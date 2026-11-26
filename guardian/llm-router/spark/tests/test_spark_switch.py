#!/usr/bin/env python3
"""Tests for spark_switch (stdlib unittest only; no real Docker, no network
beyond a server bound to 127.0.0.1 port 0)."""

import http.client
import json
import logging
import os
import socket
import struct
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import spark_switch  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PARENT = os.path.dirname(HERE)
PROFILES_PATH = os.path.join(PARENT, "profiles.json")

TOKEN = "t" * 40
VLLM_KEY = "sk-vllm-test-key-123"


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


def smart_http(docker, models_status=200):
    """http_get that answers /v1/models with whatever profile the last
    create asked for (so switches succeed), and /metrics with zeros."""

    def get(url, headers, timeout):
        if url.endswith("/v1/models"):
            if models_status != 200:
                return models_status, b"{}"
            served = None
            for m, p, b in docker.calls:
                if m == "POST" and p.startswith("/containers/create") and b:
                    cmd = b.get("Cmd", [])
                    if "--served-model-name" in cmd:
                        served = cmd[cmd.index("--served-model-name") + 1]
            return 200, json.dumps({"data": [{"id": served or "unknown"}]}).encode()
        return 200, b"vllm:num_requests_running 0\nvllm:request_success_total 0\n"

    return get


def models_http(served, metrics=b"vllm:num_requests_running 0\n"
                                b"vllm:request_success_total 0\n"):
    """http_get whose /v1/models always lists `served` (adopt probes happen
    with no create call to infer from) and whose /metrics is idle."""

    def get(url, headers, timeout):
        if url.endswith("/v1/models"):
            return 200, json.dumps({"data": [{"id": served}]}).encode()
        return 200, metrics

    return get


def make_config(**over):
    cfg = spark_switch.Config()
    cfg.switch_token = TOKEN
    cfg.hf_cache_host = "/home/tester/.cache/huggingface"
    cfg.vllm_api_key = VLLM_KEY
    for k, v in over.items():
        setattr(cfg, k, v)
    return cfg


def make_controller(docker, http_get=None, profiles=None, spawn=sync_spawn, **cfg_over):
    clock = FakeClock()
    ctrl = spark_switch.Controller(
        make_config(**cfg_over),
        profiles if profiles is not None else spark_switch.load_profiles(PROFILES_PATH),
        docker,
        http_get=http_get or smart_http(docker),
        clock=clock,
        sleep=AdvancingSleep(clock),
        spawn=spawn,
    )
    return ctrl, clock


def inspect_body(running=True, exit_code=0, labels=None, cmd=None):
    return json.dumps({
        "Config": {"Labels": labels or {}, "Cmd": cmd or []},
        "State": {"Running": running, "ExitCode": exit_code},
    }).encode()


SWITCH_ROUTES = [
    ("POST", "/containers/vllm-coder/stop", (204, b"")),
    ("DELETE", "/containers/vllm-coder", (204, b"")),
    ("POST", "/containers/create", (201, b'{"Id":"abc"}')),
    ("POST", "/containers/vllm-coder/start", (204, b"")),
    ("GET", "/containers/vllm-coder/json", (200, inspect_body(running=True))),
]


# ---------------------------------------------------------------- 1. profiles


class LoadProfilesTests(unittest.TestCase):
    def test_shipped_profiles_load(self):
        profiles = spark_switch.load_profiles(PROFILES_PATH)
        self.assertEqual(
            set(profiles),
            {"qwen3-coder", "qwen3-instruct", "gpt-oss-120b",
             "qwen3-next-80b", "qwen3-vl-30b",
             "qwen3-coder-solo", "gpt-oss-120b-lite"})
        q = profiles["qwen3-coder"]
        self.assertEqual(q.model, "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8")
        self.assertEqual(q.name, "qwen3-coder")
        self.assertEqual(q.kind, "text")
        self.assertTrue(q.verified)
        self.assertIn("--tool-call-parser", q.args)
        self.assertEqual(
            q.args[q.args.index("--tool-call-parser") + 1], "qwen3_coder")
        # qwen3-instruct: util 0.40, the resident-pair member sizing
        # measured in the 2026-11-14 pair bench.
        i = profiles["qwen3-instruct"]
        self.assertEqual(i.model, "Qwen/Qwen3-30B-A3B-Instruct-2507-FP8")
        self.assertTrue(i.verified)
        self.assertEqual(
            i.args[i.args.index("--gpu-memory-utilization") + 1], "0.40")
        self.assertEqual(i.args[i.args.index("--max-model-len") + 1], "65536")
        # The two Isaac-class profiles were brought up and load-tested on
        # the Spark on 2026-11-15, so they are verified too.
        verified = ("qwen3-coder", "qwen3-instruct",
                    "qwen3-coder-solo", "gpt-oss-120b-lite")
        for name, p in profiles.items():
            self.assertEqual(p.verified, name in verified, name)

    def _load(self, obj):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(obj, f)
            path = f.name
        try:
            return spark_switch.load_profiles(path)
        finally:
            os.unlink(path)

    def _profile(self):
        return {"model": "org/model-name", "description": "d", "kind": "text",
                "verified": False, "args": ["--max-model-len", "8192"]}

    def test_rejects_bad_name(self):
        with self.assertRaises(spark_switch.ProfileError):
            self._load({"Bad_Name": self._profile()})

    def test_rejects_bad_arg_character(self):
        prof = self._profile()
        prof["args"] = ["--max-model-len", "8192 with space"]
        with self.assertRaises(spark_switch.ProfileError):
            self._load({"ok-name": prof})

    def test_rejects_forbidden_port_arg(self):
        prof = self._profile()
        prof["args"] = ["--port", "1234"]
        with self.assertRaises(spark_switch.ProfileError):
            self._load({"ok-name": prof})

    def test_rejects_forbidden_api_key_arg(self):
        prof = self._profile()
        prof["args"] = ["--api-key=secret"]
        with self.assertRaises(spark_switch.ProfileError):
            self._load({"ok-name": prof})

    def test_rejects_reserved_default_name(self):
        with self.assertRaises(spark_switch.ProfileError):
            self._load({"default": self._profile()})

    def test_rejects_unknown_kind(self):
        prof = self._profile()
        prof["kind"] = "audio"
        with self.assertRaises(spark_switch.ProfileError):
            self._load({"ok-name": prof})


