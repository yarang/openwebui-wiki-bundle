#!/usr/bin/env python3
"""Tests for the Kubernetes backend and the controller driving it
(stdlib unittest only; no cluster, no network — a FakeKubeAPI holds the
Deployment and Pod JSON in memory and applies the strategic-merge-patch
semantics we rely on)."""

import itertools
import json
import os
import re
import secrets
import shutil
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import spark_switch  # noqa: E402
import spark_backend_kube as kube  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PARENT = os.path.dirname(HERE)
PROFILES_PATH = os.path.join(PARENT, "profiles.json")

TOKEN = "t" * 40
VLLM_KEY = "sk-vllm-test-key-123"

DEPLOY_PATH = ("/apis/apps/v1/namespaces/spark-llm/"
               "deployments/vllm-coder")
PODS_PATH = ("/api/v1/namespaces/spark-llm/pods"
             "?labelSelector=app%3Dvllm-coder")
LOG_PATH_RE = re.compile(
    r"^/api/v1/namespaces/spark-llm/pods/[^/]+/log"
    r"\?container=vllm&tailLines=\d+(&previous=true)?$")

# Every request every FakeKubeAPI instance ever made, for the RBAC-scope
# test (the backend must never touch anything but the three allowed paths).
ALL_CALLS = []

METRICS_IDLE = (b"vllm:num_requests_running 0\n"
                b"vllm:request_success_total 0\n")


# ---------------------------------------------------------------- fakes


class FakeClock:
    def __init__(self, t=1763000000.0):
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


def thread_spawn(target, args=()):
    """Real background worker — for race tests that must interleave a
    switch with another thread's drift/inspect."""
    t = threading.Thread(target=target, args=args, daemon=True)
    t.start()
    return t


class FakeDocker:
    """Minimal Docker fake (for the Docker-backend drift no-op test)."""

    def __init__(self, routes=None):
        self.calls = []
        self.routes = routes or []

    def request(self, method, path, body=None, timeout=None):
        self.calls.append((method, path, body))
        for m, prefix, value in self.routes:
            if m == method and path.startswith(prefix):
                if callable(value):
                    return value(method, path, body)
                return value
        return 404, b"{}"


def pod_status(state):
    # `ready` on the running container: a vLLM container that has started
    # but not passed its readiness probe would have ready == false — the
    # kube backend's requested_serving() distinguishes the two.
    running = {"name": "vllm",
               "state": {"running": {"startedAt": "2026-11-12T00:00:00Z"}},
               "ready": True,
               "restartCount": 0}
    if state == "running":
        return {"phase": "Running", "containerStatuses": [running]}
    if state == "pending":
        return {"phase": "Pending"}
    if state == "unschedulable":
        return {"phase": "Pending",
                "conditions": [{
                    "type": "PodScheduled", "status": "False",
                    "reason": "Unschedulable",
                    "message": ("0/1 nodes are available: 1 Insufficient "
                                "nvidia.com/gpu.")}]}
    if state == "imagepull":
        return {"phase": "Pending",
                "containerStatuses": [{
                    "name": "vllm",
                    "state": {"waiting": {
                        "reason": "ImagePullBackOff",
                        "message": ("Back-off pulling image "
                                    "nvcr.io/nvidia/vllm:26.02-py3")}},
                    "restartCount": 0}]}
    if state == "neverpull":
        # ErrImageNeverPull: the offline install runs with imagePullPolicy
        # Never; the image is simply not in containerd and no registry
        # fallback exists — terminal, fail fast
        return {"phase": "Pending",
                "containerStatuses": [{
                    "name": "vllm",
                    "state": {"waiting": {
                        "reason": "ErrImageNeverPull",
                        "message": ("Failed to pull image "
                                    "nvcr.io/nvidia/vllm:26.02-py3: "
                                    "imagePullPolicy is Never")}},
                    "restartCount": 0}]}
    if state == "oom-restart":
        # realistic CrashLoopBackOff: kubelet already restarted the
        # container (restartCount > 0) and is now back-ing off (the old
        # ContainerCreating fixture hid the previous-log bug)
        return {"phase": "Running",
                "containerStatuses": [{
                    "name": "vllm",
                    "state": {"waiting": {
                        "reason": "CrashLoopBackOff",
                        "message": ("Back-off 5m0s restarting failed "
                                    "container=vllm")}},
                    "lastState": {"terminated": {
                        "reason": "OOMKilled", "exitCode": 137}},
                    "restartCount": 1}]}
    if state == "crashloop":
        return {"phase": "Running",
                "containerStatuses": [{
                    "name": "vllm",
                    "state": {"waiting": {
                        "reason": "CrashLoopBackOff",
                        "message": ("Back-off 5m0s restarting failed "
                                    "container=vllm")}},
                    "lastState": {"terminated": {
                        "reason": "Error", "exitCode": 1}},
                    "restartCount": 2}]}
    if state == "terminated":
        # the container died and kubelet has NOT restarted it yet
        return {"phase": "Running",
                "containerStatuses": [{
                    "name": "vllm",
                    "state": {"terminated": {
                        "reason": "OOMKilled", "exitCode": 137}},
                    "restartCount": 0}]}
    if state == "failed":
        return {"phase": "Failed", "reason": "Evicted"}
    raise ValueError(state)


def make_deployment(profile="qwen3-coder", replicas=1):
    profiles = spark_switch.load_profiles(PROFILES_PATH)
    args = kube.pod_args(profiles[profile])
    return {
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {"name": "vllm-coder", "namespace": "spark-llm",
                     "generation": 1, "labels": {"app": "vllm-coder"}},
        "spec": {
            "replicas": replicas,
            "template": {
                "metadata": {
                    "labels": {"app": "vllm-coder"},
                    "annotations": {kube.ANN_PROFILE: profile},
                },
                "spec": {"containers": [{"name": "vllm", "args": args}]},
            },
        },
        "status": {"observedGeneration": 1, "conditions": []},
    }


