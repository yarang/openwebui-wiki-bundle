#!/usr/bin/env python3
"""spark-switch: one-model-at-a-time vLLM profile controller for DGX Spark.

Runs either as a Docker container with the host Docker socket mounted
(BACKEND=docker, the default) or as a pod on single-node k3s
(BACKEND=kubernetes, patching one Deployment). The state machine, cooldown,
idle return, recovery and secret redaction are identical for both; only the
container-touching code differs, and it lives behind the backend interface
(spark_backend_docker / spark_backend_kube).
"""

from __future__ import annotations

import argparse
import hmac
import http.client
import http.server
import json
import logging
import os
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field

# Shared definitions (exceptions are THESE classes everywhere: backends
# import from spark_common, never from spark_switch, so there is no cycle).
from spark_common import (LABEL_MANAGED, LABEL_PROFILE, MAX_ERROR_CHARS,
                          ConfigError, Observed, ProfileError, SwitchFailure)
from spark_backend_docker import (DockerBackend, build_create_body,
                                  decode_docker_logs)  # noqa: F401 (re-export)

log = logging.getLogger("spark-switch")

MAX_BODY_BYTES = 4096


# --------------------------------------------------------------------------
# Config


@dataclass
class Config:
    switch_host: str = "0.0.0.0"
    switch_port: int = 8010
    switch_token: str = ""
    backend: str = "docker"           # "docker" | "kubernetes"
    managed_container: str = "vllm-coder"
    vllm_image: str = "nvcr.io/nvidia/vllm:26.02-py3"
    # Offline (air-gapped) install: inject HF_HUB_OFFLINE / TRANSFORMERS_
    # OFFLINE / TIKTOKEN_ENCODINGS_BASE into the vLLM container (Docker
    # backend only; the k8s backend gets them from offline-env-patch.yaml).
    vllm_offline: bool = False
    vllm_url: str = "http://host.docker.internal:8000"
    vllm_host_port: int = 8000
    vllm_env_file: str = "/config/vllm-env"
    vllm_api_key: str = ""
    hf_cache_host: str = ""
    profiles_file: str = "/app/profiles.json"
    default_profile: str = "qwen3-coder"
    # Pair (resident) mode: comma list of profiles that live side by side in
    # slots 0..N-1. Empty = feature off = exactly the single-container
    # behaviour. resident_names is the parsed form load_config fills in.
    resident_profiles: str = ""
    resident_names: list = field(default_factory=list)
    # Wait for unified memory to be released before creating slot containers
    # (vLLM sizes its KV cache from the memory free at startup). 0 = off.
    mem_wait_timeout: int = 0
    mem_margin_gb: float = 4.0
    meminfo_path: str = "/proc/meminfo"
    idle_minutes: int = 30
    idle_poll_seconds: int = 60
    cooldown_seconds: int = 120
    ready_timeout: int = 1800
    ready_poll_seconds: int = 5
    stop_timeout: int = 60
    docker_sock: str = "/var/run/docker.sock"
    k8s_namespace: str = "spark-llm"
    k8s_deployment: str = "vllm-coder"
    k8s_container: str = "vllm"
    k8s_pod_selector: str = "app=vllm-coder"
    unschedulable_seconds: int = 120


def parse_bool(value):
    """Boolean env values for keys like VLLM_OFFLINE: exactly "1" or "0"."""
    v = str(value).strip()
    if v == "1":
        return True
    if v == "0":
        return False
    raise ValueError(f"expected 1 or 0, got {value!r}")


_ENV_KEYS = {
    "SWITCH_HOST": ("switch_host", str),
    "SWITCH_PORT": ("switch_port", int),
    "SWITCH_TOKEN": ("switch_token", str),
    "BACKEND": ("backend", str),
    "MANAGED_CONTAINER": ("managed_container", str),
    "VLLM_IMAGE": ("vllm_image", str),
    "VLLM_OFFLINE": ("vllm_offline", parse_bool),
    "VLLM_URL": ("vllm_url", str),
    "VLLM_HOST_PORT": ("vllm_host_port", int),
    "VLLM_ENV_FILE": ("vllm_env_file", str),
    "HF_CACHE_HOST": ("hf_cache_host", str),
    "PROFILES_FILE": ("profiles_file", str),
    "DEFAULT_PROFILE": ("default_profile", str),
    "RESIDENT_PROFILES": ("resident_profiles", str),
    "MEM_WAIT_TIMEOUT": ("mem_wait_timeout", int),
    "MEM_MARGIN_GB": ("mem_margin_gb", float),
    "MEMINFO_PATH": ("meminfo_path", str),
    "IDLE_MINUTES": ("idle_minutes", int),
    "IDLE_POLL_SECONDS": ("idle_poll_seconds", int),
    "COOLDOWN_SECONDS": ("cooldown_seconds", int),
    "READY_TIMEOUT": ("ready_timeout", int),
    "READY_POLL_SECONDS": ("ready_poll_seconds", int),
    "STOP_TIMEOUT": ("stop_timeout", int),
    "DOCKER_SOCK": ("docker_sock", str),
    "K8S_NAMESPACE": ("k8s_namespace", str),
    "K8S_DEPLOYMENT": ("k8s_deployment", str),
    "K8S_CONTAINER": ("k8s_container", str),
    "K8S_POD_SELECTOR": ("k8s_pod_selector", str),
    "UNSCHEDULABLE_SECONDS": ("unschedulable_seconds", int),
}



