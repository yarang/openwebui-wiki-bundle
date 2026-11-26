#!/usr/bin/env python3
"""Tests for the resident pair mode (RESIDENT_PROFILES): config validation,
request mapping, sequential slot switching, the memory wait, inspection /
adoption of a running pair, and the idle metric summation.

Fakes follow tests/test_spark_switch.py (FakeDocker, FakeClock,
AdvancingSleep, sync/noop spawn); small helpers are copied here so the two
files stay independent.
"""

import json
import logging
import os
import sys
import tempfile
import unittest
from urllib.parse import urlsplit

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import spark_switch  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PARENT = os.path.dirname(HERE)
PROFILES_PATH = os.path.join(PARENT, "profiles.json")

TOKEN = "t" * 40
VLLM_KEY = "sk-vllm-test-key-123"

METRICS_IDLE = (b"vllm:num_requests_running 0\n"
                b"vllm:request_success_total 0\n")

# 121 GiB unified memory in kB, for the memory-wait arithmetic.
TOTAL_KB = 121 * 1048576


# ---------------------------------------------------------------- fakes


class FakeDocker:
    """Records every call; routes are (method, path-prefix, value) where
    value is a (status, bytes) tuple or a callable(method, path, body)."""

    def __init__(self, routes=None):
        self.calls = []  # (method, path, body)
        self.routes = routes or []

    def request(self, method, path, body=None, timeout=None):
        self.calls.append((method, path, body))
        for m, prefix, value in self.routes:
            if m == method and path.startswith(prefix):
                if callable(value):
                    return value(method, path, body)
                return value
        return 404, b"{}"

    def calls_matching(self, method, prefix):
        return [c for c in self.calls if c[0] == method and c[1].startswith(prefix)]


class FakeClock:
    def __init__(self, t=100000.0):
        self.t = float(t)

    def __call__(self):
        return self.t


class AdvancingSleep:
    def __init__(self, clock):
        self.clock = clock

    def __call__(self, seconds):
        self.clock.t += seconds


def sync_spawn(target, args=()):
    target(*args)


def noop_spawn(target, args=()):
    pass


def inspect_body(running=True, exit_code=0, labels=None, cmd=None):
    return json.dumps({
        "Config": {"Labels": labels or {}, "Cmd": cmd or []},
        "State": {"Running": running, "ExitCode": exit_code},
    }).encode()


def make_config(**over):
    """Single-container config (pair mode off), like the one in
    test_spark_switch.py."""
    cfg = spark_switch.Config()
    cfg.switch_token = TOKEN
    cfg.hf_cache_host = "/home/tester/.cache/huggingface"
    cfg.vllm_api_key = VLLM_KEY
    for k, v in over.items():
        setattr(cfg, k, v)
    return cfg


def pair_config(**over):
    """Config with the resident pair on and DEFAULT_PROFILE=pair."""
    cfg = spark_switch.Config()
    cfg.switch_token = TOKEN
    cfg.hf_cache_host = "/home/tester/.cache/huggingface"
    cfg.vllm_api_key = VLLM_KEY
    cfg.default_profile = "pair"
    cfg.resident_profiles = "qwen3-instruct,qwen3-coder"
    for k, v in over.items():
        setattr(cfg, k, v)
    if "resident_names" not in over:
        cfg.resident_names = spark_switch.parse_resident_profiles(
            cfg.resident_profiles)
    return cfg


def make_pair_controller(docker, http_get=None, profiles=None,
                         spawn=sync_spawn, meminfo=None, **cfg_over):
    clock = FakeClock()
    ctrl = spark_switch.Controller(
        pair_config(**cfg_over),
        profiles if profiles is not None
        else spark_switch.load_profiles(PROFILES_PATH),
        docker,
        http_get=http_get or pair_http(docker),
        clock=clock,
        sleep=AdvancingSleep(clock),
        spawn=spawn,
        meminfo=meminfo)
    return ctrl, clock