class FakeKubeAPI:
    """One Deployment dict + a list of Pod dicts in memory; records every
    call. PATCH applies the strategic-merge semantics the backend relies
    on: template annotations merge, containers merge by name, args replace.

    Deployment-controller emulation: when `roll_states` is non-empty, every
    pod-list GET creates the next pod (in the queued state) for the
    template's CURRENT requested-at annotation — with roll_once=True (the
    default) one pod per distinct requested-at, keeping its state across
    further polls. The controller's _wait_ready only probes /v1/models
    once the requested pod is serving, so rollouts can no longer be driven
    from the probe; the pod-list fetch is where the backend looks."""

    def __init__(self, deployment=None):
        self.deployment = (deployment if deployment is not None
                           else make_deployment())
        self.pods = []
        self.calls = []          # (method, path, content_type, body)
        self.fail_requests = False   # transport errors
        self.deploy_get_status = 200
        self.patch_status = 200
        self.log_text = ""
        self._pod_seq = 0
        self.roll_states = []        # queued pod states (see class docstring)
        self.roll_once = True
        self.roll_after_lists = 0    # skip the first N pod-list GETs
        self._rolled_for = None      # requested-at already rolled (once mode)
        self._lists_seen = 0

    def request(self, method, path, body=None,
                content_type="application/json"):
        self.calls.append((method, path, content_type, body))
        ALL_CALLS.append((method, path))
        if self.fail_requests:
            raise kube.SwitchFailure(f"{method} {path}: ConnectionResetError")
        if method == "GET" and path == DEPLOY_PATH:
            return self.deploy_get_status, json.dumps(
                self.deployment).encode()
        if method == "GET" and path == PODS_PATH:
            self._roll_from_queue()
            return 200, json.dumps({"items": self.pods}).encode()
        if method == "PATCH" and path == DEPLOY_PATH:
            if self.patch_status != 200:
                return self.patch_status, json.dumps({
                    "kind": "Status", "code": self.patch_status,
                    "message": "deployments.apps \"vllm-coder\" not found"
                }).encode()
            self._apply_patch(body)
            return 200, json.dumps(self.deployment).encode()
        if method == "GET" and LOG_PATH_RE.match(path):
            return 200, self.log_text.encode()
        return 404, json.dumps({
            "kind": "Status", "message": "the server could not find the "
            "requested resource"}).encode()

    # -- behaviour -----------------------------------------------------------

    def _roll_from_queue(self):
        self._lists_seen += 1
        if (not self.roll_states
                or self._lists_seen <= self.roll_after_lists):
            return
        requested = self.template_requested()
        if self.roll_once and requested == self._rolled_for:
            return
        self._rolled_for = requested
        self.roll_out(self.roll_states.pop(0))

    def _apply_patch(self, body):
        spec = self.deployment.setdefault("spec", {})
        template = spec.setdefault("template", {})
        tmeta = template.setdefault("metadata", {})
        (tmeta.setdefault("annotations", {})
         .update(body["spec"]["template"]["metadata"]["annotations"]))
        containers = template.setdefault("spec", {}).setdefault(
            "containers", [])
        for patch in body["spec"]["template"]["spec"]["containers"]:
            for container in containers:
                if container["name"] == patch["name"]:
                    container["args"] = patch["args"]
                    break
            else:
                containers.append(dict(patch))
        meta = self.deployment.setdefault("metadata", {})
        meta["generation"] = meta.get("generation", 0) + 1
        status = self.deployment.setdefault("status", {})
        status["observedGeneration"] = meta["generation"]

    def roll_out(self, state="running", terminate_old=True):
        """Create a pod carrying the template's annotations in `state`;
        by default the previous pods get a deletionTimestamp (Recreate)."""
        template = self.deployment["spec"]["template"]
        annotations = dict((template.get("metadata") or {})
                           .get("annotations") or {})
        self._pod_seq += 1
        if terminate_old:
            for pod in self.pods:
                (pod.setdefault("metadata", {})
                 .setdefault("deletionTimestamp", "2026-11-12T00:00:00Z"))
        pod = {
            "metadata": {
                "name": (f"vllm-coder-{self._pod_seq:04d}-"
                         f"{secrets.token_hex(3)}"),
                "creationTimestamp": (f"2026-11-12T00:{self._pod_seq // 60:02d}"
                                      f":{self._pod_seq % 60:02d}Z"),
                "labels": {"app": "vllm-coder"},
                "annotations": annotations,
            },
            "spec": {"containers": [{"name": "vllm", "args": []}]},
            "status": pod_status(state),
        }
        self.pods.append(pod)
        return pod

    def live_pod(self):
        live = [p for p in self.pods
                if not (p.get("metadata") or {}).get("deletionTimestamp")]
        if not live:
            return None
        return max(live, key=lambda p: (p.get("metadata") or {})
                   .get("creationTimestamp") or "")

    def served_now(self):
        """What /v1/models would answer: the profile of the newest live pod,
        but only once its container is actually running."""
        pod = self.live_pod()
        if pod is None:
            return "still-loading"
        cs = [c for c in (pod.get("status") or {}).get("containerStatuses")
              or [] if c.get("name") == "vllm"]
        if cs and (cs[0].get("state") or {}).get("running"):
            ann = (pod.get("metadata") or {}).get("annotations") or {}
            return ann.get(kube.ANN_PROFILE, "unknown")
        return "still-loading"

    def template_requested(self):
        template = self.deployment.get("spec", {}).get("template", {})
        return ((template.get("metadata") or {}).get("annotations")
                or {}).get(kube.ANN_REQUESTED)


def kube_models_http(api, served=None):
    """http_get: /v1/models lists `served` (a fixed profile), or by default
    whatever the deployment template annotation says (adopt probes)."""
    if served is None:
        def served_fn():
            return api.deployment["spec"]["template"]["metadata"][
                "annotations"].get(kube.ANN_PROFILE, "unknown")
    else:
        value = served

        def served_fn():
            return value

    def get(url, headers, timeout):
        if url.endswith("/v1/models"):
            return 200, json.dumps({"data": [{"id": served_fn()}]}).encode()
        return 200, METRICS_IDLE

    return get


def served_now_http(api):
    """/v1/models answers what the newest live pod actually serves once its
    container is running ("still-loading" before that) — i.e. the Service's
    view, which keeps routing to the old pod until the new one is ready."""
    def get(url, headers, timeout):
        if url.endswith("/v1/models"):
            return 200, json.dumps(
                {"data": [{"id": api.served_now()}]}).encode()
        return 200, METRICS_IDLE

    return get


def rolling_api(deployment=None, states=None, once=True):
    """FakeKubeAPI whose Deployment controller creates pods as the backend
    looks for them: one pod per pods-list GET while states remain. once=True
    rolls ONE pod per distinct requested-at (failure scenarios where a bad
    pod state must persist); once=False rolls on every list (a pending ->
    running progression within one attempt)."""
    api = FakeKubeAPI(deployment)
    api.roll_states = list(states or [])
    api.roll_once = once
    return api


def make_kube_controller(api, http_get=None, spawn=sync_spawn, nonce="abc123",
                         **cfg_over):
    cfg = spark_switch.Config()
    cfg.switch_token = TOKEN
    cfg.vllm_api_key = VLLM_KEY
    cfg.backend = "kubernetes"
    for k, v in cfg_over.items():
        setattr(cfg, k, v)
    profiles = spark_switch.load_profiles(PROFILES_PATH)
    clock = FakeClock()
    if isinstance(nonce, str):
        # distinct nonces per call: a frozen test clock must not make two
        # replaces (attempt + recovery) mint the SAME requested-at
        base, counter = nonce[:3], itertools.count()
        nonce = (lambda: f"{base}{next(counter):03d}")
    backend = kube.KubeBackend(cfg, profiles, api, clock=clock, nonce=nonce)
    ctrl = spark_switch.Controller(
        cfg, profiles, None,           # docker=None: kube mode
        http_get=http_get or kube_models_http(api),
        clock=clock, sleep=AdvancingSleep(clock), spawn=spawn,
        backend=backend)
    return ctrl, clock, backend


# ---------------------------------------------------------------- 1-3. replace