# ---------------------------------------------------------------- 2. config


class LoadConfigTests(unittest.TestCase):
    def _write_env(self, text, mode=0o600):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(path, mode)
        self.addCleanup(os.unlink, path)
        return path

    def test_parses_export_quotes_and_comments(self):
        path = self._write_env(
            "# a comment\n"
            "\n"
            "export SWITCH_TOKEN = \"a-long-enough-token-value\"\n"
            "HF_CACHE_HOST='/home/u/.cache/huggingface'\n"
            "IDLE_MINUTES=15\n"
            "IGNORED_WITHOUT_EQUALS\n")
        try:
            cfg = spark_switch.load_config(path, {})
        finally:
            os.chmod(path, 0o600)
        self.assertEqual(cfg.switch_token, "a-long-enough-token-value")
        self.assertEqual(cfg.hf_cache_host, "/home/u/.cache/huggingface")
        self.assertEqual(cfg.idle_minutes, 15)

    def test_open_permissions_rejected(self):
        path = self._write_env("SWITCH_TOKEN=" + "x" * 30 + "\n", mode=0o644)
        try:
            with self.assertRaises(spark_switch.ConfigError):
                spark_switch.load_config(path, {})
        finally:
            os.chmod(path, 0o600)

    def test_short_token_rejected(self):
        path = self._write_env("SWITCH_TOKEN=short\n")
        try:
            with self.assertRaises(spark_switch.ConfigError):
                spark_switch.load_config(path, {})
        finally:
            os.chmod(path, 0o600)

    def test_process_env_overrides_file(self):
        path = self._write_env(
            "SWITCH_TOKEN=" + "a" * 30 + "\n"
            "IDLE_MINUTES=15\n"
            "HF_CACHE_HOST=/home/file/cache\n")
        try:
            cfg = spark_switch.load_config(
                path, {"IDLE_MINUTES": "45", "HF_CACHE_HOST": "/home/env/cache"})
        finally:
            os.chmod(path, 0o600)
        self.assertEqual(cfg.idle_minutes, 45)
        self.assertEqual(cfg.hf_cache_host, "/home/env/cache")

    def test_missing_default_profile_rejected_by_controller(self):
        profiles = spark_switch.load_profiles(PROFILES_PATH)
        profiles.pop("qwen3-coder")
        docker = FakeDocker()
        with self.assertRaises(spark_switch.ConfigError):
            spark_switch.Controller(make_config(), profiles, docker)

    def test_open_vllm_env_mode_warns_but_loads(self):
        """The vLLM key file is mounted read-only into the container, so an
        open mode is warned about, not refused — and the key still loads."""
        fd, vpath = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write("VLLM_API_KEY=" + VLLM_KEY + "\n")
        os.chmod(vpath, 0o600)
        self.addCleanup(lambda: (os.chmod(vpath, 0o600), os.unlink(vpath)))

        switch_env = self._write_env(
            "SWITCH_TOKEN=" + "x" * 30 + "\n"
            "HF_CACHE_HOST=/home/u/.cache/huggingface\n")

        cfg = spark_switch.load_config(
            switch_env, {"VLLM_ENV_FILE": vpath})
        self.assertEqual(cfg.vllm_api_key, VLLM_KEY)  # tight mode: no warning

        os.chmod(vpath, 0o644)
        with self.assertLogs(logging.getLogger("spark-switch"),
                             level="WARNING") as cm:
            cfg = spark_switch.load_config(
                switch_env, {"VLLM_ENV_FILE": vpath})
        self.assertEqual(cfg.vllm_api_key, VLLM_KEY)  # still loads
        text = "\n".join(r.getMessage() for r in cm.records)
        self.assertIn("chmod 600", text)
        self.assertNotIn(VLLM_KEY, text)  # the warning never quotes content


# ---------------------------------------------------------------- 3. adopt