def models_body(served):
    return json.dumps({"data": [{"id": served}]}).encode()


def pair_http(docker, errors=None,
              residents=("qwen3-instruct", "qwen3-coder")):
    """http_get answering /v1/models per slot port: port 8000+i serves
    residents[i] (or whatever the last create for that slot asked for, so
    exclusive big-profile switches work); /metrics is idle. With `errors`,
    probing a slot > 0 before its container was created is recorded — the
    sequential-start invariant."""

    def created_names():
        return {p.split("name=", 1)[1]
                for m, p, b in docker.calls
                if m == "POST" and p.startswith("/containers/create") and b}

    def last_served(cname):
        served = None
        for m, p, b in docker.calls:
            if m == "POST" and b and p == f"/containers/create?name={cname}":
                cmd = b.get("Cmd", [])
                if "--served-model-name" in cmd:
                    served = cmd[cmd.index("--served-model-name") + 1]
        return served

    def get(url, headers, timeout):
        if url.endswith("/v1/models"):
            port = urlsplit(url).port or 80
            index = port - 8000
            if not 0 <= index < len(residents):
                return 0, b""
            cname = "vllm-coder" if index == 0 else f"vllm-coder-{index}"
            if cname in created_names():
                served = last_served(cname) or residents[index]
            else:
                if index > 0 and errors is not None:
                    errors.append(
                        f"slot {index} probed before its container existed")
                served = residents[index]
            return 200, models_body(served)
        return 200, METRICS_IDLE

    return get


def static_models_http(served, metrics=METRICS_IDLE):
    def get(url, headers, timeout):
        if url.endswith("/v1/models"):
            return 200, models_body(served)
        return 200, metrics

    return get


# Routes for a full pair cycle: stop/delete BOTH slots (the "-1" DELETE
# route must come first: FakeDocker prefix-matches, and
# "/containers/vllm-coder-1?force=true" starts with "/containers/vllm-coder").
PAIR_ROUTES = [
    ("POST", "/containers/vllm-coder/stop", (204, b"")),
    ("POST", "/containers/vllm-coder-1/stop", (204, b"")),
    ("DELETE", "/containers/vllm-coder-1", (204, b"")),
    ("DELETE", "/containers/vllm-coder", (204, b"")),
    ("POST", "/containers/create", (201, b'{"Id":"abc"}')),
    ("POST", "/containers/vllm-coder/start", (204, b"")),
    ("POST", "/containers/vllm-coder-1/start", (204, b"")),
    ("GET", "/containers/vllm-coder/json",
     (200, inspect_body(running=True))),
    ("GET", "/containers/vllm-coder-1/json",
     (200, inspect_body(running=True))),
]


# ---------------------------------------------------------------- 1. config