class ReplaceTests(unittest.TestCase):
    def test_happy_path_patches_deployment_and_waits_for_pod(self):
        api = rolling_api(make_deployment(profile="qwen3-coder"),
                          ["pending", "running"], once=False)
        ctrl, _, _ = make_kube_controller(
            api, http_get=served_now_http(api))

        status, payload = ctrl.request_switch("gpt-oss-120b")
        self.assertEqual(status, 202)

        patches = [c for c in api.calls if c[0] == "PATCH"]
        self.assertEqual(len(patches), 1)
        method, path, ctype, body = patches[0]
        self.assertEqual(path, DEPLOY_PATH)
        self.assertEqual(ctype, "application/strategic-merge-patch+json")
        annotations = body["spec"]["template"]["metadata"]["annotations"]
        self.assertEqual(annotations[kube.ANN_PROFILE], "gpt-oss-120b")
        requested = annotations[kube.ANN_REQUESTED]
        self.assertRegex(requested, r"^\d{13}-[a-z0-9]{6}$")
        prof = spark_switch.load_profiles(PROFILES_PATH)["gpt-oss-120b"]
        self.assertEqual(body["spec"]["template"]["spec"]["containers"],
                         [{"name": "vllm", "args": kube.pod_args(prof)}])

        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "gpt-oss-120b")
        self.assertIsNone(st["target"])
        self.assertIsNone(st["last_error"])

    def test_same_profile_reswitch_waits_for_the_new_pod(self):
        # one "running" per replace(): the second, same-profile switch must
        # wait for ITS pod — the old pod (same profile, old requested-at)
        # answering /v1/models with the expected id is not enough
        api = rolling_api(make_deployment(profile="qwen3-coder"),
                          ["running", "running"])
        ctrl, clock, backend = make_kube_controller(
            api, http_get=served_now_http(api))
        ctrl.request_switch("gpt-oss-120b")
        self.assertEqual(ctrl.status()["current"], "gpt-oss-120b")
        first_requested = backend._requested
        clock.t += 1.0   # a later re-switch is a different millisecond

        # Same profile again (run_switch bypasses the "already current" 200):
        # a new requested-at must force a new pod even though nothing else in
        # the template changed.
        ctrl.run_switch("gpt-oss-120b", "api")
        patches = [c for c in api.calls if c[0] == "PATCH"]
        self.assertEqual(len(patches), 2)
        second_requested = backend._requested
        self.assertNotEqual(first_requested, second_requested)

        # The OLD-annotated pod is ignored for liveness/log selection.
        old_pod = api.live_pod()
        old_pod["metadata"]["annotations"][kube.ANN_REQUESTED] = \
            first_requested
        pod, list_failed = backend._select_pod(backend._requested)
        self.assertFalse(list_failed)
        self.assertIsNone(pod)  # old-annotated pod does not match

        self.assertEqual(ctrl.status()["state"], "ready")
        self.assertEqual(ctrl.status()["current"], "gpt-oss-120b")

    def test_requested_at_format_and_uniqueness(self):
        api = FakeKubeAPI(make_deployment())
        cfg = spark_switch.Config()
        cfg.switch_token = TOKEN
        cfg.backend = "kubernetes"
        profiles = spark_switch.load_profiles(PROFILES_PATH)
        clock = FakeClock()
        backend = kube.KubeBackend(cfg, profiles, api, clock=clock)
        seen = set()
        for _ in range(25):          # distinct milliseconds
            clock.t += 1.0
            backend.replace(profiles["qwen3-coder"], lambda phase: None)
            self.assertRegex(backend._requested, r"^\d{13}-[a-z0-9]{6}$")
            seen.add(backend._requested)
        for _ in range(10):          # same millisecond: the nonce differs
            backend.replace(profiles["qwen3-coder"], lambda phase: None)
            seen.add(backend._requested)
        self.assertEqual(len(seen), 35)

    def test_patch_404_reports_missing_manifests(self):
        api = rolling_api(make_deployment(), ["running"])
        api.patch_status = 404
        ctrl, _, _ = make_kube_controller(
            api, http_get=served_now_http(api))
        ctrl.run_switch("gpt-oss-120b", "api")
        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIn("not found in spark-llm", st["last_error"])


# ------------------------------------------------------- 4-8. failure paths


class FailurePathTests(unittest.TestCase):
    def test_unschedulable_below_threshold_waits_then_fails_and_recovers(self):
        # --- controller level: fails after the threshold, recovery runs once
        api = rolling_api(make_deployment(),
                          ["unschedulable", "running"])
        ctrl, clock, _ = make_kube_controller(
            api, http_get=served_now_http(api),
            unschedulable_seconds=120, ready_poll_seconds=5)
        status, _ = ctrl.request_switch("gpt-oss-120b")
        self.assertEqual(status, 202)

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertEqual(st["current"], "qwen3-coder")
        self.assertIn("pod unschedulable for 120 s", st["last_error"])
        self.assertIn("nvidia.com/gpu", st["last_error"])
        self.assertIn("recovery to qwen3-coder succeeded", st["last_error"])
        patches = [c for c in api.calls if c[0] == "PATCH"]
        self.assertEqual(len(patches), 2)  # attempt + recovery

        # --- backend level: below the threshold check_alive keeps waiting
        api2 = FakeKubeAPI(make_deployment())
        ctrl2, clock2, backend2 = make_kube_controller(
            api2, http_get=kube_models_http(api2),
            unschedulable_seconds=120, ready_poll_seconds=5)
        backend2._requested = "1699999999999-aaaaaa"
        pod = api2.roll_out("unschedulable", terminate_old=False)
        pod["metadata"]["annotations"][kube.ANN_REQUESTED] = \
            backend2._requested
        self.assertIsNone(backend2.check_alive())          # first sighting
        clock2.t += 5
        self.assertIsNone(backend2.check_alive())          # 5 s
        clock2.t += 110
        self.assertIsNone(backend2.check_alive())          # 115 s < 120 s
        clock2.t += 5
        why = backend2.check_alive()                       # 120 s >= 120 s
        self.assertIn("pod unschedulable for 120 s", why)
        self.assertIn("nvidia.com/gpu", why)

    def test_image_pull_backoff_fails_then_recovers_to_default(self):
        api = rolling_api(make_deployment(), ["imagepull", "running"])
        ctrl, _, _ = make_kube_controller(
            api, http_get=served_now_http(api))
        ctrl.request_switch("gpt-oss-120b")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertEqual(st["current"], "qwen3-coder")
        self.assertIn("ImagePullBackOff", st["last_error"])
        self.assertIn("recovery to qwen3-coder succeeded", st["last_error"])

    def test_err_image_neverpull_is_fatal_and_recovers_to_default(self):
        # the offline install's images live only in containerd; when one is
        # missing the kubelet reports ErrImageNeverPull — no retry, no
        # registry fallback — and the switch must fail fast and recover
        self.assertIn("ErrImageNeverPull", kube.FATAL_WAITING_REASONS)

        api = rolling_api(make_deployment(), ["neverpull", "running"])
        ctrl, _, _ = make_kube_controller(
            api, http_get=served_now_http(api))
        ctrl.request_switch("gpt-oss-120b")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertEqual(st["current"], "qwen3-coder")
        self.assertIn("ErrImageNeverPull", st["last_error"])
        self.assertIn("recovery to qwen3-coder succeeded", st["last_error"])

    def test_oom_restart_failure_uses_previous_logs(self):
        api = rolling_api(make_deployment(), ["oom-restart", "running"])
        api.log_text = ("ERROR: allocator oom; key=" + VLLM_KEY +
                        " token=" + TOKEN + "\n")
        ctrl, _, _ = make_kube_controller(
            api, http_get=served_now_http(api))
        ctrl.request_switch("gpt-oss-120b")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        # CrashLoopBackOff with restartCount > 0: the fatal waiting reason
        # wins the message, but the PREVIOUS container's logs are fetched
        self.assertIn("container waiting: CrashLoopBackOff",
                      st["last_error"])
        log_calls = [c for c in api.calls
                     if c[0] == "GET" and LOG_PATH_RE.match(c[1])]
        self.assertGreaterEqual(len(log_calls), 1)
        self.assertTrue(any("previous=true" in c[1] for c in log_calls),
                        log_calls)
        # redaction: neither secret survives into last_error
        self.assertNotIn(VLLM_KEY, st["last_error"])
        self.assertNotIn(TOKEN, st["last_error"])
        self.assertIn("***", st["last_error"])

    def test_crashloop_with_restarts_reads_previous_container_logs(self):
        # CrashLoopBackOff + restartCount 2: the fatal waiting reason must
        # not lose the PREVIOUS container's logs (restart_seen is set before
        # the waiting-reason evaluation).
        api = rolling_api(make_deployment(), ["crashloop", "running"])
        ctrl, _, backend = make_kube_controller(
            api, http_get=served_now_http(api))
        ctrl.request_switch("gpt-oss-120b")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIn("container waiting: CrashLoopBackOff", st["last_error"])
        log_calls = [c for c in api.calls
                     if c[0] == "GET" and LOG_PATH_RE.match(c[1])]
        # _restart_seen is per-attempt bookkeeping that the recovery's
        # replace() legitimately resets — so the assertion must target the
        # MOMENT the failing attempt fetched its logs: check_alive had
        # already set the flag before it returned CrashLoopBackOff, hence
        # the very first log GET carries previous=true.
        self.assertTrue(log_calls)
        self.assertIn("previous=true", log_calls[0][1], log_calls)
        self.assertFalse(backend._restart_seen)   # reset by the recovery

    def test_terminated_container_before_any_restart_fails_fast(self):
        # current state terminated, restartCount still 0 (kubelet has not
        # restarted it yet): fail fast; the logs read the CURRENT (dead)
        # container, so previous stays false.
        api = rolling_api(make_deployment(), ["terminated", "running"])
        ctrl, _, _ = make_kube_controller(
            api, http_get=served_now_http(api))
        ctrl.request_switch("gpt-oss-120b")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIn("container terminated: OOMKilled (exit 137)",
                      st["last_error"])
        log_calls = [c for c in api.calls
                     if c[0] == "GET" and LOG_PATH_RE.match(c[1])]
        self.assertTrue(log_calls)
        self.assertFalse(any("previous=true" in c[1] for c in log_calls),
                         log_calls)

    def test_replica_failure_condition_means_psa_rejection(self):
        # pod creation is refused, so no pod ever appears (no rolling fake)
        api = FakeKubeAPI(make_deployment())
        api.deployment["status"]["conditions"] = [{
            "type": "ReplicaFailure", "status": "True",
            "reason": "FailedCreate",
            "message": ('pods "vllm-coder-1" is forbidden: violates '
                        'PodSecurity "baseline:latest": hostPath volumes'),
        }]
        ctrl, _, _ = make_kube_controller(api)
        ctrl.request_switch("gpt-oss-120b")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIsNone(st["current"])   # the recovery hits the same wall
        self.assertIn("pod creation refused", st["last_error"])
        self.assertIn("PodSecurity", st["last_error"])
        self.assertIn("recovery to qwen3-coder failed", st["last_error"])

    def test_stale_replica_failure_ignored_current_one_fails(self):
        api = FakeKubeAPI(make_deployment())
        api.deployment["status"]["conditions"] = [{
            "type": "ReplicaFailure", "status": "True",
            "reason": "FailedCreate", "message": "violates PodSecurity",
        }]
        ctrl, _, backend = make_kube_controller(api)
        backend._requested = "1699999999999-aaaaaa"
        backend._patched_generation = 2            # this attempt's patch
        api.deployment["metadata"]["generation"] = 2
        api.deployment["status"]["observedGeneration"] = 1  # stale
        self.assertIsNone(backend.check_alive())   # stale -> keep waiting

        api.deployment["status"]["observedGeneration"] = 2  # caught up
        why = backend.check_alive()
        self.assertIsNotNone(why)
        self.assertIn("pod creation refused", why)

    def test_recovery_also_failing_ends_failed_with_no_current(self):
        api = rolling_api(make_deployment(), ["imagepull", "imagepull"])
        ctrl, _, _ = make_kube_controller(
            api, http_get=served_now_http(api), ready_timeout=60)
        ctrl.request_switch("gpt-oss-120b")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIsNone(st["current"])
        self.assertIn("ImagePullBackOff", st["last_error"])
        self.assertIn("recovery to qwen3-coder failed", st["last_error"])