class AdoptTests(unittest.TestCase):
    def test_adopts_unlabeled_container_from_cmd(self):
        docker = FakeDocker([(
            "GET", "/containers/vllm-coder/json",
            (200, inspect_body(
                running=True,
                cmd=["vllm", "serve", "Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8",
                     "--served-model-name", "qwen3-coder"])))])
        ctrl, _ = make_controller(docker, http_get=models_http("qwen3-coder"))
        ctrl.adopt()
        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "qwen3-coder")

    def test_404_means_unknown(self):
        ctrl, _ = make_controller(FakeDocker())
        ctrl.adopt()
        st = ctrl.status()
        self.assertEqual(st["state"], "unknown")
        self.assertIsNone(st["current"])

    def test_label_wins_over_cmd(self):
        docker = FakeDocker([(
            "GET", "/containers/vllm-coder/json",
            (200, inspect_body(
                running=True,
                labels={spark_switch.LABEL_PROFILE: "gpt-oss-120b"},
                cmd=["vllm", "serve", "x", "--served-model-name",
                     "qwen3-coder"])))])
        ctrl, _ = make_controller(docker, http_get=models_http("gpt-oss-120b"))
        ctrl.adopt()
        st = ctrl.status()
        self.assertEqual(st["current"], "gpt-oss-120b")

    def test_stopped_container_is_unknown(self):
        docker = FakeDocker([(
            "GET", "/containers/vllm-coder/json",
            (200, inspect_body(
                running=False,
                labels={spark_switch.LABEL_PROFILE: "gpt-oss-120b"})))])
        ctrl, _ = make_controller(docker)
        ctrl.adopt()
        self.assertEqual(ctrl.status()["state"], "unknown")

    def test_running_but_not_serving_is_adopted_as_loading(self):
        """A running container whose vLLM does not list the profile yet (the
        controller restarted during a long weight load) must not be reported
        ready: adopt it as switching/loading and only wait for readiness."""
        docker = FakeDocker([(
            "GET", "/containers/vllm-coder/json",
            (200, inspect_body(
                running=True,
                labels={spark_switch.LABEL_PROFILE: "gpt-oss-120b"})))])

        probes = {"n": 0}

        def not_yet_then_ready(url, headers, timeout):
            if url.endswith("/v1/models"):
                probes["n"] += 1
                if probes["n"] <= 1:  # the adopt probe: weights still loading
                    return 200, json.dumps(
                        {"data": [{"id": "nope"}]}).encode()
                return 200, json.dumps(
                    {"data": [{"id": "gpt-oss-120b"}]}).encode()
            return 200, b""

        ctrl, _ = make_controller(docker, http_get=not_yet_then_ready)
        ctrl.adopt()  # sync spawn: the adopt wait runs to completion here
        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "gpt-oss-120b")
        self.assertEqual(st["reason"], "adopt")
        # the adopt worker only waited — no stop/create cycle was run
        self.assertEqual(
            len(docker.calls_matching("POST", "/containers/vllm-coder/stop")), 0)
        self.assertEqual(len(docker.calls_matching("POST", "/containers/create")), 0)

    def test_adopt_wait_state_before_ready(self):
        """Right after adopt of a loading container: switching, target set,
        phase loading (checked with a worker that does not run yet)."""
        docker = FakeDocker([(
            "GET", "/containers/vllm-coder/json",
            (200, inspect_body(
                running=True,
                labels={spark_switch.LABEL_PROFILE: "qwen3-next-80b"})))])
        ctrl, _ = make_controller(docker, http_get=models_http("still-loading"),
                                  spawn=noop_spawn)
        ctrl.adopt()
        st = ctrl.status()
        self.assertEqual(st["state"], "switching")
        self.assertEqual(st["target"], "qwen3-next-80b")
        self.assertEqual(st["phase"], "loading")

    def test_adopt_wait_timeout_follows_recovery_path(self):
        """If the adopted load never finishes, the normal failure + recovery
        path runs: one switch back to the default profile, then failed."""
        # FakeDocker uses the FIRST matching route, so the labeled inspect
        # (adopt's view) must come before SWITCH_ROUTES' unlabeled one.
        docker = FakeDocker([(
            "GET", "/containers/vllm-coder/json",
            (200, inspect_body(
                running=True,
                labels={spark_switch.LABEL_PROFILE: "gpt-oss-120b"})))]
            + list(SWITCH_ROUTES))

        def never_lists(url, headers, timeout):
            if url.endswith("/v1/models"):
                return 200, json.dumps({"data": [{"id": "other"}]}).encode()
            return 200, b""

        ctrl, _ = make_controller(docker, http_get=never_lists,
                                  ready_timeout=15, ready_poll_seconds=5)
        ctrl.adopt()  # sync spawn: adopt wait times out, recovery runs
        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIsNone(st["current"])
        creates = docker.calls_matching("POST", "/containers/create")
        self.assertEqual(len(creates), 1)  # exactly one recovery create
        cmd = creates[0][2]["Cmd"]
        self.assertEqual(cmd[cmd.index("--served-model-name") + 1], "qwen3-coder")
        self.assertIn("not ready after 15 s", st["last_error"])


# ---------------------------------------------------------------- 4. happy path