class PairConfigTests(unittest.TestCase):
    def _write_env(self, text):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(path, 0o600)
        self.addCleanup(os.unlink, path)
        return path

    def test_parse_strips_and_drops_empties(self):
        self.assertEqual(spark_switch.parse_resident_profiles(""), [])
        self.assertEqual(spark_switch.parse_resident_profiles(" , , "), [])
        self.assertEqual(
            spark_switch.parse_resident_profiles(" a , b , , c "),
            ["a", "b", "c"])

    def test_single_resident_rejected(self):
        with self.assertRaises(spark_switch.ConfigError):
            spark_switch.parse_resident_profiles("only-one")

    def test_duplicate_residents_rejected(self):
        with self.assertRaises(spark_switch.ConfigError):
            spark_switch.parse_resident_profiles("a,b,a")

    def test_load_config_fills_resident_names(self):
        path = self._write_env(
            "SWITCH_TOKEN=" + "x" * 30 + "\n"
            "HF_CACHE_HOST=/home/u/.cache/huggingface\n"
            "RESIDENT_PROFILES= qwen3-instruct , qwen3-coder ,\n")
        cfg = spark_switch.load_config(path, {})
        self.assertEqual(cfg.resident_names,
                         ["qwen3-instruct", "qwen3-coder"])

    def test_kube_backend_with_residents_rejected(self):
        path = self._write_env(
            "SWITCH_TOKEN=" + "x" * 30 + "\n"
            "BACKEND=kubernetes\n"
            "RESIDENT_PROFILES=qwen3-instruct,qwen3-coder\n")
        with self.assertRaises(spark_switch.ConfigError) as cm:
            spark_switch.load_config(path, {})
        self.assertIn("RESIDENT_PROFILES", str(cm.exception))

    def test_mem_margin_gb_bad_value_rejected(self):
        path = self._write_env(
            "SWITCH_TOKEN=" + "x" * 30 + "\n"
            "HF_CACHE_HOST=/home/u/.cache/huggingface\n"
            "MEM_MARGIN_GB=not-a-number\n")
        with self.assertRaises(spark_switch.ConfigError) as cm:
            spark_switch.load_config(path, {})
        self.assertIn("MEM_MARGIN_GB", str(cm.exception))

    def test_defaults(self):
        cfg = spark_switch.Config()
        self.assertEqual(cfg.resident_profiles, "")
        self.assertEqual(cfg.resident_names, [])
        self.assertEqual(cfg.mem_wait_timeout, 0)
        self.assertEqual(cfg.mem_margin_gb, 4.0)
        self.assertEqual(cfg.meminfo_path, "/proc/meminfo")

    def test_pair_profile_name_rejected_by_load_profiles(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json",
                                         delete=False) as f:
            json.dump({"pair": {"model": "org/model-name",
                                "args": ["--max-model-len", "8192"]}}, f)
            path = f.name
        try:
            with self.assertRaises(spark_switch.ProfileError):
                spark_switch.load_profiles(path)
        finally:
            os.unlink(path)


class PairControllerValidationTests(unittest.TestCase):
    def _profiles(self):
        return spark_switch.load_profiles(PROFILES_PATH)

    def test_default_pair_without_residents_rejected(self):
        cfg = make_config(default_profile="pair")
        with self.assertRaises(spark_switch.ConfigError) as cm:
            spark_switch.Controller(cfg, self._profiles(), FakeDocker())
        self.assertIn("DEFAULT_PROFILE", str(cm.exception))

    def test_unknown_resident_rejected(self):
        cfg = pair_config()
        cfg.resident_names = ["nope", "qwen3-coder"]
        with self.assertRaises(spark_switch.ConfigError) as cm:
            spark_switch.Controller(cfg, self._profiles(), FakeDocker())
        self.assertIn("nope", str(cm.exception))

    def test_default_pair_with_residents_is_accepted(self):
        ctrl, _ = make_pair_controller(FakeDocker(), spawn=noop_spawn)
        self.assertEqual(ctrl.config.default_profile, "pair")


# ---------------------------------------------------------------- 2. mapping


class PairRequestSwitchMappingTests(unittest.TestCase):
    def _controller(self):
        ctrl, _ = make_pair_controller(FakeDocker(), spawn=noop_spawn)
        return ctrl

    def test_each_resident_name_maps_to_pair(self):
        for name in ("qwen3-coder", "qwen3-instruct", "pair"):
            ctrl = self._controller()
            status, payload = ctrl.request_switch(name)
            self.assertEqual(status, 202, name)
            self.assertEqual(payload["target"], "pair", name)

    def test_default_alias_maps_to_pair(self):
        ctrl = self._controller()
        status, payload = ctrl.request_switch("default")
        self.assertEqual(status, 202)
        self.assertEqual(payload["target"], "pair")

    def test_exclusive_profile_keeps_its_own_name(self):
        ctrl = self._controller()
        status, payload = ctrl.request_switch("gpt-oss-120b")
        self.assertEqual(status, 202)
        self.assertEqual(payload["target"], "gpt-oss-120b")

    def test_already_ready_pair_is_200_unchanged(self):
        ctrl = self._controller()
        with ctrl._lock:
            ctrl._s.state = "ready"
            ctrl._s.current = "pair"
        status, payload = ctrl.request_switch("qwen3-coder")
        self.assertEqual(status, 200)
        self.assertFalse(payload["changed"])
        self.assertEqual(payload["current"], "pair")

    def test_pair_without_residents_is_400(self):
        ctrl, _ = make_pair_controller(FakeDocker(), spawn=noop_spawn,
                                       default_profile="qwen3-coder",
                                       resident_profiles="",
                                       resident_names=[])
        status, payload = ctrl.request_switch("pair")
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"]["type"], "unknown_profile")