# ---------------------------------------------------------------- 9. adopt


class AdoptTests(unittest.TestCase):
    def _adopted(self, api, served):
        ctrl, _, _ = make_kube_controller(
            api, http_get=kube_models_http(api, served=served))
        ctrl.adopt()
        return ctrl

    def test_annotation_wins_over_args(self):
        deployment = make_deployment(profile="qwen3-coder")
        # args claim a different profile; the annotation must win
        prof = spark_switch.load_profiles(PROFILES_PATH)["gpt-oss-120b"]
        deployment["spec"]["template"]["spec"]["containers"][0]["args"] = \
            kube.pod_args(prof)
        api = FakeKubeAPI(deployment)
        api.roll_out("running", terminate_old=False)
        ctrl = self._adopted(api, served="qwen3-coder")
        self.assertEqual(ctrl.status()["state"], "ready")
        self.assertEqual(ctrl.status()["current"], "qwen3-coder")

    def test_falls_back_to_served_model_name_in_args(self):
        deployment = make_deployment(profile="qwen3-coder")
        (deployment["spec"]["template"]["metadata"]["annotations"].pop(
            kube.ANN_PROFILE))
        api = FakeKubeAPI(deployment)
        api.roll_out("running", terminate_old=False)
        ctrl = self._adopted(api, served="qwen3-coder")
        self.assertEqual(ctrl.status()["state"], "ready")
        self.assertEqual(ctrl.status()["current"], "qwen3-coder")

    def test_404_is_unknown_with_no_current(self):
        api = FakeKubeAPI(make_deployment())
        api.deploy_get_status = 404
        ctrl = self._adopted(api, served="qwen3-coder")
        st = ctrl.status()
        self.assertEqual(st["state"], "unknown")
        self.assertIsNone(st["current"])

    def test_scaled_to_zero_is_unknown(self):
        api = FakeKubeAPI(make_deployment(profile="gpt-oss-120b",
                                          replicas=0))
        ctrl = self._adopted(api, served="gpt-oss-120b")
        st = ctrl.status()
        self.assertEqual(st["state"], "unknown")
        self.assertIsNone(st["current"])

    def test_transport_error_is_unknown(self):
        api = FakeKubeAPI(make_deployment())
        api.fail_requests = True
        ctrl = self._adopted(api, served="qwen3-coder")
        st = ctrl.status()
        self.assertEqual(st["state"], "unknown")
        self.assertIsNone(st["current"])

    def test_running_but_not_listed_is_adopted_as_loading(self):
        api = FakeKubeAPI(make_deployment(profile="gpt-oss-120b"))
        api.roll_out("running", terminate_old=False)
        ctrl, _, _ = make_kube_controller(
            api, http_get=kube_models_http(api, served="still-loading"),
            spawn=noop_spawn)
        ctrl.adopt()
        st = ctrl.status()
        self.assertEqual(st["state"], "switching")
        self.assertEqual(st["target"], "gpt-oss-120b")
        self.assertEqual(st["phase"], "loading")

        # and with a worker that runs: it only waits (no PATCH) and finishes
        api2 = FakeKubeAPI(make_deployment(profile="gpt-oss-120b"))
        api2.roll_out("running", terminate_old=False)
        ctrl2, _, _ = make_kube_controller(
            api2, http_get=kube_models_http(api2, served="gpt-oss-120b"))
        ctrl2.adopt()
        st = ctrl2.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "gpt-oss-120b")
        self.assertEqual(
            [c for c in api2.calls if c[0] == "PATCH"], [])

    def test_adopt_waits_for_the_adopted_rollout_pod_not_the_old_answer(self):
        # G4: controller restart during a same-profile rollout. The template
        # already carries the NEW requested-at, its pod does not exist yet,
        # and the OLD pod (different requested-at) is Running+Ready — the
        # Service routes /v1/models to it, so it lists the same profile. The
        # adoption must take the loading path (switching/phase=loading), not
        # "ready" — and must not even consult /v1/models.
        api = FakeKubeAPI(make_deployment(profile="qwen3-coder"))
        old = api.roll_out("running", terminate_old=False)
        old["metadata"]["annotations"][kube.ANN_REQUESTED] = \
            "1762999999999-oldold"
        api.deployment["spec"]["template"]["metadata"]["annotations"][
            kube.ANN_REQUESTED] = "1763000000000-newnew"
        probes = []

        def counting_http(url, headers, timeout):
            probes.append(url)
            return 200, json.dumps(
                {"data": [{"id": "qwen3-coder"}]}).encode()

        ctrl, _, backend = make_kube_controller(api, http_get=counting_http,
                                                spawn=noop_spawn)
        ctrl.adopt()
        st = ctrl.status()
        self.assertEqual(st["state"], "switching")   # NOT "ready"
        self.assertEqual(st["target"], "qwen3-coder")
        self.assertEqual(st["phase"], "loading")
        self.assertEqual(probes, [])  # the old pod's answer was never asked
        # the adopted rollout became this controller's own attempt
        self.assertEqual(backend._requested, "1763000000000-newnew")