class SwitchHappyPathTests(unittest.TestCase):
    def test_docker_sequence_and_create_body(self):
        docker = FakeDocker(list(SWITCH_ROUTES))
        ctrl, _ = make_controller(docker)
        ctrl.run_switch("gpt-oss-120b", "api")

        sequence = [(m, p) for m, p, b in docker.calls]
        self.assertEqual(
            sequence,
            [
                ("POST", "/containers/vllm-coder/stop?t=60"),
                ("DELETE", "/containers/vllm-coder?force=true"),
                ("POST", "/containers/create?name=vllm-coder"),
                ("POST", "/containers/vllm-coder/start"),
                ("GET", "/containers/vllm-coder/json"),
            ])

        creates = docker.calls_matching("POST", "/containers/create")
        self.assertEqual(len(creates), 1)
        method, path, body = creates[0]
        self.assertEqual(path, "/containers/create?name=vllm-coder")
        self.assertEqual(body["Image"], "nvcr.io/nvidia/vllm:26.02-py3")
        cmd = body["Cmd"]
        prof = spark_switch.load_profiles(PROFILES_PATH)["gpt-oss-120b"]
        self.assertEqual(
            cmd[:7],
            ["vllm", "serve", prof.model, "--served-model-name",
             "gpt-oss-120b", "--host", "0.0.0.0"])
        self.assertEqual(cmd[7], "--port")
        self.assertEqual(cmd[8], "8000")
        for arg in prof.args:
            self.assertIn(arg, cmd)
        self.assertEqual(body["Env"], ["VLLM_API_KEY=" + VLLM_KEY])
        self.assertEqual(
            body["Labels"][spark_switch.LABEL_PROFILE], "gpt-oss-120b")
        self.assertEqual(body["Labels"][spark_switch.LABEL_MANAGED], "1")
        hc = body["HostConfig"]
        self.assertEqual(
            hc["Binds"], ["/home/tester/.cache/huggingface:/root/.cache/huggingface"])
        self.assertEqual(
            hc["PortBindings"]["8000/tcp"][0]["HostPort"], "8000")
        self.assertEqual(hc["IpcMode"], "host")
        self.assertEqual(hc["ShmSize"], 67108864)
        self.assertEqual(hc["Ulimits"][0]["Name"], "memlock")
        self.assertEqual(hc["RestartPolicy"], {"Name": "unless-stopped"})
        self.assertEqual(
            hc["DeviceRequests"], [{"Driver": "", "Count": -1,
                                    "Capabilities": [["gpu"]]}])
        self.assertEqual(body["ExposedPorts"], {"8000/tcp": {}})
        self.assertNotIn("Entrypoint", body)

        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "gpt-oss-120b")
        self.assertIsNone(st["target"])
        self.assertIsNone(st["last_error"])


# ---------------------------------------------------------------- 5-7. failures


def failure_routes(docker):
    """stop/delete/create/start succeed; the container exits during loading;
    logs contain both secrets."""
    log_text = ("ERROR: boom while loading; key=" + VLLM_KEY +
                " token=" + TOKEN + "\n")
    routes = [
        ("POST", "/containers/vllm-coder/stop", (204, b"")),
        ("DELETE", "/containers/vllm-coder", (204, b"")),
        ("POST", "/containers/create", (201, b'{"Id":"abc"}')),
        ("POST", "/containers/vllm-coder/start", (204, b"")),
        ("GET", "/containers/vllm-coder/logs", (200, log_text.encode())),
    ]

    def inspect(method, path, body):
        previous = sum(1 for m, p, b in docker.calls[:-1]
                       if m == "GET" and p == "/containers/vllm-coder/json")
        if previous == 0:  # first switch: container dies during loading
            return 200, inspect_body(running=False, exit_code=137)
        return 200, inspect_body(running=True)  # recovery stays up

    routes.append(("GET", "/containers/vllm-coder/json", inspect))
    return routes