# ---------------------------------------------------------------- 3. switching


class PairSwitchTests(unittest.TestCase):
    def test_pair_switch_stops_both_then_starts_slots_in_order(self):
        errors = []
        probes = []  # (url, len(docker.calls) at probe time)
        docker = FakeDocker(list(PAIR_ROUTES))
        base = pair_http(docker, errors=errors)

        def recording_get(url, headers, timeout):
            probes.append((url, len(docker.calls)))
            return base(url, headers, timeout)

        ctrl, _ = make_pair_controller(docker, http_get=recording_get)
        ctrl.run_switch("pair", "api")

        self.assertEqual(errors, [])
        # Both slots are stopped and deleted before anything is created,
        # slot 0 is created and started before slot 1, and after the last
        # POST only readiness inspects happen.
        self.assertEqual(
            [(m, p) for m, p, b in docker.calls if m == "POST"],
            [
                ("POST", "/containers/vllm-coder/stop?t=60"),
                ("POST", "/containers/vllm-coder-1/stop?t=60"),
                ("POST", "/containers/create?name=vllm-coder"),
                ("POST", "/containers/vllm-coder/start"),
                ("POST", "/containers/create?name=vllm-coder-1"),
                ("POST", "/containers/vllm-coder-1/start"),
            ])
        deletes = sorted(p for m, p, _ in docker.calls if m == "DELETE")
        self.assertEqual(deletes,
                         ["/containers/vllm-coder-1?force=true",
                          "/containers/vllm-coder?force=true"])
        idx_create0 = next(i for i, (m, p, _b) in enumerate(docker.calls)
                           if m == "POST"
                           and p == "/containers/create?name=vllm-coder")
        self.assertLess(max(i for i, (m, _p, _b) in enumerate(docker.calls)
                            if m == "DELETE"), idx_create0)
        last_post = max(i for i, (m, _p, _b) in enumerate(docker.calls)
                        if m == "POST")
        self.assertTrue(all(m == "GET"
                            for m, _p, _b in docker.calls[last_post + 1:]))

        # Sequential start: slot 0 was probed (and answered) strictly before
        # slot 1's create was issued — a probe records len(docker.calls) at
        # its own moment, so n == idx_create1 still means "create1 happened
        # after this probe" — and slot 1 was never probed before existing.
        idx_create1 = next(i for i, (m, p, _b) in enumerate(docker.calls)
                           if m == "POST"
                           and p == "/containers/create?name=vllm-coder-1")
        first_slot0_probe = min(n for url, n in probes
                                if ":8000/v1/models" in url)
        slot1_probes = [n for url, n in probes if ":8001/v1/models" in url]
        self.assertLessEqual(first_slot0_probe, idx_create1)
        self.assertTrue(slot1_probes)
        self.assertGreater(min(slot1_probes), idx_create1)

        # Create bodies: slot 0 = qwen3-instruct on 8000, slot 1 =
        # qwen3-coder on 8001; container port untouched.
        creates = docker.calls_matching("POST", "/containers/create")
        self.assertEqual(len(creates), 2)
        _, path0, body0 = creates[0]
        self.assertEqual(path0, "/containers/create?name=vllm-coder")
        cmd0 = body0["Cmd"]
        self.assertEqual(
            cmd0[cmd0.index("--served-model-name") + 1], "qwen3-instruct")
        self.assertEqual(
            body0["HostConfig"]["PortBindings"]["8000/tcp"][0]["HostPort"],
            "8000")
        self.assertEqual(body0["Labels"][spark_switch.LABEL_PROFILE],
                         "qwen3-instruct")
        _, path1, body1 = creates[1]
        self.assertEqual(path1, "/containers/create?name=vllm-coder-1")
        cmd1 = body1["Cmd"]
        self.assertEqual(
            cmd1[cmd1.index("--served-model-name") + 1], "qwen3-coder")
        self.assertEqual(
            body1["HostConfig"]["PortBindings"]["8000/tcp"][0]["HostPort"],
            "8001")
        self.assertEqual(body1["ExposedPorts"], {"8000/tcp": {}})

        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "pair")
        self.assertIsNone(st["last_error"])
        self.assertEqual(st["mode"], "pair")
        self.assertEqual(st["residents"], ["qwen3-instruct", "qwen3-coder"])
        self.assertEqual(st["slots"], [
            {"slot": 0, "container": "vllm-coder", "port": 8000,
             "profile": "qwen3-instruct"},
            {"slot": 1, "container": "vllm-coder-1", "port": 8001,
             "profile": "qwen3-coder"},
        ])
        resident_flags = {p["name"]: p["resident"] for p in st["profiles"]}
        self.assertTrue(resident_flags["qwen3-instruct"])
        self.assertTrue(resident_flags["qwen3-coder"])
        self.assertFalse(resident_flags["gpt-oss-120b"])

    def test_exclusive_switch_from_pair_evicts_both_slots(self):
        docker = FakeDocker(list(PAIR_ROUTES))
        ctrl, _ = make_pair_controller(docker)
        with ctrl._lock:
            ctrl._s.state = "ready"
            ctrl._s.current = "pair"
        ctrl.run_switch("gpt-oss-120b", "api")

        stops = sorted(p for m, p, _ in docker.calls
                       if m == "POST" and p.endswith("/stop?t=60"))
        self.assertEqual(stops,
                         ["/containers/vllm-coder-1/stop?t=60",
                          "/containers/vllm-coder/stop?t=60"])
        deletes = sorted(p for m, p, _ in docker.calls if m == "DELETE")
        self.assertEqual(deletes,
                         ["/containers/vllm-coder-1?force=true",
                          "/containers/vllm-coder?force=true"])

        creates = docker.calls_matching("POST", "/containers/create")
        self.assertEqual(len(creates), 1)
        _, path, body = creates[0]
        self.assertEqual(path, "/containers/create?name=vllm-coder")
        cmd = body["Cmd"]
        self.assertEqual(
            cmd[cmd.index("--served-model-name") + 1], "gpt-oss-120b")
        self.assertEqual(
            body["HostConfig"]["PortBindings"]["8000/tcp"][0]["HostPort"],
            "8000")

        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "gpt-oss-120b")
        self.assertEqual(st["mode"], "single")
        self.assertEqual(st["slots"], [
            {"slot": 0, "container": "vllm-coder", "port": 8000,
             "profile": "gpt-oss-120b"},
        ])
        # residents stay reported even while an exclusive profile serves
        self.assertEqual(st["residents"], ["qwen3-instruct", "qwen3-coder"])