# ---------------------------------------------------------------- 10. drift


class DriftTests(unittest.TestCase):
    def _ready_on(self, profile):
        api = FakeKubeAPI(make_deployment(profile=profile))
        api.roll_out("running", terminate_old=False)
        ctrl, _, _ = make_kube_controller(api)  # template-driven probe
        ctrl.adopt()
        return ctrl, api

    def test_deployment_changed_behind_our_back_is_re_adopted(self):
        ctrl, api = self._ready_on("qwen3-coder")
        # operator ran `kubectl apply` / `rollout undo`: annotation changed
        api.deployment["spec"]["template"]["metadata"]["annotations"][
            kube.ANN_PROFILE] = "gpt-oss-120b"
        ctrl.drift_check()
        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "gpt-oss-120b")

    def test_no_drift_when_annotation_matches(self):
        ctrl, api = self._ready_on("qwen3-coder")
        before = len(api.calls)
        ctrl.drift_check()
        self.assertEqual(ctrl.status()["current"], "qwen3-coder")
        self.assertEqual(ctrl.status()["state"], "ready")
        # one deploy GET + one pod list, no PATCH
        self.assertEqual([c for c in api.calls[before:]
                          if c[0] == "PATCH"], [])

    def test_inspect_error_is_not_drift(self):
        ctrl, api = self._ready_on("qwen3-coder")
        api.fail_requests = True
        ctrl.drift_check()
        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "qwen3-coder")

    def test_docker_backend_drift_check_is_a_noop(self):
        docker = FakeDocker([(
            "GET", "/containers/vllm-coder/json",
            (200, json.dumps({
                "Config": {"Labels": {
                    spark_switch.LABEL_PROFILE: "qwen3-coder"}, "Cmd": []},
                "State": {"Running": True, "ExitCode": 0},
            }).encode()))])

        def http_get(url, headers, timeout):
            if url.endswith("/v1/models"):
                return 200, json.dumps(
                    {"data": [{"id": "qwen3-coder"}]}).encode()
            return 200, METRICS_IDLE

        cfg = spark_switch.Config()
        cfg.switch_token = TOKEN
        cfg.hf_cache_host = "/home/tester/.cache/huggingface"
        cfg.vllm_api_key = VLLM_KEY
        ctrl = spark_switch.Controller(
            cfg, spark_switch.load_profiles(PROFILES_PATH), docker,
            http_get=http_get, clock=FakeClock(),
            sleep=AdvancingSleep(FakeClock()), spawn=sync_spawn)
        ctrl.adopt()
        self.assertEqual(ctrl.status()["state"], "ready")
        calls_before = len(docker.calls)
        ctrl.drift_check()
        self.assertEqual(len(docker.calls), calls_before)  # no extra calls

    def test_switch_landing_during_drift_inspect_survives(self):
        api = FakeKubeAPI(make_deployment(profile="qwen3-coder"))
        api.roll_out("running", terminate_old=False)
        wrapper = RacingInspectBackend(None)
        ctrl, clock, backend = make_kube_controller(
            api, http_get=kube_models_http(api, served="qwen3-coder"),
            spawn=noop_spawn)
        wrapper.inner = backend
        wrapper.ctrl = ctrl
        ctrl._backend = wrapper
        ctrl.adopt()
        self.assertEqual(ctrl.status()["state"], "ready")

        # while drift_check inspects, a user switch lands (worker parked)
        api.deployment["spec"]["template"]["metadata"]["annotations"][
            kube.ANN_PROFILE] = "gpt-oss-120b"
        ctrl.drift_check()
        st = ctrl.status()
        self.assertEqual(st["state"], "switching")   # the switch wins
        self.assertEqual(st["target"], "gpt-oss-120b")
        self.assertEqual(st["current"], "qwen3-coder")

    def test_drift_readopt_of_a_loading_rollout_commits_the_observation(self):
        # drift re-adopts an in-progress rollout (operator applied a new
        # profile whose pod is still loading): the adopted requested-at and
        # generation become the backend's own rollout bookkeeping.
        api = FakeKubeAPI(make_deployment(profile="qwen3-coder"))
        api.roll_out("running", terminate_old=False)
        ctrl, _, backend = make_kube_controller(
            api, http_get=served_now_http(api), spawn=noop_spawn)
        ctrl.adopt()
        self.assertEqual(ctrl.status()["state"], "ready")

        api.deployment["spec"]["template"]["metadata"]["annotations"] = {
            kube.ANN_PROFILE: "gpt-oss-120b",
            kube.ANN_REQUESTED: "1763000000000-operat",
        }
        api.deployment["metadata"]["generation"] = 7
        api.deployment["status"]["observedGeneration"] = 7
        api.roll_out("pending", terminate_old=True)

        ctrl.drift_check()
        st = ctrl.status()
        self.assertEqual(st["state"], "switching")
        self.assertEqual(st["target"], "gpt-oss-120b")
        self.assertEqual(st["phase"], "loading")
        self.assertEqual(backend._requested, "1763000000000-operat")
        self.assertEqual(backend._patched_generation, 7)

    def test_drift_race_replace_wins_over_stale_inspection(self):
        """The real race (F1): drift's inspect() has the OLD template in
        hand; a user switch runs its replace() for a NEW profile between
        that GET and _apply_observation. The stale inspection must not
        clobber the new attempt's bookkeeping: the switch must keep waiting
        on (and fail on) ITS pod instead of timing out on a mismatch."""
        api = FakeKubeAPI(make_deployment(profile="qwen3-coder"))
        api.roll_out("running", terminate_old=False)          # P0 old pod
        ctrl, clock, backend = make_kube_controller(
            api, http_get=served_now_http(api), spawn=thread_spawn,
            nonce="newnew", ready_timeout=120, ready_poll_seconds=5)
        ctrl.adopt()
        self.assertEqual(ctrl.status()["state"], "ready")

        # the operator applies a different profile behind our back (drift
        # trigger); the old template carries an old requested-at
        api.deployment["spec"]["template"]["metadata"]["annotations"] = {
            kube.ANN_PROFILE: "gpt-oss-120b",
            kube.ANN_REQUESTED: "1762999999999-oldold",
        }

        # park the switch worker inside _wait_ready, right after replace()
        worker_parked = threading.Event()
        release_worker = threading.Event()
        real_sleep = ctrl.sleep

        def parking_sleep(seconds):
            if not worker_parked.is_set():
                worker_parked.set()
                self.assertTrue(release_worker.wait(timeout=10))
            real_sleep(seconds)

        ctrl.sleep = parking_sleep
        # the switch (running on a real worker thread) must roll its own
        # pod: arm the Deployment-controller emulation
        api.roll_states = ["imagepull", "running"]
        api.roll_once = True

        armed = [True]
        real_request = api.request

        def racing_request(method, path, body=None,
                           content_type="application/json"):
            if armed[0] and method == "GET" and path == DEPLOY_PATH:
                armed[0] = False
                # snapshot BEFORE the switch lands: this is the stale JSON
                # drift's inspect() is about to parse
                snapshot = json.dumps(api.deployment).encode()
                status, _ = ctrl.request_switch("qwen3-vl-30b")
                self.assertEqual(status, 202)
                self.assertTrue(worker_parked.wait(timeout=10),
                                "worker never reached _wait_ready")
                return 200, snapshot
            return real_request(method, path, body=body,
                                content_type=content_type)

        api.request = racing_request

        # drift thread: GET (old snapshot) -> replace() for the new profile
        # lands mid-inspect -> inspect returns the stale observation
        ctrl.drift_check()

        # the switch's requested-at survived the stale inspection
        self.assertEqual(backend._requested, api.template_requested())
        self.assertNotEqual(backend._requested, "1762999999999-oldold")

        # let the replacement proceed: its pod goes ImagePullBackOff, the
        # switch must fail FAST on that (check_alive selects the new pod)
        release_worker.set()
        deadline = time.time() + 10
        while ctrl.status()["state"] == "switching" and time.time() < deadline:
            time.sleep(0.01)
        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertIn("ImagePullBackOff", st["last_error"])
        self.assertIn("recovery to qwen3-coder succeeded", st["last_error"])
        # and the backend selection matches the recovery's own pod
        pod, list_failed = backend._select_pod(backend._requested)
        self.assertFalse(list_failed)
        self.assertIsNotNone(pod)

    def test_drift_observation_after_a_completed_switch_is_dropped(self):
        # G5: a switch that starts AND FINISHES while drift's inspect runs
        # unlocked (state leaves "switching", the generation moves). The
        # stale drift observation must be dropped: the controller keeps the
        # switch's result and never commits the stale adoption.
        api = FakeKubeAPI(make_deployment(profile="qwen3-coder"))
        api.roll_out("running", terminate_old=False)
        wrapper = CompletedSwitchInspectBackend(None)
        ctrl, _, backend = make_kube_controller(
            api, http_get=served_now_http(api), spawn=noop_spawn)
        wrapper.inner = backend
        ctrl._backend = wrapper
        ctrl.adopt()
        self.assertEqual(ctrl.status()["state"], "ready")
        wrapper.ctrl = ctrl            # arm: the next inspect runs a switch

        # the operator's change the stale inspect will report (pre-switch)
        api.deployment["spec"]["template"]["metadata"]["annotations"][
            kube.ANN_PROFILE] = "qwen3-vl-30b"
        api.roll_states = ["running"]  # the switch's own pod
        commits_before_drift = len(wrapper.commits)

        ctrl.drift_check()
        st = ctrl.status()
        self.assertEqual(st["state"], "ready")      # the switch's result
        self.assertEqual(st["current"], "gpt-oss-120b")
        self.assertEqual(st["reason"], "api")
        self.assertIsNone(st["target"])             # not re-adopted
        self.assertEqual(len(wrapper.commits), commits_before_drift)

    def test_drift_probe_race_is_dropped_by_the_generation_check(self):
        # G5, write-point half: the switch completes DURING the drift
        # observation's unlocked requested_serving()/probe — after the
        # commit point, before the state write. Only the generation clause
        # of blocked() can catch that (the state is no longer "switching").
        api = FakeKubeAPI(make_deployment(profile="qwen3-coder"))
        api.roll_out("running", terminate_old=False)
        wrapper = RacingProbeBackend(None)
        ctrl, _, backend = make_kube_controller(
            api, http_get=served_now_http(api), spawn=noop_spawn)
        wrapper.inner = backend
        ctrl._backend = wrapper
        ctrl.adopt()
        self.assertEqual(ctrl.status()["state"], "ready")
        wrapper.ctrl = ctrl            # arm: the next probe runs a switch

        api.deployment["spec"]["template"]["metadata"]["annotations"][
            kube.ANN_PROFILE] = "qwen3-vl-30b"
        api.roll_states = ["running"]

        ctrl.drift_check()
        st = ctrl.status()
        # the completed switch's result survived the stale observation
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "gpt-oss-120b")
        self.assertIsNone(st["target"])
        # and the backend still waits on the switch's rollout, not the
        # stale one the drift observation had committed before it
        self.assertEqual(backend._requested, api.template_requested())