class SwitchFailureTests(unittest.TestCase):
    def test_exit_during_loading_triggers_recovery(self):
        docker = FakeDocker()
        docker.routes = failure_routes(docker)
        ctrl, _ = make_controller(docker)
        with self.assertLogs(logging.getLogger("spark-switch"), level="INFO"):
            ctrl.run_switch("gpt-oss-120b", "api")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertEqual(st["current"], "qwen3-coder")
        self.assertIn("exited", st["last_error"])
        self.assertIn("code 137", st["last_error"])
        self.assertIn("boom", st["last_error"])
        self.assertNotIn(VLLM_KEY, st["last_error"])
        self.assertNotIn(TOKEN, st["last_error"])
        self.assertIn("***", st["last_error"])

        creates = docker.calls_matching("POST", "/containers/create")
        self.assertEqual(len(creates), 2)
        second_cmd = creates[1][2]["Cmd"]
        served = second_cmd[second_cmd.index("--served-model-name") + 1]
        self.assertEqual(served, "qwen3-coder")
        self.assertIn("recovery", st["last_error"].lower())

    def test_ready_timeout_fails_then_recovers(self):
        def never_lists(url, headers, timeout):
            if url.endswith("/v1/models"):
                return 200, json.dumps({"data": [{"id": "something-else"}]}).encode()
            return 200, b""

        docker = FakeDocker()
        docker.routes = failure_routes(docker)
        ctrl, _ = make_controller(docker, http_get=never_lists,
                                  ready_timeout=15, ready_poll_seconds=5)
        with self.assertLogs(logging.getLogger("spark-switch"), level="INFO"):
            ctrl.run_switch("gpt-oss-120b", "api")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIn("not ready after 15 s", st["last_error"])
        creates = docker.calls_matching("POST", "/containers/create")
        self.assertEqual(len(creates), 2)  # original + one recovery

    def test_default_failure_has_no_recovery(self):
        log_text = "fatal; " + VLLM_KEY + "\n"
        docker = FakeDocker([
            ("POST", "/containers/vllm-coder/stop", (204, b"")),
            ("DELETE", "/containers/vllm-coder", (204, b"")),
            ("POST", "/containers/create", (201, b'{"Id":"abc"}')),
            ("POST", "/containers/vllm-coder/start", (204, b"")),
            ("GET", "/containers/vllm-coder/json",
             (200, inspect_body(running=False, exit_code=1))),
            ("GET", "/containers/vllm-coder/logs", (200, log_text.encode())),
        ])
        ctrl, _ = make_controller(docker)
        with self.assertLogs(logging.getLogger("spark-switch"), level="INFO"):
            ctrl.run_switch("qwen3-coder", "api")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIsNone(st["current"])
        self.assertIn("exited", st["last_error"])
        self.assertEqual(len(docker.calls_matching("POST", "/containers/create")), 1)

    def test_stop_timeout_exception_ends_failed_not_switching(self):
        """A stop whose socket read times out raises TimeoutError; it must be
        converted to a switch failure, recovered, and the state must end
        terminal so the next /switch is accepted."""

        class StopTimesOut(FakeDocker):
            def request(self, method, path, body=None, timeout=None):
                if (method == "POST"
                        and path.startswith("/containers/vllm-coder/stop")):
                    raise TimeoutError("stop timed out")
                return super().request(method, path, body, timeout)

        docker = StopTimesOut(list(SWITCH_ROUTES))
        ctrl, _ = make_controller(docker)
        with self.assertLogs(logging.getLogger("spark-switch"), level="INFO"):
            ctrl.run_switch("gpt-oss-120b", "api")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")  # never "switching"
        self.assertIsNone(st["current"])
        self.assertIn("TimeoutError", st["last_error"])
        self.assertIn("stop", st["last_error"])
        # a new switch is accepted right away (no permanent 409)
        status, _ = ctrl.request_switch("qwen3-next-80b")
        self.assertEqual(status, 202)

    def test_unexpected_exceptions_end_failed_not_switching(self):
        """Exceptions that are not SwitchFailure (main attempt and recovery)
        must still follow the failure/recovery path and end terminal."""

        class Boom(FakeDocker):
            def __init__(self, routes=None):
                super().__init__(routes)
                self.stop_calls = 0

            def request(self, method, path, body=None, timeout=None):
                if (method == "POST"
                        and path.startswith("/containers/vllm-coder/stop")):
                    self.stop_calls += 1
                    raise RuntimeError("docker socket vanished")
                return super().request(method, path, body, timeout)

        docker = Boom(list(SWITCH_ROUTES))
        ctrl, _ = make_controller(docker)
        with self.assertLogs(logging.getLogger("spark-switch"), level="INFO"):
            ctrl.run_switch("gpt-oss-120b", "api")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIsNone(st["current"])
        self.assertIn("RuntimeError", st["last_error"])
        self.assertGreaterEqual(docker.stop_calls, 2)  # main attempt + recovery
        status, _ = ctrl.request_switch("qwen3-next-80b")
        self.assertEqual(status, 202)  # accepted, not 409

    def test_guarded_spawn_converts_worker_crash_to_failed(self):
        """A worker that raises through every handler (here: a broken
        run_switch) must end failed, not stuck switching."""
        ctrl, _ = make_controller(FakeDocker(list(SWITCH_ROUTES)))

        def broken(target, reason):
            raise RuntimeError("worker exploded before any handler")

        ctrl.run_switch = broken
        status, _ = ctrl.request_switch("gpt-oss-120b")
        self.assertEqual(status, 202)
        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIn("RuntimeError", st["last_error"])
        status, _ = ctrl.request_switch("qwen3-next-80b")
        self.assertEqual(status, 202)

    def test_stop_socket_timeout_exceeds_stop_timeout(self):
        """The stop request's socket timeout must outlive the stop_timeout we
        ask Docker for, or a slow container kill kills the request instead."""
        docker = FakeDocker(list(SWITCH_ROUTES))
        inner = docker.request
        seen = {}

        def record(method, path, body=None, timeout=None):
            if "/stop" in path:
                seen["timeout"] = timeout
            return inner(method, path, body, timeout)

        docker.request = record
        ctrl, _ = make_controller(docker, stop_timeout=90)
        ctrl.run_switch("gpt-oss-120b", "api")
        self.assertIsNotNone(seen.get("timeout"))
        self.assertGreaterEqual(seen["timeout"], 90 + 30)


# ---------------------------------------------------------------- 8. request_switch


class RequestSwitchTests(unittest.TestCase):
    def _ready_controller(self, profile="qwen3-coder", docker=None, spawn=sync_spawn):
        if docker is None:
            docker = FakeDocker([(
                "GET", "/containers/vllm-coder/json",
                (200, inspect_body(
                    running=True,
                    labels={spark_switch.LABEL_PROFILE: profile})))])
            http_get = models_http(profile)  # adopt probe lists the profile
        else:
            http_get = smart_http(docker)    # switches answer what they create
        ctrl, clock = make_controller(docker, spawn=spawn, http_get=http_get)
        ctrl.adopt()
        return ctrl, clock, docker

    def test_unknown_profile_is_400(self):
        ctrl, _, _ = self._ready_controller()
        status, payload = ctrl.request_switch("nope")
        self.assertEqual(status, 400)
        self.assertIn("error", payload)

    def test_already_current_ready_is_200(self):
        ctrl, _, _ = self._ready_controller()
        status, payload = ctrl.request_switch("qwen3-coder")
        self.assertEqual(status, 200)
        self.assertFalse(payload["changed"])
        self.assertEqual(payload["current"], "qwen3-coder")

    def test_while_switching_is_409(self):
        ctrl, _, _ = self._ready_controller(spawn=noop_spawn)
        status, _ = ctrl.request_switch("gpt-oss-120b")
        self.assertEqual(status, 202)
        status, payload = ctrl.request_switch("qwen3-next-80b")
        self.assertEqual(status, 409)
        self.assertEqual(payload["target"], "gpt-oss-120b")

    def test_cooldown_is_429_then_default_allowed(self):
        docker = FakeDocker(list(SWITCH_ROUTES))
        ctrl, clock, docker = self._ready_controller(docker=docker)
        status, _ = ctrl.request_switch("gpt-oss-120b")
        self.assertEqual(status, 202)  # sync spawn: switch completes
        self.assertEqual(ctrl.status()["state"], "ready")

        status, payload = ctrl.request_switch("qwen3-next-80b")
        self.assertEqual(status, 429)
        self.assertIsInstance(payload["retry_after"], int)
        self.assertGreaterEqual(payload["retry_after"], 1)
        self.assertLessEqual(payload["retry_after"], 120)

        status, payload = ctrl.request_switch("default")
        self.assertEqual(status, 202)
        self.assertEqual(ctrl.status()["current"], "qwen3-coder")

    def test_default_alias_maps_to_default_profile(self):
        ctrl, _, _ = self._ready_controller()
        status, payload = ctrl.request_switch("default")
        self.assertEqual(status, 200)
        self.assertEqual(payload["current"], "qwen3-coder")