# ---------------------------------------------------------------- 4. memory wait


class MemoryWaitTests(unittest.TestCase):
    def _meminfo(self, values, box=None):
        """Injectable reader serving `values` in order (last one repeats);
        records the phase observed at each call into box["phases"]."""
        def read():
            if box is not None:
                box["n"] += 1
                if box["ctrl"] is not None:
                    box["phases"].append(box["ctrl"].status()["phase"])
            return values[min(box["n"] if box else 1, len(values)) - 1]
        return read

    def test_waits_for_memory_then_proceeds(self):
        box = {"ctrl": None, "n": 0, "phases": []}
        low = (TOTAL_KB, int(TOTAL_KB * 0.70))          # below the need
        enough = (TOTAL_KB, int(TOTAL_KB * 0.93))       # above the need
        docker = FakeDocker(list(PAIR_ROUTES))
        ctrl, _ = make_pair_controller(
            docker, http_get=pair_http(docker),
            mem_wait_timeout=120,
            meminfo=self._meminfo([low, enough], box))
        box["ctrl"] = ctrl
        ctrl.run_switch("pair", "api")

        self.assertIn("waiting-memory", box["phases"])
        self.assertEqual(box["n"], 2)  # one low read, one good read
        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "pair")

    def test_timeout_ends_failed_with_memory_message(self):
        always_low = (TOTAL_KB, int(TOTAL_KB * 0.70))
        docker = FakeDocker(list(PAIR_ROUTES))
        # pair is also the default: no recovery attempt, straight to failed
        ctrl, _ = make_pair_controller(
            docker, http_get=pair_http(docker),
            mem_wait_timeout=12, ready_poll_seconds=5,
            meminfo=lambda: always_low)
        ctrl.run_switch("pair", "api")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIn("memory not released", st["last_error"])
        self.assertIn("GiB", st["last_error"])
        # memory never freed: no container was ever created
        self.assertEqual(
            len(docker.calls_matching("POST", "/containers/create")), 0)
        # both slots were still stopped first
        self.assertEqual(
            sorted(p for m, p, _ in docker.calls if m == "DELETE"),
            ["/containers/vllm-coder-1?force=true",
             "/containers/vllm-coder?force=true"])

    def test_unreadable_meminfo_warns_and_does_not_block(self):
        docker = FakeDocker(list(PAIR_ROUTES))
        with self.assertLogs(logging.getLogger("spark-switch"),
                             level="WARNING") as cm:
            ctrl, _ = make_pair_controller(
                docker, http_get=pair_http(docker),
                mem_wait_timeout=600, meminfo=lambda: None)
            ctrl.run_switch("pair", "api")
        self.assertIn("skipping the memory wait",
                      "\n".join(r.getMessage() for r in cm.records))
        self.assertEqual(ctrl.status()["current"], "pair")

    def test_disabled_wait_never_reads_meminfo(self):
        calls = {"n": 0}

        def read():
            calls["n"] += 1
            return (TOTAL_KB, TOTAL_KB)

        docker = FakeDocker(list(PAIR_ROUTES))
        ctrl, _ = make_pair_controller(
            docker, http_get=pair_http(docker), meminfo=read)
        ctrl.run_switch("pair", "api")
        self.assertEqual(calls["n"], 0)  # MEM_WAIT_TIMEOUT defaults to 0
        self.assertEqual(ctrl.status()["current"], "pair")