class RacingInspectBackend:
    """Drift-race fake: inspect() lets a user request_switch land first."""

    supports_drift_check = True

    def __init__(self, inner):
        self.inner = inner
        self.ctrl = None

    def inspect(self):
        if self.ctrl is not None:
            status, _ = self.ctrl.request_switch("gpt-oss-120b")
            assert status == 202, status
        return self.inner.inspect()

    def replace(self, *args, **kwargs):
        return self.inner.replace(*args, **kwargs)

    def check_alive(self):
        return self.inner.check_alive()

    def requested_serving(self):
        return self.inner.requested_serving()

    def commit_adoption(self, obs):
        return self.inner.commit_adoption(obs)

    def logs_tail(self, n=40):
        return self.inner.logs_tail(n)


class CompletedSwitchInspectBackend:
    """G5 drift-race fake: inspect() first captures the (pre-switch) stale
    observation, then lets a switch run to COMPLETION (state leaves
    "switching", the generation moves) before returning it."""

    supports_drift_check = True

    def __init__(self, inner):
        self.inner = inner
        self.ctrl = None
        self.commits = []

    def inspect(self):
        stale = self.inner.inspect()
        if self.ctrl is not None:
            self.ctrl.run_switch("gpt-oss-120b", "api")
        return stale

    def replace(self, *args, **kwargs):
        return self.inner.replace(*args, **kwargs)

    def check_alive(self):
        return self.inner.check_alive()

    def requested_serving(self):
        return self.inner.requested_serving()

    def commit_adoption(self, obs):
        self.commits.append(obs)
        return self.inner.commit_adoption(obs)

    def logs_tail(self, n=40):
        return self.inner.logs_tail(n)


class RacingProbeBackend:
    """G5 drift-race fake: requested_serving() lets a switch run to
    COMPLETION (once) — the drift observation is then between its commit
    point and its next state write, with the generation already moved.
    ctrl is assigned by the test only after adopt(), so the adoption's own
    requested_serving() call does not trigger the race."""

    supports_drift_check = True

    def __init__(self, inner):
        self.inner = inner
        self.ctrl = None
        self.armed = True

    def inspect(self):
        return self.inner.inspect()

    def replace(self, *args, **kwargs):
        return self.inner.replace(*args, **kwargs)

    def check_alive(self):
        return self.inner.check_alive()

    def requested_serving(self):
        if self.armed and self.ctrl is not None:
            self.armed = False
            self.ctrl.run_switch("gpt-oss-120b", "api")
        return self.inner.requested_serving()

    def commit_adoption(self, obs):
        return self.inner.commit_adoption(obs)

    def logs_tail(self, n=40):
        return self.inner.logs_tail(n)