# ---------------------------------------------------------------- 9-10. idle / metrics


METRICS_TEMPLATE = (
    "# HELP vllm:num_requests_running help text\n"
    "# TYPE vllm:num_requests_running gauge\n"
    "vllm:num_requests_running{{model_name=\"{m}\"}} {running}\n"
    "vllm:num_requests_waiting{{model_name=\"{m}\"}} {waiting}\n"
    "vllm:request_success_total{{model_name=\"{m}\",finished_reason=\"stop\"}} {stop}\n"
    "vllm:request_success_total{{model_name=\"{m}\",finished_reason=\"length\"}} {length}\n"
    "vllm:gpu_cache_usage_perc{{model_name=\"{m}\"}} 0.42\n"
)


class IdleTests(unittest.TestCase):
    def _controller(self, metrics_text, idle_minutes=30):
        docker = FakeDocker(list(SWITCH_ROUTES))

        def http_get(url, headers, timeout):
            if url.endswith("/metrics"):
                return 200, metrics_text.encode()
            return smart_http(docker)(url, headers, timeout)

        ctrl, clock = make_controller(docker, http_get=http_get,
                                      idle_minutes=idle_minutes)
        with ctrl._lock:
            ctrl._s.current = "gpt-oss-120b"
            ctrl._s.state = "ready"
            ctrl._s.last_activity = clock.t
        return ctrl, clock, docker

    def _creates(self, docker):
        return docker.calls_matching("POST", "/containers/create")

    def test_idle_expiry_triggers_switch_to_default(self):
        ctrl, clock, docker = self._controller(
            METRICS_TEMPLATE.format(m="m", running=0, waiting=0, stop=1, length=1))
        ctrl.idle_tick()  # first tick only records the success total
        self.assertEqual(len(self._creates(docker)), 0)
        clock.t += 31 * 60
        ctrl.idle_tick()
        self.assertGreater(len(self._creates(docker)), 0)
        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "qwen3-coder")
        self.assertEqual(st["reason"], "idle")

    def test_running_requests_reset_timer(self):
        ctrl, clock, docker = self._controller(
            METRICS_TEMPLATE.format(m="m", running=3, waiting=1, stop=1, length=1))
        ctrl.idle_tick()
        clock.t += 31 * 60
        ctrl.idle_tick()
        self.assertEqual(len(self._creates(docker)), 0)
        self.assertIsNotNone(ctrl.status()["idle_return_at"])
        self.assertGreater(ctrl.status()["idle_return_at"], clock.t)

    def test_success_counter_change_resets_timer(self):
        ctrl, clock, docker = self._controller(
            METRICS_TEMPLATE.format(m="m", running=0, waiting=0, stop=1, length=1))
        ctrl.idle_tick()  # records success total = 2.0
        clock.t += 31 * 60

        # metrics now report a higher success total (finished requests)
        new_text = METRICS_TEMPLATE.format(
            m="m", running=0, waiting=0, stop=5, length=1)

        def http_get(url, headers, timeout):
            if url.endswith("/metrics"):
                return 200, new_text.encode()
            return smart_http(docker)(url, headers, timeout)

        ctrl.http_get = http_get
        ctrl.idle_tick()  # success total changed -> counts as activity
        self.assertEqual(len(self._creates(docker)), 0)
        self.assertGreater(ctrl.status()["idle_return_at"], clock.t)

    def test_metrics_fetch_failure_never_triggers(self):
        docker = FakeDocker(list(SWITCH_ROUTES))

        def http_get(url, headers, timeout):
            if url.endswith("/metrics"):
                return 0, b""
            return smart_http(docker)(url, headers, timeout)

        ctrl, clock = make_controller(docker, http_get=http_get)
        with ctrl._lock:
            ctrl._s.current = "gpt-oss-120b"
            ctrl._s.state = "ready"
            ctrl._s.last_activity = clock.t - 10 * 3600
        ctrl.idle_tick()
        self.assertEqual(len(self._creates(docker)), 0)

    def test_default_current_never_triggers(self):
        ctrl, clock, docker = self._controller(
            METRICS_TEMPLATE.format(m="m", running=0, waiting=0, stop=1, length=1))
        with ctrl._lock:
            ctrl._s.current = "qwen3-coder"
        clock.t += 31 * 60
        ctrl.idle_tick()
        self.assertEqual(len(self._creates(docker)), 0)

    def test_idle_minutes_zero_never_triggers(self):
        ctrl, clock, docker = self._controller(
            METRICS_TEMPLATE.format(m="m", running=0, waiting=0, stop=1, length=1),
            idle_minutes=0)
        clock.t += 10 * 3600
        ctrl.idle_tick()
        self.assertEqual(len(self._creates(docker)), 0)

    def test_no_trigger_while_switching(self):
        ctrl, clock, docker = self._controller(
            METRICS_TEMPLATE.format(m="m", running=0, waiting=0, stop=1, length=1))
        ctrl._spawn = noop_spawn
        status, _ = ctrl.request_switch("qwen3-next-80b")
        self.assertEqual(status, 202)
        clock.t += 31 * 60
        ctrl.idle_tick()
        self.assertEqual(len(self._creates(docker)), 0)

    def test_switch_during_metrics_probe_aborts_idle_return(self):
        """The metrics probe runs unlocked for up to 10 s. If a user switch
        completes meanwhile, the tick must do nothing instead of returning to
        the default profile and killing the model the user just loaded."""
        docker = FakeDocker(list(SWITCH_ROUTES))
        base = smart_http(docker)
        metrics = METRICS_TEMPLATE.format(
            m="m", running=0, waiting=0, stop=1, length=1).encode()

        ctrl, clock = make_controller(docker, idle_minutes=30)
        with ctrl._lock:
            ctrl._s.current = "gpt-oss-120b"
            ctrl._s.state = "ready"
            ctrl._s.last_activity = clock.t - 31 * 60  # idle already expired

        def racing_get(url, headers, timeout):
            if url.endswith("/metrics"):
                # While idle_tick holds no lock, a user switch completes.
                status, _ = ctrl.request_switch("qwen3-next-80b")
                self.assertEqual(status, 202)
                return 200, metrics
            return base(url, headers, timeout)

        ctrl.http_get = racing_get
        ctrl.idle_tick()

        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "qwen3-next-80b")  # user's model kept
        self.assertEqual(st["reason"], "api")               # no idle return ran