# ---------------------------------------------------------------- 5. check_alive


class CheckAlivePairTests(unittest.TestCase):
    def _backend(self, docker):
        profiles = spark_switch.load_profiles(PROFILES_PATH)
        return spark_switch.DockerBackend(pair_config(), profiles, docker)

    def test_exited_second_slot_is_named(self):
        docker = FakeDocker([
            ("GET", "/containers/vllm-coder/json",
             (200, inspect_body(running=True))),
            ("GET", "/containers/vllm-coder-1/json",
             (200, inspect_body(running=False, exit_code=3))),
        ])
        backend = self._backend(docker)
        backend._active = ["vllm-coder", "vllm-coder-1"]
        why = backend.check_alive()
        self.assertIsNotNone(why)
        self.assertIn("vllm-coder-1", why)
        self.assertIn("code 3", why)

    def test_single_active_slot_keeps_the_historical_message(self):
        docker = FakeDocker([
            ("GET", "/containers/vllm-coder/json",
             (200, inspect_body(running=False, exit_code=3))),
        ])
        backend = self._backend(docker)
        backend._active = ["vllm-coder"]
        self.assertEqual(backend.check_alive(),
                         "container exited (code 3)")

    def test_logs_tail_prefixes_each_slot_when_plural(self):
        docker = FakeDocker([
            ("GET", "/containers/vllm-coder/logs",
             (200, b"slot zero log\n")),
            ("GET", "/containers/vllm-coder-1/logs",
             (200, b"slot one log\n")),
        ])
        backend = self._backend(docker)
        backend._active = ["vllm-coder", "vllm-coder-1"]
        tail = backend.logs_tail(40)
        self.assertIn("== vllm-coder ==", tail)
        self.assertIn("== vllm-coder-1 ==", tail)
        self.assertIn("slot zero log", tail)
        self.assertIn("slot one log", tail)
        self.assertEqual(tail.index("vllm-coder ==")
                         < tail.index("slot zero log")
                         < tail.index("vllm-coder-1 =="), True)