# ------------------------------------------------- 11-12. redaction + RBAC


class ReadinessGateTests(unittest.TestCase):
    """F2: readiness may only be decided once the REQUESTED pod is serving;
    before that, /v1/models can still be answered by the old pod."""

    def test_requested_serving_tracks_the_requested_pod_only(self):
        api = FakeKubeAPI(make_deployment())
        ctrl, _, backend = make_kube_controller(api)
        backend._requested = "1763000000000-newnew"

        old = api.roll_out("running", terminate_old=False)
        old["metadata"]["annotations"][kube.ANN_REQUESTED] = \
            "1762999999999-oldold"
        self.assertFalse(backend.requested_serving())  # old pod only

        new = api.roll_out("running", terminate_old=False)
        new["metadata"]["annotations"][kube.ANN_REQUESTED] = \
            backend._requested
        self.assertTrue(backend.requested_serving())   # requested + ready

        new["metadata"]["deletionTimestamp"] = "2026-11-12T00:00:00Z"
        self.assertFalse(backend.requested_serving())  # being deleted

        new["metadata"].pop("deletionTimestamp")
        new["status"] = pod_status("pending")
        self.assertFalse(backend.requested_serving())  # exists, not ready

    def test_ready_waits_for_the_requested_pod_not_the_old_answer(self):
        # SAME-PROFILE replace (recovery re-applying the running profile):
        # the old pod is Running+Ready and answers /v1/models with the
        # expected id, while the new pod (new requested-at) appears only
        # after two polls. Readiness must wait for the new pod.
        api = FakeKubeAPI(make_deployment(profile="qwen3-coder"))
        old = api.roll_out("running", terminate_old=False)
        ctrl, clock, backend = make_kube_controller(
            api, http_get=served_now_http(api), ready_poll_seconds=5)
        ctrl.adopt()
        self.assertEqual(ctrl.status()["state"], "ready")

        # the Deployment controller needs two poll iterations (check_alive +
        # requested_serving lists each) before it creates the replacement
        # pod; reset the counter so it counts lists from NOW on — adopt()'s
        # own inspect list must not eat into the skip budget
        api.roll_states = ["running"]
        api.roll_after_lists = 4
        api._lists_seen = 0
        clock.t += 1.0
        started = clock.t
        ctrl.run_switch("qwen3-coder", "api")   # same profile, new attempt

        st = ctrl.status()
        self.assertEqual(st["state"], "ready")
        self.assertEqual(st["current"], "qwen3-coder")
        # at least two poll intervals passed before ready was declared (the
        # old pod answering the probe correctly was NOT enough)
        self.assertGreaterEqual(clock.t - started, 10)
        # and the pod that made it ready carries THIS attempt's annotation
        pod, list_failed = backend._select_pod(backend._requested)
        self.assertFalse(list_failed)
        self.assertIsNotNone(pod)
        self.assertEqual(
            (pod.get("metadata") or {}).get("annotations")
            .get(kube.ANN_PROFILE), "qwen3-coder")
        self.assertIsNotNone(
            (pod.get("metadata") or {}).get("annotations")
            .get(kube.ANN_REQUESTED))
        # the old pod (still alive, still Running+Ready) is not the one
        self.assertIsNot(pod, old)


class RedactionAndScopeTests(unittest.TestCase):
    def test_failure_reason_with_secrets_is_redacted_everywhere(self):
        # the backend FAILURE REASON (not just the log tail) is untrusted
        # text: here the ReplicaFailure condition message quotes both the
        # API key and the switch token. Neither may survive into the stored
        # last_error nor into the logged failure.
        api = FakeKubeAPI(make_deployment())
        api.deployment["status"]["conditions"] = [{
            "type": "ReplicaFailure", "status": "True",
            "reason": "FailedCreate",
            "message": ('pods "vllm-coder-1" is forbidden: token ' + TOKEN +
                        " key " + VLLM_KEY),
        }]
        ctrl, _, _ = make_kube_controller(api)
        with self.assertLogs("spark-switch", level="WARNING") as captured:
            ctrl.request_switch("gpt-oss-120b")

        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertNotIn(VLLM_KEY, st["last_error"])
        self.assertNotIn(TOKEN, st["last_error"])
        self.assertIn("***", st["last_error"])
        logged = "\n".join(captured.output)
        self.assertNotIn(VLLM_KEY, logged)
        self.assertNotIn(TOKEN, logged)
        self.assertIn("***", logged)

    def test_log_tail_with_secrets_is_redacted_in_status(self):
        api = rolling_api(make_deployment(), ["imagepull", "running"])
        api.log_text = ("INFO: loading weights; api key " + VLLM_KEY +
                        " and switch token " + TOKEN + "\n")
        ctrl, _, _ = make_kube_controller(
            api, http_get=served_now_http(api))
        ctrl.request_switch("gpt-oss-120b")
        st = ctrl.status()
        self.assertEqual(st["state"], "failed")
        self.assertNotIn(VLLM_KEY, json.dumps(st))
        self.assertNotIn(TOKEN, json.dumps(st))
        self.assertIn("***", st["last_error"])

    def test_every_recorded_path_stays_inside_the_rbac_scope(self):
        self.assertTrue(ALL_CALLS, "no kube calls were recorded at all")
        for method, path in ALL_CALLS:
            ok = ((method in ("GET", "PATCH") and path == DEPLOY_PATH)
                  or (method == "GET" and path == PODS_PATH)
                  or (method == "GET" and LOG_PATH_RE.match(path)))
            if not ok:
                self.fail(f"out-of-scope request: {method} {path}")
        # the suite actually exercised all three shapes (not a vacuous pass)
        self.assertTrue(any(m == "PATCH" and p == DEPLOY_PATH
                            for m, p in ALL_CALLS))
        self.assertTrue(any(m == "GET" and p == PODS_PATH
                            for m, p in ALL_CALLS))
        self.assertTrue(any(m == "GET" and LOG_PATH_RE.match(p)
                            for m, p in ALL_CALLS))


# ---------------------------------------------------------------- 13. KubeAPI


def _extract_ca_cert(directory):
    """First PEM certificate from a system CA bundle, or None."""
    for path in ("/etc/ssl/cert.pem", "/etc/ssl/certs/ca-certificates.crt",
                 "/usr/local/etc/openssl@3/cert.pem",
                 "/usr/local/etc/openssl/cert.pem"):
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as f:
            text = f.read()
        start = text.find("-----BEGIN CERTIFICATE-----")
        end = text.find("-----END CERTIFICATE-----", start)
        if start >= 0 and end > start:
            cert = text[start:end + len("-----END CERTIFICATE-----")] + "\n"
            out = os.path.join(directory, "ca.pem")
            with open(out, "w", encoding="utf-8") as f:
                f.write(cert)
            return out
    return None


class FakeHTTPSConnection:
    captured = []

    def __init__(self, host, port, timeout=None, context=None):
        self.host = host
        self.port = port
        self.timeout = timeout
        self.context = context
        self.requests = []
        self.closed = False
        FakeHTTPSConnection.captured.append(self)

    def request(self, method, path, body=None, headers=None):
        self.requests.append((method, path, body, dict(headers or {})))

    def getresponse(self):
        class Response:
            status = 200

            def read(self):
                return b"{}"

        return Response()

    def close(self):
        self.closed = True


class KubeAPITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        ca = _extract_ca_cert(self.tmp)
        if ca is None:
            raise unittest.SkipTest("no system CA bundle to build a cafile")
        self.token_path = os.path.join(self.tmp, "token")
        self._write_token("token-one")
        self.api = kube.KubeAPI("10.0.0.1", 6443, self.token_path, ca)
        FakeHTTPSConnection.captured = []
        self._original = kube._HTTPSConnection
        kube._HTTPSConnection = FakeHTTPSConnection
        self.addCleanup(setattr, kube, "_HTTPSConnection", self._original)

    def _write_token(self, value):
        with open(self.token_path, "w", encoding="utf-8") as f:
            f.write(value + "\n")

    def test_token_file_is_reread_on_every_request(self):
        status, _ = self.api.request("GET", "/api")
        self.assertEqual(status, 200)
        conn = FakeHTTPSConnection.captured[-1]
        self.assertEqual(conn.requests[0][3]["Authorization"],
                         "Bearer token-one")
        self._write_token("token-two")   # projected token rotated
        status, _ = self.api.request("GET", "/api")
        self.assertEqual(status, 200)
        conn = FakeHTTPSConnection.captured[-1]
        self.assertEqual(conn.requests[0][3]["Authorization"],
                         "Bearer token-two")  # rotated token used

    def test_headers_and_json_body(self):
        status, _ = self.api.request(
            "PATCH", "/apis/apps/v1/x",
            body={"spec": {"replicas": 1}},
            content_type="application/merge-patch+json")
        self.assertEqual(status, 200)
        conn = FakeHTTPSConnection.captured[-1]
        method, path, body, headers = conn.requests[0]
        self.assertEqual((method, path), ("PATCH", "/apis/apps/v1/x"))
        self.assertEqual(headers["Authorization"], "Bearer token-one")
        self.assertEqual(headers["Accept"], "application/json")
        self.assertEqual(headers["Content-Type"],
                         "application/merge-patch+json")
        self.assertEqual(json.loads(body.decode()),
                         {"spec": {"replicas": 1}})

    def test_transport_error_becomes_switch_failure_without_token(self):
        class DeadConnection(FakeHTTPSConnection):
            def request(self, method, path, body=None, headers=None):
                raise ConnectionResetError("connection reset by peer")

        kube._HTTPSConnection = DeadConnection
        with self.assertRaises(spark_switch.SwitchFailure) as cm:
            self.api.request("GET",
                             "/apis/apps/v1/namespaces/x/deployments/y")
        text = str(cm.exception)
        self.assertIn("GET", text)
        self.assertIn("/apis/apps/v1/namespaces/x/deployments/y", text)
        self.assertNotIn("token-one", text)       # never the token
        self.assertNotIn("reset by peer", text)   # no raw exception text

    def test_missing_incluster_env_is_config_error(self):
        with self.assertRaises(spark_switch.ConfigError):
            kube.KubeAPI.from_incluster({})
        with self.assertRaises(spark_switch.ConfigError):
            kube.KubeAPI.from_incluster({
                "KUBERNETES_SERVICE_HOST": "10.0.0.1",
                "KUBERNETES_SERVICE_PORT": "6443",
                # no projected service-account token on this machine
            })


# ---------------------------------------------- 14. config + full docker=None


class KubeConfigTests(unittest.TestCase):
    def _write_env(self, text, mode=0o600):
        fd, path = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(path, mode)
        self.addCleanup(lambda: (os.chmod(path, 0o600), os.unlink(path)))
        return path

    def test_backend_kubernetes_needs_no_hf_cache_host(self):
        path = self._write_env("SWITCH_TOKEN=" + "x" * 30 + "\n"
                               "BACKEND=kubernetes\n")
        cfg = spark_switch.load_config(path, {})
        self.assertEqual(cfg.backend, "kubernetes")
        self.assertEqual(cfg.k8s_namespace, "spark-llm")
        self.assertEqual(cfg.k8s_deployment, "vllm-coder")
        self.assertEqual(cfg.k8s_container, "vllm")
        self.assertEqual(cfg.k8s_pod_selector, "app=vllm-coder")
        self.assertEqual(cfg.unschedulable_seconds, 120)

    def test_invalid_backend_rejected(self):
        path = self._write_env("SWITCH_TOKEN=" + "x" * 30 + "\n"
                               "BACKEND=containers\n")
        with self.assertRaises(spark_switch.ConfigError):
            spark_switch.load_config(path, {})

    def test_process_env_vllm_api_key_wins_over_file(self):
        fd, vpath = tempfile.mkstemp()
        with os.fdopen(fd, "w") as f:
            f.write("VLLM_API_KEY=file-key-value\n")
        os.chmod(vpath, 0o600)
        self.addCleanup(lambda: os.unlink(vpath))
        path = self._write_env(
            "SWITCH_TOKEN=" + "x" * 30 + "\n"
            "HF_CACHE_HOST=/home/u/.cache/huggingface\n")
        cfg = spark_switch.load_config(path, {"VLLM_ENV_FILE": vpath})
        self.assertEqual(cfg.vllm_api_key, "file-key-value")
        cfg = spark_switch.load_config(
            path, {"VLLM_ENV_FILE": vpath, "VLLM_API_KEY": "env-key-value"})
        self.assertEqual(cfg.vllm_api_key, "env-key-value")

    def test_exception_identity_is_shared_with_spark_common(self):
        import spark_common
        self.assertIs(spark_switch.SwitchFailure, spark_common.SwitchFailure)
        self.assertIs(spark_switch.ConfigError, spark_common.ConfigError)
        self.assertIs(spark_switch.ProfileError, spark_common.ProfileError)


class FullLifecycleWithDockerNoneTests(unittest.TestCase):
    """The whole surface with docker=None: any leftover use of self.docker
    in a Controller method would raise AttributeError here."""

    def test_adopt_switch_recovery_idle_status_drift(self):
        api = FakeKubeAPI(make_deployment(profile="qwen3-coder"))
        api.roll_out("running", terminate_old=False)
        ctrl, clock, _ = make_kube_controller(
            api, http_get=kube_models_http(api, served="qwen3-coder"))
        ctrl.adopt()
        self.assertEqual(ctrl.status()["state"], "ready")

        # a switch that fails and recovers (drives replace/check_alive/logs)
        api.log_text = "ERROR: boom; key=" + VLLM_KEY + "\n"
        api.roll_states = ["imagepull", "running", "running", "running"]
        ctrl.http_get = served_now_http(api)
        ctrl.request_switch("gpt-oss-120b")
        self.assertEqual(ctrl.status()["state"], "failed")
        self.assertEqual(ctrl.status()["current"], "qwen3-coder")

        # a successful switch (past the cooldown; failed state accepts)
        clock.t += ctrl.config.cooldown_seconds + 1
        status, _ = ctrl.request_switch("qwen3-vl-30b")
        self.assertEqual(status, 202)
        self.assertEqual(ctrl.status()["state"], "ready")
        self.assertEqual(ctrl.status()["current"], "qwen3-vl-30b")

        # idle auto-return to the default (time passes before idle fires)
        clock.t += 60
        with ctrl._lock:
            ctrl._s.last_activity = clock.t - 31 * 60
        ctrl.idle_tick()
        self.assertEqual(ctrl.status()["current"], "qwen3-coder")
        self.assertEqual(ctrl.status()["reason"], "idle")

        # drift check with no drift changes nothing
        ctrl.drift_check()
        self.assertEqual(ctrl.status()["state"], "ready")
        self.assertEqual(ctrl.status()["current"], "qwen3-coder")


if __name__ == "__main__":
    unittest.main()