def parse_env_text(text: str) -> dict:
    """Parse KEY=VALUE lines; '#' comments, blanks, optional 'export ' and
    optional single/double quotes around the value are tolerated."""
    out = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if key:
            out[key] = value
    return out


def load_config(env_file: str, environ: dict) -> Config:
    """Load the controller config. Process environment wins over the env file.

    The env file itself must not be readable or writable by group/other.
    The vLLM API key from VLLM_ENV_FILE is kept in memory only.
    """
    file_values = {}
    if os.path.exists(env_file):
        st = os.stat(env_file)
        if st.st_mode & 0o077:
            raise ConfigError(
                f"{env_file}: mode {oct(st.st_mode & 0o777)} is too open; "
                "chmod 600 required (no group/other access)"
            )
        with open(env_file, encoding="utf-8") as f:
            file_values = parse_env_text(f.read())

    values = dict(file_values)
    for key in _ENV_KEYS:
        if key in environ and environ[key] != "":
            values[key] = environ[key]

    cfg = Config()
    for key, (attr, cast) in _ENV_KEYS.items():
        if key in values:
            try:
                setattr(cfg, attr, cast(values[key]))
            except (TypeError, ValueError):
                raise ConfigError(f"{key}={values[key]!r} is not a valid {cast.__name__}")

    if len(cfg.switch_token) < 24:
        raise ConfigError("SWITCH_TOKEN must be set and at least 24 characters")
    if cfg.backend not in ("docker", "kubernetes"):
        raise ConfigError(
            f"BACKEND must be 'docker' or 'kubernetes', not {cfg.backend!r}")
    if cfg.backend == "docker":
        # The k8s backend never creates containers itself (the manifests do),
        # so there is no host cache path to bind-mount.
        if not cfg.hf_cache_host or not os.path.isabs(cfg.hf_cache_host):
            raise ConfigError(
                "HF_CACHE_HOST must be an absolute host path "
                "(e.g. /home/<user>/.cache/huggingface)"
            )
    if not (1 <= cfg.switch_port <= 65535):
        raise ConfigError("SWITCH_PORT out of range")
    if not (1 <= cfg.vllm_host_port <= 65535):
        raise ConfigError("VLLM_HOST_PORT out of range")

    # Pair (resident) mode: shape checks here; existence of each profile is
    # verified by the Controller, which knows the profile table.
    cfg.resident_names = parse_resident_profiles(cfg.resident_profiles)
    if cfg.resident_names and cfg.backend != "docker":
        raise ConfigError(
            "RESIDENT_PROFILES requires BACKEND=docker (the Kubernetes "
            "backend manages a single Deployment)")

    # vLLM API key: the process environment wins (in k8s it arrives via
    # secretKeyRef); otherwise parse VLLM_ENV_FILE. Kept in memory only,
    # never logged.
    env_key = environ.get("VLLM_API_KEY", "")
    if env_key:
        cfg.vllm_api_key = env_key
    elif os.path.exists(cfg.vllm_env_file):
        st = os.stat(cfg.vllm_env_file)
        if st.st_mode & 0o077:
            # Warn, do not refuse: the file is mounted read-only into this
            # container, so the controller cannot fix it — the host must.
            log.warning(
                "%s is readable by group/others (mode %s); the vLLM API key "
                "may be exposed. Run on the host: chmod 600 %s",
                cfg.vllm_env_file, oct(st.st_mode & 0o777), cfg.vllm_env_file)
        with open(cfg.vllm_env_file, encoding="utf-8") as f:
            cfg.vllm_api_key = parse_env_text(f.read()).get("VLLM_API_KEY", "")
    return cfg


def parse_resident_profiles(raw):
    """RESIDENT_PROFILES comma list -> [profile names]; empty list when the
    feature is off. Validates the shape only (at least two names, no
    duplicates); whether the profiles exist is checked where the profile
    table is known (Controller.__init__)."""
    names = [n.strip() for n in str(raw or "").split(",")]
    names = [n for n in names if n]
    if not names:
        return []
    if len(names) < 2:
        raise ConfigError(
            "RESIDENT_PROFILES must list at least 2 profiles "
            "(comma-separated)")
    if len(set(names)) != len(names):
        raise ConfigError("RESIDENT_PROFILES lists a profile twice")
    return names


# --------------------------------------------------------------------------
# Profiles

_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
_MODEL_RE = re.compile(r"^[A-Za-z0-9._/-]{1,200}$")
_ARG_RE = re.compile(r"^[A-Za-z0-9._:/=,+-]{1,200}$")
_FORBIDDEN_ARG_PREFIXES = ("--host", "--port", "--served-model-name", "--api-key")


@dataclass
class Profile:
    name: str
    model: str
    description: str = ""
    kind: str = "text"
    verified: bool = False
    args: list = field(default_factory=list)