# ---------------------------------------------------------------- 6. inspect / adopt


class InspectPairTests(unittest.TestCase):
    def _adopt_with(self, docker, http_get):
        ctrl, _ = make_pair_controller(docker, http_get=http_get)
        ctrl.adopt()
        return ctrl.status()

    def test_both_slots_running_adopts_pair(self):
        docker = FakeDocker([
            ("GET", "/containers/vllm-coder/json",
             (200, inspect_body(
                 running=True,
                 labels={spark_switch.LABEL_PROFILE: "qwen3-instruct"}))),
            ("GET", "/containers/vllm-coder-1/json",
             (200, inspect_body(
                 running=True,
                 labels={spark_switch.LABEL_PROFILE: "qwen3-coder"}))),
        ])
        st = self._adopt_with(docker, pair_http(docker))
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "pair")
        self.assertEqual(st["mode"], "pair")

    def test_only_slot0_running_adopts_single_profile(self):
        docker = FakeDocker([
            ("GET", "/containers/vllm-coder/json",
             (200, inspect_body(
                 running=True,
                 labels={spark_switch.LABEL_PROFILE: "qwen3-instruct"}))),
            ("GET", "/containers/vllm-coder-1/json", (404, b"{}")),
        ])
        st = self._adopt_with(docker, static_models_http("qwen3-instruct"))
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "qwen3-instruct")
        self.assertEqual(st["mode"], "single")

    def test_wrong_profiles_on_slots_is_unknown(self):
        docker = FakeDocker([
            ("GET", "/containers/vllm-coder/json",
             (200, inspect_body(
                 running=True,
                 labels={spark_switch.LABEL_PROFILE: "gpt-oss-120b"}))),
            ("GET", "/containers/vllm-coder-1/json",
             (200, inspect_body(
                 running=True,
                 labels={spark_switch.LABEL_PROFILE: "qwen3-coder"}))),
        ])
        st = self._adopt_with(docker, pair_http(docker))
        self.assertEqual(st["state"], "unknown")
        self.assertIsNone(st["current"])

    def test_partial_slot_set_without_slot0_is_unknown(self):
        docker = FakeDocker([
            ("GET", "/containers/vllm-coder/json", (404, b"{}")),
            ("GET", "/containers/vllm-coder-1/json",
             (200, inspect_body(
                 running=True,
                 labels={spark_switch.LABEL_PROFILE: "qwen3-coder"}))),
        ])
        st = self._adopt_with(docker, pair_http(docker))
        self.assertEqual(st["state"], "unknown")
        self.assertIsNone(st["current"])


# ---------------------------------------------------------------- 7. idle sum