class ParseMetricsTests(unittest.TestCase):
    def test_sums_labeled_samples_and_ignores_the_rest(self):
        text = (
            "# HELP vllm:num_requests_running gauge\n"
            "vllm:num_requests_running{model_name=\"a\"} 1\n"
            "vllm:num_requests_running{model_name=\"b\"} 2\n"
            "vllm:num_requests_waiting{model_name=\"a\"} 0\n"
            "vllm:num_requests_waiting{model_name=\"b\"} 1\n"
            "vllm:request_success_total{model_name=\"a\",finished_reason=\"stop\"} 5\n"
            "vllm:request_success_total{model_name=\"b\",finished_reason=\"length\"} 7.5\n"
            "vllm:gpu_cache_usage_perc{model_name=\"a\"} 0.9\n"
            "something_else_total 100\n"
            "\n")
        result = spark_switch.parse_metrics(text)
        self.assertEqual(result["vllm:num_requests_running"], 3.0)
        self.assertEqual(result["vllm:num_requests_waiting"], 1.0)
        self.assertEqual(result["vllm:request_success_total"], 12.5)
        self.assertEqual(
            set(result),
            {"vllm:num_requests_running", "vllm:num_requests_waiting",
             "vllm:request_success_total"})


# ---------------------------------------------------------------- 10.5 docker transport


class DockerAPITests(unittest.TestCase):
    def test_socket_error_becomes_switch_failure(self):
        api = spark_switch.DockerAPI("/nonexistent/docker.sock")
        with self.assertRaises(spark_switch.SwitchFailure) as cm:
            api.request("GET", "/version")
        # short message: method+path and the exception type, nothing else
        self.assertIn("GET /version", str(cm.exception))
        self.assertIn("FileNotFoundError", str(cm.exception))

    def test_http_exception_becomes_switch_failure(self):
        api = spark_switch.DockerAPI("/var/run/docker.sock")

        class DeadConn:
            def __init__(self, *a, **k):
                pass

            def request(self, method, path, body=None, headers=None):
                raise http.client.HTTPException("connection went away")

            def close(self):
                pass

        original = spark_switch.UnixHTTPConnection
        spark_switch.UnixHTTPConnection = DeadConn
        try:
            with self.assertRaises(spark_switch.SwitchFailure) as cm:
                api.request("POST", "/containers/vllm-coder/stop?t=60")
        finally:
            spark_switch.UnixHTTPConnection = original
        self.assertIn("POST /containers/vllm-coder/stop", str(cm.exception))
        self.assertIn("HTTPException", str(cm.exception))


# ---------------------------------------------------------------- 11. docker logs


class DecodeDockerLogsTests(unittest.TestCase):
    def test_multiplexed_frames(self):
        def frame(stream, payload):
            return struct.pack(">Bxxx", stream) + struct.pack(">I", len(payload)) + payload

        data = (frame(1, b"stdout line\n") + frame(2, b"stderr line\n"))
        self.assertEqual(spark_switch.decode_docker_logs(data),
                         "stdout line\nstderr line\n")

    def test_plain_text_fallback(self):
        data = b"plain text without any header"
        self.assertEqual(spark_switch.decode_docker_logs(data), data.decode())


# ---------------------------------------------------------------- 12. HTTP server


class HTTPServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        docker = FakeDocker([(
            "GET", "/containers/vllm-coder/json",
            (200, inspect_body(
                running=True,
                labels={spark_switch.LABEL_PROFILE: "qwen3-coder"})))])
        cls.ctrl, _ = make_controller(docker, spawn=noop_spawn,
                                      http_get=models_http("qwen3-coder"))
        cls.ctrl.adopt()
        cls.server = spark_switch.make_server(cls.ctrl, "127.0.0.1", 0)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def _request(self, method, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(method, path, body=body, headers=headers or {})
            resp = conn.getresponse()
            data = resp.read()
            return resp.status, data
        finally:
            conn.close()

    def test_health_without_auth(self):
        status, data = self._request("GET", "/health")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data), {"ok": True})

    def test_status_requires_token(self):
        status, _ = self._request("GET", "/status")
        self.assertEqual(status, 401)
        status, _ = self._request(
            "GET", "/status", headers={"Authorization": "Bearer wrong-token"})
        self.assertEqual(status, 401)

    def test_status_with_token_and_no_secrets(self):
        status, data = self._request(
            "GET", "/status", headers={"Authorization": "Bearer " + TOKEN})
        self.assertEqual(status, 200)
        payload = json.loads(data)
        self.assertEqual(payload["state"], "ready")
        self.assertEqual(payload["default"], "qwen3-coder")
        self.assertNotIn(TOKEN, data.decode())
        self.assertNotIn(VLLM_KEY, data.decode())

    def test_switch_body_too_large(self):
        status, _ = self._request(
            "POST", "/switch", body=b"x" * 5000,
            headers={"Authorization": "Bearer " + TOKEN,
                     "Content-Type": "application/json"})
        self.assertEqual(status, 413)

    def test_switch_invalid_json(self):
        status, _ = self._request(
            "POST", "/switch", body=b"{not json",
            headers={"Authorization": "Bearer " + TOKEN,
                     "Content-Type": "application/json"})
        self.assertEqual(status, 400)

    def test_switch_missing_profile(self):
        status, _ = self._request(
            "POST", "/switch", body=json.dumps({"nope": 1}).encode(),
            headers={"Authorization": "Bearer " + TOKEN,
                     "Content-Type": "application/json"})
        self.assertEqual(status, 400)

    def test_switch_valid_returns_202(self):
        status, data = self._request(
            "POST", "/switch", body=json.dumps({"profile": "gpt-oss-120b"}).encode(),
            headers={"Authorization": "Bearer " + TOKEN,
                     "Content-Type": "application/json"})
        self.assertEqual(status, 202)
        payload = json.loads(data)
        self.assertEqual(payload["state"], "switching")
        self.assertEqual(payload["target"], "gpt-oss-120b")

    def test_unknown_path_404(self):
        status, _ = self._request(
            "GET", "/nope", headers={"Authorization": "Bearer " + TOKEN})
        self.assertEqual(status, 404)

    def _raw_post(self, content_length, send_body=b""):
        """One hand-rolled POST /switch with a chosen Content-Length. Returns
        the first response bytes; used for lengths http.client would never
        send (negative, absurdly large) without ever transmitting the body."""
        sock = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        try:
            head = (
                "POST /switch HTTP/1.1\r\n"
                "Host: t\r\n"
                "Authorization: Bearer " + TOKEN + "\r\n"
                "Content-Length: " + str(content_length) + "\r\n"
                "\r\n").encode()
            sock.sendall(head + send_body)
            data = b""
            try:
                while b"\r\n\r\n" not in data:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    data += chunk
            except socket.timeout:
                pass
            return data
        finally:
            sock.close()

    def test_negative_content_length_rejected_without_reading(self):
        # Content-Length: -1 must never reach rfile.read: read(-1) would
        # block until EOF (and a bodyless client would hang the thread). The
        # answer must arrive without any body being sent.
        data = self._raw_post(-1)
        self.assertTrue(data)
        self.assertIn(b"400", data.split(b"\r\n", 1)[0])

    def test_absurd_content_length_answered_without_body(self):
        # A declared length far over the limit is answered immediately; the
        # body is neither waited for nor read.
        data = self._raw_post(99999999)
        self.assertTrue(data)
        self.assertIn(b"413", data.split(b"\r\n", 1)[0])

    def test_handler_has_read_timeout(self):
        # Every connection gets a socket read timeout, so a client that
        # stalls mid-request (slow-loris) is dropped instead of parking a
        # thread forever.
        self.assertEqual(self.server.RequestHandlerClass.timeout, 30)


# ---------------------------------------------------------------- 13. logging


class LoggingSecretsTests(unittest.TestCase):
    def test_switch_failure_logs_never_contain_secrets(self):
        docker = FakeDocker()
        docker.routes = failure_routes(docker)
        ctrl, _ = make_controller(docker)
        with self.assertLogs(logging.getLogger("spark-switch"), level="INFO") as cm:
            ctrl.run_switch("gpt-oss-120b", "api")
        text = "\n".join(r.getMessage() for r in cm.records)
        self.assertNotIn(VLLM_KEY, text)
        self.assertNotIn(TOKEN, text)

    def test_http_logs_never_contain_secrets(self):
        docker = FakeDocker([(
            "GET", "/containers/vllm-coder/json",
            (200, inspect_body(
                running=True,
                labels={spark_switch.LABEL_PROFILE: "qwen3-coder"})))])
        ctrl, _ = make_controller(docker, spawn=noop_spawn,
                                  http_get=models_http("qwen3-coder"))
        ctrl.adopt()
        server = spark_switch.make_server(ctrl, "127.0.0.1", 0)
        port = server.server_address[1]
        t = threading.Thread(target=server.serve_forever, daemon=True)
        t.start()
        try:
            with self.assertLogs(logging.getLogger("spark-switch"), level="INFO") as cm:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                conn.request("GET", "/status?extra=1",
                             headers={"Authorization": "Bearer " + TOKEN})
                resp = conn.getresponse()
                resp.read()
                conn.close()
            self.assertEqual(resp.status, 200)
            text = "\n".join(r.getMessage() for r in cm.records)
            self.assertNotIn(TOKEN, text)
            self.assertNotIn(VLLM_KEY, text)
            for record in cm.records:
                if "/status" in record.getMessage():
                    self.assertNotIn("extra=1", record.getMessage())
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