def load_profiles(path: str) -> dict:
    """Load and validate the profile table (name -> Profile)."""
    with open(path, encoding="utf-8") as f:
        try:
            raw = json.load(f)
        except json.JSONDecodeError as e:
            raise ProfileError(f"{path}: invalid JSON ({e})")
    if not isinstance(raw, dict):
        raise ProfileError(f"{path}: must be a JSON object of profiles")

    profiles = {}
    for name, obj in raw.items():
        if name == "default":
            raise ProfileError('"default" is a reserved profile name')
        if name == "pair":
            raise ProfileError('"pair" is a reserved profile name')
        if not isinstance(name, str) or not _NAME_RE.match(name):
            raise ProfileError(f"invalid profile name: {name!r}")
        if not isinstance(obj, dict):
            raise ProfileError(f"profile {name!r}: must be an object")

        model = obj.get("model")
        if not isinstance(model, str) or not _MODEL_RE.match(model):
            raise ProfileError(f"profile {name!r}: invalid model {model!r}")

        kind = obj.get("kind", "text")
        if kind not in ("text", "vision"):
            raise ProfileError(f"profile {name!r}: kind must be text or vision")

        verified = obj.get("verified", False)
        if not isinstance(verified, bool):
            raise ProfileError(f"profile {name!r}: verified must be a boolean")

        description = obj.get("description", "")
        if not isinstance(description, str):
            raise ProfileError(f"profile {name!r}: description must be a string")

        args = obj.get("args", [])
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            raise ProfileError(f"profile {name!r}: args must be a list of strings")
        for a in args:
            if not _ARG_RE.match(a):
                raise ProfileError(f"profile {name!r}: invalid arg {a!r}")
            for prefix in _FORBIDDEN_ARG_PREFIXES:
                if a == prefix or a.startswith(prefix):
                    raise ProfileError(
                        f"profile {name!r}: arg {a!r} conflicts with a "
                        "controller-managed flag"
                    )

        profiles[name] = Profile(
            name=name, model=model, description=description, kind=kind,
            verified=verified, args=list(args),
        )
    return profiles


# --------------------------------------------------------------------------
# Docker Engine API over the unix socket


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, sock_path, timeout=None):
        super().__init__("localhost", timeout=timeout)
        self._sock_path = sock_path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        if self.timeout is not None:
            s.settimeout(self.timeout)
        s.connect(self._sock_path)
        self.sock = s


class DockerAPI:
    def __init__(self, sock_path):
        self.sock_path = sock_path

    def request(self, method, path, body=None, timeout=30):
        """One request over the unix socket. Returns (status, raw bytes).
        Transport failures (socket errors, timeouts, a dead docker socket,
        malformed replies) are converted to SwitchFailure so a worker thread
        can never die on them and leave the state stuck in "switching"."""
        conn = UnixHTTPConnection(self.sock_path, timeout=timeout)
        try:
            payload = None
            headers = {"Host": "localhost"}
            if body is not None:
                payload = json.dumps(body).encode("utf-8")
                headers["Content-Type"] = "application/json"
            conn.request(method, path, body=payload, headers=headers)
            resp = conn.getresponse()
            return resp.status, resp.read()
        except (OSError, http.client.HTTPException, ValueError) as e:
            raise SwitchFailure(
                f"docker {method} {path.split('?', 1)[0]} failed: "
                f"{type(e).__name__}") from e
        finally:
            conn.close()


# --------------------------------------------------------------------------
# vLLM HTTP access (injectable)


def _default_http_get(url, headers, timeout):
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.read()
        except Exception:
            return e.code, b""
    except (urllib.error.URLError, OSError, socket.timeout):
        return 0, b""


# --------------------------------------------------------------------------
# Prometheus metrics parsing


_METRICS_OF_INTEREST = (
    "vllm:num_requests_running",
    "vllm:num_requests_waiting",
    "vllm:request_success_total",
)


def parse_metrics(text: str) -> dict:
    """Sum all samples (any labels) of the metrics we care about."""
    totals = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        base = parts[0].split("{", 1)[0]
        if base not in _METRICS_OF_INTEREST:
            continue
        try:
            value = float(parts[-1])
        except ValueError:
            continue
        totals[base] = totals.get(base, 0.0) + value
    return totals


# --------------------------------------------------------------------------
# Pair-mode helpers


def slot_url(base_url, index):
    """The vLLM URL of slot `index`: VLLM_URL with its port replaced by
    (port + index). Scheme/host/path are kept; a URL without an explicit
    port uses the scheme default (80/443) as the base."""
    parts = urllib.parse.urlsplit(base_url)
    port = parts.port
    if port is None:
        port = 443 if parts.scheme == "https" else 80
    netloc = f"{parts.hostname}:{port + index}"
    return urllib.parse.urlunsplit(
        (parts.scheme, netloc, parts.path, parts.query, parts.fragment))


def gpu_memory_utilization(profile):
    """The --gpu-memory-utilization fraction of a profile, accepting both
    the "--flag value" and "--flag=value" forms; 0.9 (vLLM's own default)
    when the flag is absent."""
    args = profile.args
    for i, arg in enumerate(args):
        if arg == "--gpu-memory-utilization" and i + 1 < len(args):
            try:
                return float(args[i + 1])
            except ValueError:
                continue
        if arg.startswith("--gpu-memory-utilization="):
            try:
                return float(arg.split("=", 1)[1])
            except ValueError:
                continue
    return 0.9