class IdleSumTests(unittest.TestCase):
    METRICS = ("vllm:num_requests_running {r}\n"
               "vllm:num_requests_waiting {w}\n"
               "vllm:request_success_total {s}\n")

    def test_probe_idle_sums_both_endpoints(self):
        ctrl, _ = make_pair_controller(FakeDocker())

        def get(url, headers, timeout):
            port = urlsplit(url).port or 80
            if url.endswith("/metrics"):
                if port == 8000:
                    return 200, self.METRICS.format(
                        r=2, w=0, s=5).encode()
                return 200, self.METRICS.format(r=1, w=1, s=7).encode()
            return 200, models_body("x")

        ctrl.http_get = get
        running, success = ctrl._probe_idle(ctrl._endpoints("pair"))
        self.assertEqual(running, 4.0)   # (2+0) + (1+1)
        self.assertEqual(success, 12.0)  # 5 + 7

    def test_probe_idle_failed_endpoint_is_not_idleness(self):
        ctrl, _ = make_pair_controller(FakeDocker())

        def get(url, headers, timeout):
            port = urlsplit(url).port or 80
            if url.endswith("/metrics"):
                return (200, self.METRICS.format(r=0, w=0, s=1).encode()
                        if port == 8000 else (0, b""))
            return 200, models_body("x")

        ctrl.http_get = get
        running, success = ctrl._probe_idle(ctrl._endpoints("pair"))
        self.assertIsNone(running)
        self.assertIsNone(success)

    def test_idle_tick_counts_summed_running_as_activity(self):
        # pair default, exclusive current: the idle tick runs the sum path
        # over the current profile's endpoints (one here) and must treat
        # running > 0 as activity.
        docker = FakeDocker(list(PAIR_ROUTES))
        ctrl, clock = make_pair_controller(docker)

        def get(url, headers, timeout):
            if url.endswith("/metrics"):
                return 200, self.METRICS.format(r=3, w=1, s=0).encode()
            return pair_http(docker)(url, headers, timeout)

        ctrl.http_get = get
        with ctrl._lock:
            ctrl._s.state = "ready"
            ctrl._s.current = "gpt-oss-120b"
            ctrl._s.last_activity = clock.t - 31 * 60  # idle-long ago
        ctrl.idle_tick()
        st = ctrl.status()
        self.assertEqual(st["current"], "gpt-oss-120b")  # no idle return
        self.assertIsNotNone(st["idle_return_at"])
        self.assertGreater(st["idle_return_at"], clock.t)


# ---------------------------------------------------------------- 8. slot_url


class SlotUrlTests(unittest.TestCase):
    def test_replaces_the_port(self):
        self.assertEqual(
            spark_switch.slot_url("http://host.docker.internal:8000", 1),
            "http://host.docker.internal:8001")
        self.assertEqual(
            spark_switch.slot_url("http://host.docker.internal:8000", 0),
            "http://host.docker.internal:8000")

    def test_scheme_defaults_when_port_absent(self):
        self.assertEqual(spark_switch.slot_url("http://h/", 2),
                         "http://h:82/")
        self.assertEqual(spark_switch.slot_url("https://h", 1),
                         "https://h:444")

    def test_keeps_scheme_host_and_path(self):
        self.assertEqual(spark_switch.slot_url("http://h:8000/v1/models", 1),
                         "http://h:8001/v1/models")

    def test_gpu_memory_utilization_reading(self):
        profiles = spark_switch.load_profiles(PROFILES_PATH)
        self.assertEqual(
            spark_switch.gpu_memory_utilization(profiles["qwen3-instruct"]),
            0.40)
        # both --flag value and --flag=value forms, and the 0.9 fallback
        p = spark_switch.Profile(name="x", model="org/m",
                                 args=["--gpu-memory-utilization", "0.5"])
        self.assertEqual(spark_switch.gpu_memory_utilization(p), 0.5)
        p = spark_switch.Profile(name="x", model="org/m",
                                 args=["--gpu-memory-utilization=0.25"])
        self.assertEqual(spark_switch.gpu_memory_utilization(p), 0.25)
        p = spark_switch.Profile(name="x", model="org/m", args=[])
        self.assertEqual(spark_switch.gpu_memory_utilization(p), 0.9)


if __name__ == "__main__":
    unittest.main()