def read_meminfo(path):
    """(MemTotal_kb, MemAvailable_kb) from a /proc/meminfo-style file, or
    None when it cannot be read or does not contain both fields."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except OSError:
        return None
    total = avail = None
    for line in lines:
        fields = line.split()
        if len(fields) < 2:
            continue
        if fields[0] == "MemTotal:":
            try:
                total = int(fields[1])
            except ValueError:
                pass
        elif fields[0] == "MemAvailable:":
            try:
                avail = int(fields[1])
            except ValueError:
                pass
    if total is None or avail is None:
        return None
    return total, avail


# --------------------------------------------------------------------------
# Controller


def _default_spawn(target, args):
    threading.Thread(target=target, args=args, daemon=True).start()


@dataclass
class _State:
    state: str = "unknown"        # unknown | ready | switching | failed
    current: str = None           # type: str | None
    target: str = None            # type: str | None
    phase: str = ""
    started_at: float = None      # type: float | None
    finished_at: float = None
    last_error: str = None        # type: str | None
    last_switch_done_at: float = None
    last_activity: float = None
    last_success_total: float = None
    reason: str = None            # type: str | None
    # Bumped on every state transition. idle_tick releases the lock while it
    # probes /metrics; the generation lets it detect that a switch happened
    # in the meantime instead of acting on a stale idle computation.
    generation: int = 0


class Controller:
    def __init__(self, config, profiles, docker,
                 http_get=None, clock=time.time, sleep=time.sleep,
                 spawn=None, backend=None, meminfo=None):
        residents = config.resident_names
        for name in residents:
            if name not in profiles:
                raise ConfigError(
                    f"RESIDENT_PROFILES entry {name!r} is not defined in "
                    f"{config.profiles_file}"
                )
        if config.default_profile == "pair":
            if not residents:
                raise ConfigError(
                    'DEFAULT_PROFILE "pair" requires RESIDENT_PROFILES '
                    "to be set"
                )
        elif config.default_profile not in profiles:
            raise ConfigError(
                f"DEFAULT_PROFILE {config.default_profile!r} is not defined "
                f"in {config.profiles_file}"
            )
        self.config = config
        self.profiles = profiles
        self.docker = docker  # only the Docker backend touches this
        self._backend = (backend if backend is not None
                         else DockerBackend(config, profiles, docker))
        self.http_get = http_get or _default_http_get
        self.clock = clock
        self.sleep = sleep
        self._spawn = spawn or _default_spawn
        # Unified-memory probe for the pre-start wait: () -> (total_kb,
        # avail_kb) or None. Injectable for tests.
        self._meminfo = meminfo or self._read_meminfo
        self._lock = threading.Lock()
        self._s = _State()

    def _read_meminfo(self):
        return read_meminfo(self.config.meminfo_path)

    # -- internals ---------------------------------------------------------

    def _set_phase(self, phase):
        with self._lock:
            self._s.phase = phase

    def _endpoints(self, name):
        """(base_url, served_model_name) pairs to probe for a target or
        current profile name: "pair" maps every resident profile to its slot
        port, any other profile is the single VLLM_URL endpoint (exactly
        what the controller probed before the pair mode existed)."""
        if name == "pair":
            return [(slot_url(self.config.vllm_url, i), served)
                    for i, served in enumerate(self.config.resident_names)]
        return [(self.config.vllm_url, name)]

    def _slot_container(self, index):
        """Container name of slot `index` (matches the Docker backend's
        slot naming; used for the status report)."""
        name = self.config.managed_container
        return name if index == 0 else f"{name}-{index}"

    def _auth_headers(self):
        return {"Authorization": "Bearer " + self.config.vllm_api_key}

    def _redact(self, text):
        for secret in (self.config.vllm_api_key, self.config.switch_token):
            if secret:
                text = text.replace(secret, "***")
        return text

    def _collect_failure(self, reason):
        """Fetch the serving workload's log tail and build a redacted
        failure message. The backend reason is untrusted text (k8s API
        messages, container waiting messages, condition messages) exactly
        like the log tail: the WHOLE combined message is redacted before
        truncation."""
        try:
            tail = self._backend.logs_tail(40)
        except Exception:
            tail = ""
        message = self._redact(reason + "\n" + tail)
        return message[:MAX_ERROR_CHARS]

    # -- adoption ----------------------------------------------------------

    def adopt(self):
        """Adopt the workload that exists at startup, if we can tell which
        profile it serves."""
        try:
            obs = self._backend.inspect()
        except Exception as e:
            log.warning("backend inspect during adopt failed: %s",
                        self._redact(str(e)))
            obs = Observed(None, "unknown", "")
        self._apply_observation(obs, from_drift=False)

    def _apply_observation(self, obs, from_drift, expected_generation=None):
        """Shared adoption logic. With from_drift=True (re-adopt after the
        idle-loop drift check noticed the Deployment changed behind our
        back), every state write re-checks under the lock that no switch
        intervened: a switch may have merely started (state "switching") or
        even started AND finished (generation moved) while the inspection
        ran unlocked; in both cases the drift result is dropped.
        expected_generation is the generation drift_check captured before
        its unlocked inspect; None for startup adoption, which races with
        nothing (the HTTP server is not up yet)."""
        def blocked():
            # must be called while holding self._lock
            return from_drift and (
                self._s.state == "switching"
                or (expected_generation is not None
                    and self._s.generation != expected_generation))

        if obs.state in ("absent", "unknown"):
            with self._lock:
                if blocked():
                    return
                self._s.state, self._s.current = "unknown", None
            log.info("adopted workload: state=unknown current=None")
            return

        current = obs.profile
        if current and obs.state in ("running", "pending"):
            # Record the adopted attempt as ours FIRST, under the lock and
            # only on a path that passes the staleness check: a replace()
            # racing the inspection must never be overwritten by the
            # (possibly stale) inspected values. Then decide whether
            # /v1/models may be trusted at all: while the pod this attempt
            # waits for is not serving yet, the Service still routes to the
            # OLD pod, which on a same-profile rollout answers with the
            # expected id (controller restart mid-rollout) — probing then
            # would report "ready" for a replacement that is absent or
            # still loading. Docker has no rollout gap: its
            # requested_serving() is always True, so behaviour there is
            # unchanged.
            with self._lock:
                if blocked():
                    return
                self._backend.commit_adoption(obs)
            if self._backend.requested_serving():
                # A running workload is only "ready" once vLLM actually
                # lists the profile: after a controller restart during a
                # 10-minute weight load the API is not up yet, and reporting
                # ready too early makes the router send requests that will
                # fail. Probe once — for the pair mode EVERY endpoint must
                # list its resident profile.
                listed = True
                for base_url, served in self._endpoints(current):
                    ok = False
                    hstatus, hbody = self.http_get(
                        base_url.rstrip("/") + "/v1/models",
                        self._auth_headers(), timeout=10)
                    if hstatus == 200:
                        try:
                            ids = [m.get("id")
                                   for m in json.loads(hbody).get("data", [])]
                        except ValueError:
                            ids = []
                        ok = served in ids
                    if not ok:
                        listed = False
                        break
                if listed:
                    now = self.clock()
                    with self._lock:
                        if blocked():
                            return
                        self._s.current = current
                        self._s.state = "ready"
                        self._s.last_activity = now
                    log.info("adopted workload: state=ready current=%s",
                             current)
                    return
            # Not serving yet (or the probe did not list the profile):
            # still loading — adopt it as an in-progress switch to that
            # profile and let the worker wait for readiness only (no
            # stop/create; the wait itself keeps refusing /v1/models until
            # requested_serving() turns True).
            now = self.clock()
            with self._lock:
                if blocked():
                    return
                self._s.current = current
                self._s.state = "switching"
                self._s.target = current
                self._s.reason = "adopt"
                self._s.started_at = now
                self._s.finished_at = None
                self._s.phase = "loading"
                self._s.last_error = None
                self._s.generation += 1
            log.info("adopted workload still loading: current=%s", current)
            self._spawn_guarded(self._adopt_wait, (current,))
            return
        with self._lock:
            if blocked():
                return
            self._s.current = current
            self._s.state = "unknown"
        log.info("adopted workload: state=unknown current=%s", current)

    def drift_check(self):
        """Kube only: notice when the Deployment was changed behind the
        controller's back (kubectl apply with different args, rollout undo)
        and re-adopt what is actually deployed. The inspect runs unlocked;
        if a switch starts — or even starts and finishes — meanwhile, its
        result wins: the generation captured below invalidates the
        (possibly stale) observation at every later write."""
        backend = self._backend
        if not backend.supports_drift_check:
            return
        with self._lock:
            if self._s.state == "switching":
                return
            expected_generation = self._s.generation
        try:
            obs = backend.inspect()
        except Exception as e:
            log.warning("drift inspect failed: %s", self._redact(str(e)))
            return
        if obs.state == "unknown":
            # An API hiccup is not drift.
            return
        with self._lock:
            if (self._s.state == "switching"
                    or self._s.generation != expected_generation):
                return
            current = self._s.current
        if obs.profile == current:
            return
        log.info("drift: deployment reports profile %r but controller state "
                 "has %r; re-adopting", obs.profile, current)
        self._apply_observation(obs, from_drift=True,
                                expected_generation=expected_generation)

    # -- container body ----------------------------------------------------

    def build_create_body(self, profile):
        # Thin delegate to spark_backend_docker.build_create_body, kept for
        # compatibility.
        return build_create_body(self.config, profile)

    # -- switching ---------------------------------------------------------

    def _switch_once(self, target, reason):
        """Drive one full replace cycle. Raises SwitchFailure on error.
        On success, marks the state ready."""
        start_slot = getattr(self._backend, "start_slot", None)
        if start_slot is None:
            # Kubernetes backend: the single-Deployment replace path.
            profile = self.profiles[target]
            try:
                self._backend.replace(profile, self._set_phase)
            except SwitchFailure as e:
                # The backend reports a short reason; attach the redacted
                # log tail of the serving workload.
                raise SwitchFailure(
                    self._collect_failure(str(e))) from None
            self._wait_ready(target, reason)
            return
        # Docker slot path: a normal profile is slot 0 alone; "pair" is
        # every resident profile on slots 0..N-1, in order.
        if target == "pair":
            plan = [(i, self.profiles[name])
                    for i, name in enumerate(self.config.resident_names)]
        else:
            plan = [(0, self.profiles[target])]
        endpoints = self._endpoints(target)
        try:
            self._backend.remove_slots(self._set_phase)
        except SwitchFailure as e:
            raise SwitchFailure(self._collect_failure(str(e))) from None
        self._wait_memory([profile for _, profile in plan])
        for index, profile in plan:
            try:
                start_slot(index, profile, self._set_phase)
            except SwitchFailure as e:
                raise SwitchFailure(self._collect_failure(str(e))) from None
            # vLLM sizes its KV cache from the memory free at startup: the
            # next slot must not start before this one is serving.
            base_url, served = endpoints[index]
            phase = f"loading {served}" if target == "pair" else "loading"
            self._wait_endpoint(base_url, served, phase)
        self._mark_ready(target, reason)

    def _wait_memory(self, profiles):
        """Wait until the unified memory freed by the stopped containers is
        visible before any new slot is created. Disabled
        (MEM_WAIT_TIMEOUT <= 0) or an unreadable meminfo (warned, never
        blocking) both return immediately."""
        cfg = self.config
        if cfg.mem_wait_timeout <= 0:
            return
        mem = self._meminfo()
        if mem is None:
            log.warning("cannot read %s; skipping the memory wait",
                        cfg.meminfo_path)
            return
        total_kb, avail_kb = mem
        need_kb = (sum(gpu_memory_utilization(p) for p in profiles) * total_kb
                   + cfg.mem_margin_gb * 1024 * 1024)
        self._set_phase("waiting-memory")
        started = self.clock()
        while avail_kb < need_kb:
            elapsed = self.clock() - started
            if elapsed >= cfg.mem_wait_timeout:
                raise SwitchFailure(
                    f"memory not released: available "
                    f"{avail_kb / 1048576:.1f} GiB < needed "
                    f"{need_kb / 1048576:.1f} GiB after {int(elapsed)} s")
            self.sleep(cfg.ready_poll_seconds)
            mem = self._meminfo()
            if mem is None:
                log.warning("cannot read %s during the memory wait; "
                            "continuing without it", cfg.meminfo_path)
                return
            avail_kb = mem[1]

    def _wait_ready(self, profile_name, reason):
        """Wait until every endpoint of profile_name lists its served model
        (or the workload dies, or READY_TIMEOUT passes). Raises
        SwitchFailure on failure; on success marks the state ready. Also
        used by adopt for an already-running workload, without any replace
        before it."""
        for base_url, served in self._endpoints(profile_name):
            phase = (f"loading {served}" if profile_name == "pair"
                     else "loading")
            self._wait_endpoint(base_url, served, phase)
        self._mark_ready(profile_name, reason)

    def _wait_endpoint(self, base_url, served_name, phase):
        """Wait until GET <base>/v1/models lists served_name (or the
        workload dies, or READY_TIMEOUT passes; the timeout is per
        endpoint). Raises SwitchFailure on failure."""
        cfg = self.config
        self._set_phase(phase)
        started = self.clock()
        while True:
            now = self.clock()
            if now - started >= cfg.ready_timeout:
                raise SwitchFailure(self._collect_failure(
                    f"not ready after {int(cfg.ready_timeout)} s"))
            why = self._backend.check_alive()
            if why:
                raise SwitchFailure(self._collect_failure(why))
            if not self._backend.requested_serving():
                # The workload this attempt waits for is not serving yet:
                # /v1/models could still be answered by the OLD pod (the
                # Service keeps routing to it until the new one is ready),
                # which on a same-profile replace even lists the expected
                # id. Keep waiting; READY_TIMEOUT above still applies.
                self.sleep(cfg.ready_poll_seconds)
                continue
            hstatus, hbody = self.http_get(
                base_url.rstrip("/") + "/v1/models",
                self._auth_headers(), timeout=10)
            if hstatus == 200:
                try:
                    ids = [m.get("id") for m in json.loads(hbody).get("data", [])]
                except ValueError:
                    ids = []
                if served_name in ids:
                    return
            self.sleep(cfg.ready_poll_seconds)

    def _mark_ready(self, profile_name, reason):
        done = self.clock()
        with self._lock:
            self._s.state = "ready"
            self._s.current = profile_name
            self._s.target = None
            self._s.phase = ""
            self._s.last_error = None
            self._s.last_switch_done_at = done
            self._s.last_activity = done
            self._s.last_success_total = None
            self._s.finished_at = done
            self._s.reason = reason
            self._s.generation += 1
        log.info("switch to %s (reason=%s) is ready", profile_name, reason)

    def run_switch(self, target, reason):
        """Synchronous switch; runs in a worker thread in production.
        Whatever happens, the worker never ends with the state "switching":
        an unexpected exception follows the normal failure/recovery path, and
        anything that still escapes is converted to a terminal "failed"."""
        try:
            self._switch_once(target, reason)
            return
        except SwitchFailure as e:
            first_error = str(e)
        except Exception as e:  # unexpected: same treatment as a failure
            first_error = self._redact(
                f"unexpected {type(e).__name__}: {e}")
        self._recover(target, first_error)

    def _adopt_wait(self, profile_name):
        """Readiness-only wait for a container adopted mid-load (adopt found it
        running but vLLM did not answer for it yet). Runs in a worker thread;
        timeout or exit follows the normal failure + recovery path."""
        try:
            self._wait_ready(profile_name, "adopt")
            return
        except SwitchFailure as e:
            first_error = str(e)
        except Exception as e:
            first_error = self._redact(
                f"unexpected {type(e).__name__}: {e}")
        self._recover(profile_name, first_error)

    def _recover(self, target, first_error):
        """Shared failure path: mark the failed attempt, then one recovery
        attempt back to the default profile (unless the default itself was
        the target). Always leaves a terminal state."""
        default = self.config.default_profile
        log.warning("switch to %s failed: %s", target, first_error)
        if target == default:
            self._mark_failed(None, first_error)
            return

        try:
            self._switch_once(default, "recovery")
        except SwitchFailure as e2:
            self._mark_failed(
                None,
                first_error + f"\nrecovery to {default} failed: {e2}")
            log.warning("recovery to %s failed", default)
            return
        except Exception as e2:  # unexpected during recovery: still terminal
            message = self._redact(f"unexpected {type(e2).__name__}: {e2}")
            self._mark_failed(
                None,
                first_error + f"\nrecovery to {default} crashed: {message}")
            log.warning("recovery to %s crashed: %s", default, message)
            return
        self._mark_failed(
            default,
            first_error + f"\nrecovery to {default} succeeded; "
            "serving default again")
        log.warning("recovery to %s succeeded after failed switch to %s",
                    default, target)

    def _mark_failed(self, current, message):
        """Terminal failure state (current may be the default after a
        successful recovery). The message is stored redacted and bounded."""
        now = self.clock()
        with self._lock:
            self._s.state = "failed"
            self._s.current = current
            self._s.target = None
            self._s.phase = ""
            self._s.last_error = self._redact(message or "")[:MAX_ERROR_CHARS]
            self._s.finished_at = now
            self._s.generation += 1

    def _spawn_guarded(self, worker, args):
        """Start a worker so that even an unexpected crash ends in a terminal
        state instead of leaving "switching" forever (every later /switch
        would then get 409)."""
        def guarded():
            try:
                worker(*args)
            except Exception as e:  # last resort; never stay "switching"
                message = self._redact(
                    f"unexpected {type(e).__name__}: {e}")[:MAX_ERROR_CHARS]
                log.warning("switch worker for %s crashed: %s", args[0], message)
                self._mark_failed(None, message)
        self._spawn(guarded, ())

    def request_switch(self, name, reason="api"):
        """Validate and enqueue a switch. Returns (http_status, payload)."""
        if name == "default":
            name = self.config.default_profile
        residents = self.config.resident_names
        if name == "pair" or (residents and name in residents):
            # The pair mode maps "pair" and each individual resident name to
            # the same target: asking for either member loads the whole pair.
            if not residents:
                return 400, {"error": {
                    "type": "unknown_profile",
                    "message": "unknown profile: pair"}}
            name = "pair"
        elif name not in self.profiles:
            return 400, {"error": {
                "type": "unknown_profile",
                "message": f"unknown profile: {name}"}}

        now = self.clock()
        with self._lock:
            if self._s.state == "switching":
                return 409, {
                    "error": {
                        "type": "already_switching",
                        "message": "a switch is already in progress"},
                    "target": self._s.target,
                }
            if name == self._s.current and self._s.state == "ready":
                return 200, {"state": "ready", "current": name, "changed": False}
            if (name != self.config.default_profile
                    and self._s.last_switch_done_at is not None):
                elapsed = now - self._s.last_switch_done_at
                if elapsed < self.config.cooldown_seconds:
                    retry_after = int(self.config.cooldown_seconds - elapsed)
                    retry_after = max(retry_after, 1)
                    return 429, {
                        "error": {
                            "type": "cooldown",
                            "message": "switch cooldown active"},
                        "retry_after": retry_after,
                    }
            self._s.state = "switching"
            self._s.target = name
            self._s.reason = reason
            self._s.started_at = now
            self._s.finished_at = None
            self._s.phase = ""
            self._s.last_error = None
            self._s.generation += 1

        self._spawn_guarded(self.run_switch, (name, reason))
        return 202, {"state": "switching", "target": name}

    # -- status ------------------------------------------------------------

    def status(self):
        cfg = self.config
        with self._lock:
            s = self._s
            idle_return_at = None
            if (cfg.idle_minutes > 0 and s.state == "ready" and s.current
                    and s.current != cfg.default_profile
                    and s.last_activity is not None):
                idle_return_at = s.last_activity + cfg.idle_minutes * 60
            cooldown_until = None
            if s.last_switch_done_at is not None:
                cooldown_until = s.last_switch_done_at + cfg.cooldown_seconds
            if s.current is None:
                mode = None
            elif s.current == "pair":
                mode = "pair"
            else:
                mode = "single"
            slots = [
                {"slot": i, "container": self._slot_container(i),
                 "port": cfg.vllm_host_port + i, "profile": served}
                for i, (_base, served)
                in enumerate(self._endpoints(s.current))
            ] if s.current is not None else []
            return {
                "state": s.state,
                "current": s.current,
                "target": s.target,
                "default": cfg.default_profile,
                "mode": mode,
                "residents": list(cfg.resident_names),
                "slots": slots,
                "phase": s.phase,
                "reason": s.reason,
                "started_at": s.started_at,
                "finished_at": s.finished_at,
                "last_error": s.last_error,
                "idle_minutes": cfg.idle_minutes,
                "idle_return_at": idle_return_at,
                "cooldown_until": cooldown_until,
                "profiles": [
                    {"name": p.name, "model": p.model, "kind": p.kind,
                     "verified": p.verified, "description": p.description,
                     "resident": p.name in cfg.resident_names}
                    for _, p in sorted(self.profiles.items())
                ],
            }

    # -- idle auto-return ----------------------------------------------------

    def _probe_idle(self, endpoints):
        """Sum the idle metrics over every endpoint (pair mode: both slots).
        Returns (running, success); (None, None) when any probe failed — a
        failed probe is NOT idleness. success is None when any endpoint does
        not report a success total (the change check then never fires)."""
        running = 0.0
        success = 0.0
        for base_url, _served in endpoints:
            status, data = self.http_get(
                base_url.rstrip("/") + "/metrics", self._auth_headers(),
                timeout=10)
            if status != 200:
                return None, None
            try:
                metrics = parse_metrics(data.decode("utf-8", "replace"))
            except Exception:
                return None, None
            running += (metrics.get("vllm:num_requests_running", 0.0)
                        + metrics.get("vllm:num_requests_waiting", 0.0))
            endpoint_success = metrics.get("vllm:request_success_total")
            if endpoint_success is None:
                success = None
            elif success is not None:
                success += endpoint_success
        return running, success

    def idle_tick(self):
        cfg = self.config
        if cfg.idle_minutes <= 0:
            return
        with self._lock:
            if (self._s.state != "ready" or not self._s.current
                    or self._s.current == cfg.default_profile):
                return
            # Remember what we are judging: the probe below runs unlocked for
            # up to 10 s, and a user switch may complete meanwhile.
            generation = self._s.generation
            previous = self._s.last_success_total
            endpoints = self._endpoints(self._s.current)

        running, success = self._probe_idle(endpoints)
        if running is None:
            return

        now = self.clock()
        with self._lock:
            # Re-check under the lock: if any switch happened while we probed
            # (generation moved), or the state/current changed, the idle
            # computation above is stale — do nothing, in particular do not
            # switch away from a model a user just loaded.
            if (self._s.generation != generation
                    or self._s.state != "ready" or not self._s.current
                    or self._s.current == cfg.default_profile):
                return
            if running > 0:
                self._s.last_activity = now
            elif (previous is not None and success is not None
                    and success != previous):
                self._s.last_activity = now
            self._s.last_success_total = success
            idle_expired = (
                self._s.last_activity is not None
                and now - self._s.last_activity >= cfg.idle_minutes * 60)

        if idle_expired:
            log.info("idle for %d minutes; returning to %s",
                     cfg.idle_minutes, cfg.default_profile)
            self.request_switch(cfg.default_profile, reason="idle")


# --------------------------------------------------------------------------
# HTTP server


def _error_payload(exc_type, message):
    return {"error": {"type": exc_type, "message": message}}


def make_server(controller, host, port):
    handler = _build_handler(controller)
    return http.server.ThreadingHTTPServer((host, port), handler)


def _build_handler(controller):
    token = controller.config.switch_token.encode("utf-8")

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        # Drop connections that stop sending mid-request (slow-loris): every
        # rfile read inherits this timeout via StreamRequestHandler.setup.
        timeout = 30

        # -- helpers ---------------------------------------------------

        def _send(self, status, payload, close=False):
            body = json.dumps(payload).encode("utf-8")
            if close:
                self.close_connection = True
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            log.info("%s %s %d %s",
                     self.command, self.path.split("?", 1)[0], status,
                     self.client_address[0])

        def _authorized(self):
            header = self.headers.get("Authorization", "")
            expected = b"Bearer " + token
            try:
                got = header.encode("utf-8")
            except UnicodeEncodeError:
                return False
            return hmac.compare_digest(got, expected)

        # -- methods ----------------------------------------------------

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/health":
                self._send(200, {"ok": True})
                return
            # Unauthenticated or unknown paths: answer and close without
            # reading (or trusting) any body the client may still send.
            if not self._authorized():
                self._send(401, _error_payload(
                    "unauthorized", "missing or invalid bearer token"),
                    close=True)
                return
            if path == "/status":
                self._send(200, controller.status())
                return
            self._send(404, _error_payload("not_found", f"no such path: {path}"),
                       close=True)

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            if path != "/switch":
                self._send(404, _error_payload("not_found", f"no such path: {path}"),
                           close=True)
                return
            # Auth BEFORE reading the body.
            if not self._authorized():
                self._send(401, _error_payload(
                    "unauthorized", "missing or invalid bearer token"),
                    close=True)
                return
            length = self.headers.get("Content-Length")
            if length is None:
                self._send(400, _error_payload(
                    "bad_request", "Content-Length required"), close=True)
                return
            try:
                n = int(length)
            except ValueError:
                self._send(400, _error_payload(
                    "bad_request", "invalid Content-Length"), close=True)
                return
            if n < 0:
                self._send(400, _error_payload(
                    "bad_request", "invalid Content-Length"), close=True)
                return
            if n > MAX_BODY_BYTES:
                self._send(413, _error_payload(
                    "payload_too_large", f"body must be <= {MAX_BODY_BYTES} bytes"),
                    close=True)
                return
            raw = self.rfile.read(n)
            try:
                obj = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                self._send(400, _error_payload("bad_request", "invalid JSON"))
                return
            profile = obj.get("profile") if isinstance(obj, dict) else None
            if not isinstance(profile, str) or not profile:
                self._send(400, _error_payload(
                    "bad_request", 'body must be {"profile": "<name>"}'))
                return
            status, payload = controller.request_switch(profile, reason="api")
            self._send(status, payload)

        # -- logging ------------------------------------------------------

        def log_message(self, fmt, *args):
            # Default BaseHTTPRequestHandler logging is silenced; one INFO
            # line per request is emitted in _send instead (method, path
            # without query string, status, client IP) — never headers or
            # bodies.
            return

    return Handler


# --------------------------------------------------------------------------
# main


def _idle_loop(controller):
    cfg = controller.config
    while True:
        time.sleep(max(cfg.idle_poll_seconds, 1))
        try:
            controller.drift_check()
        except Exception as e:  # never let the idle thread die
            log.warning("drift_check failed: %s", e)
        try:
            controller.idle_tick()
        except Exception as e:  # never let the idle thread die
            log.warning("idle_tick failed: %s", e)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="DGX Spark vLLM profile switch controller")
    parser.add_argument("--env-file", default="/app/env")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s")

    try:
        config = load_config(args.env_file, os.environ)
        profiles = load_profiles(config.profiles_file)
        if config.backend == "kubernetes":
            from spark_backend_kube import KubeAPI, KubeBackend
            api = KubeAPI.from_incluster(os.environ)
            backend = KubeBackend(config, profiles, api)
            controller = Controller(config, profiles, None, backend=backend)
        else:
            controller = Controller(
                config, profiles, DockerAPI(config.docker_sock))
    except (ConfigError, ProfileError) as e:
        print(f"config error: {e}", file=sys.stderr)
        return 2

    try:
        controller.adopt()
    except Exception as e:
        log.warning("adopt failed: %s", e)

    server = make_server(controller, config.switch_host, config.switch_port)
    threading.Thread(target=_idle_loop, args=(controller,), daemon=True).start()
    log.info("spark-switch listening on %s:%d (state=%s current=%s)",
             config.switch_host, config.switch_port,
             controller.status()["state"], controller.status()["current"])
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
