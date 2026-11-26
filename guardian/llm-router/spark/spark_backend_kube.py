"""Kubernetes backend: patches one Deployment instead of recreating a
container, using only the Python standard library (http.client + ssl).

RBAC scope: the backend may only ever request
  - GET/PATCH /apis/apps/v1/namespaces/<ns>/deployments/<deploy>
  - GET      /api/v1/namespaces/<ns>/pods?labelSelector=<selector>
  - GET      /api/v1/namespaces/<ns>/pods/<pod>/log?container=...&tailLines=...
(the test suite asserts this). Never secrets, replicasets, events, or other
deployments.
"""

from __future__ import annotations

import http.client
import json
import secrets
import ssl
import time
import urllib.parse

from spark_common import ConfigError, Observed, SwitchFailure

# Module-level names so tests can monkeypatch the transport without touching
# the real class binding used elsewhere.
_HTTPSConnection = http.client.HTTPSConnection

ANN_PROFILE = "spark-switch/profile"
ANN_REQUESTED = "spark-switch/requested-at"

SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"

# Container waiting reasons that mean the rollout can never become ready.
# ErrImageNeverPull is the offline-installed cluster's equivalent of
# ImagePullBackOff: imagePullPolicy forbids the pull and the image is not in
# containerd — waiting the full READY_TIMEOUT would only waste half an hour.
FATAL_WAITING_REASONS = frozenset({
    "ImagePullBackOff", "ErrImagePull", "ErrImageNeverPull", "InvalidImageName",
    "CreateContainerConfigError", "CreateContainerError", "CrashLoopBackOff",
})

MAX_API_MESSAGE_CHARS = 300


def pod_args(profile):
    """The Deployment container args for a profile: exactly the Docker Cmd
    minus the leading "vllm serve" (the manifest sets command: [vllm, serve])."""
    return [profile.model, "--served-model-name", profile.name,
            "--host", "0.0.0.0", "--port", "8000", *profile.args]


class KubeAPI:
    """Minimal in-cluster Kubernetes API client (stdlib only). The bearer
    token file is re-read on every request: projected tokens rotate."""

    def __init__(self, host, port, token_path, ca_path, timeout=30):
        self.host = host
        self.port = port
        self.token_path = token_path
        self.ca_path = ca_path
        self.timeout = timeout

    @classmethod
    def from_incluster(cls, environ):
        host = environ.get("KUBERNETES_SERVICE_HOST", "")
        port = environ.get("KUBERNETES_SERVICE_PORT", "")
        if not host or not port:
            raise ConfigError(
                "KUBERNETES_SERVICE_HOST/PORT are not set; "
                "not running inside a k8s pod?")
        try:
            port = int(port)
        except ValueError:
            raise ConfigError(
                f"KUBERNETES_SERVICE_PORT={port!r} is not a port number")
        token_path = f"{SA_DIR}/token"
        ca_path = f"{SA_DIR}/ca.crt"
        try:
            with open(token_path, encoding="utf-8"):
                pass
        except OSError:
            raise ConfigError(
                f"in-cluster token {token_path} is missing; "
                "not running inside a k8s pod?")
        return cls(host, port, token_path, ca_path)

    def request(self, method, path, body=None, content_type="application/json"):
        """One request. Returns (status, bytes). Transport failures become
        SwitchFailure("<method> <path>: <ExceptionType>") — never the token,
        never raw exception text (it could quote request headers)."""
        payload = None
        headers = {"Accept": "application/json"}
        if body is not None:
            payload = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = content_type
        conn = None
        try:
            # Re-read on every request: projected tokens rotate.
            with open(self.token_path, encoding="utf-8") as f:
                headers["Authorization"] = "Bearer " + f.read().strip()
            context = ssl.create_default_context(cafile=self.ca_path)
            conn = _HTTPSConnection(self.host, self.port, timeout=self.timeout,
                                    context=context)
            conn.request(method, path, body=payload, headers=headers)
            resp = conn.getresponse()
            return resp.status, resp.read()
        except (OSError, http.client.HTTPException, ssl.SSLError) as e:
            raise SwitchFailure(
                f"{method} {path}: {type(e).__name__}") from e
        finally:
            if conn is not None:
                conn.close()


def _clip(text, limit=MAX_API_MESSAGE_CHARS):
    if not isinstance(text, str):
        return ""
    return text[:limit]


class KubeBackend:
    """Serves profiles by patching spec.template of one Deployment and
    waiting for the pod that carries this attempt's requested-at
    annotation."""

    supports_drift_check = True

    def __init__(self, config, profiles, api, clock=time.time, nonce=None):
        self.config = config
        self.profiles = profiles
        self.api = api
        self.clock = clock or time.time
        # optional zero-arg callable returning the 6-char nonce (tests)
        self._nonce = nonce
        # rollout bookkeeping
        self._requested = None            # ANN_REQUESTED of this attempt
        self._requested_since = None
        self._patched_generation = None   # metadata.generation from PATCH
        self._unschedulable_since = None
        self._restart_seen = False

    # -- paths ----------------------------------------------------------------

    @property
    def _ns(self):
        return self.config.k8s_namespace

    @property
    def deploy_path(self):
        return (f"/apis/apps/v1/namespaces/{self._ns}/"
                f"deployments/{self.config.k8s_deployment}")

    @property
    def pods_path(self):
        selector = urllib.parse.quote(self.config.k8s_pod_selector, safe="")
        return f"/api/v1/namespaces/{self._ns}/pods?labelSelector={selector}"

    def _log_path(self, pod_name, tail, previous):
        query = f"container={self.config.k8s_container}&tailLines={tail}"
        if previous:
            query += "&previous=true"
        return f"/api/v1/namespaces/{self._ns}/pods/{pod_name}/log?{query}"

    # -- helpers --------------------------------------------------------------

    def _nonce6(self):
        if self._nonce is not None:
            return self._nonce()
        return secrets.token_hex(3)  # 6 chars from [0-9a-f]

    def _container_status(self, pod):
        for cs in (pod.get("status") or {}).get("containerStatuses") or []:
            if cs.get("name") == self.config.k8s_container:
                return cs
        return None

    def _profile_from_template(self, template):
        annotations = ((template.get("metadata") or {}).get("annotations")
                       or {})
        name = annotations.get(ANN_PROFILE)
        if name in self.profiles:
            return name
        for container in (template.get("spec") or {}).get("containers") or []:
            if container.get("name") != self.config.k8s_container:
                continue
            args = container.get("args") or []
            for i, arg in enumerate(args):
                if (arg == "--served-model-name" and i + 1 < len(args)
                        and args[i + 1] in self.profiles):
                    return args[i + 1]
        return None

    def _select_pod(self, requested):
        """Returns (pod_or_None, list_failed). list_failed is True when the
        pod list call failed (transport or non-200): callers decide whether
        that means "keep waiting" (check_alive) or "unknown" (inspect).
        `requested` is the ANN_REQUESTED value to match — an explicit
        parameter (not self._requested) so inspect() can select for the
        template it just read without touching this attempt's bookkeeping."""
        try:
            status, data = self.api.request("GET", self.pods_path)
        except SwitchFailure:
            return None, True
        if status != 200:
            return None, True
        try:
            items = json.loads(data).get("items") or []
        except ValueError:
            return None, True
        live = []
        for pod in items:
            meta = pod.get("metadata") or {}
            if meta.get("deletionTimestamp"):
                continue  # old pod during the Recreate gap
            if (requested is not None
                    and ((meta.get("annotations") or {})
                         .get(ANN_REQUESTED) != requested)):
                continue
            live.append(pod)
        if not live:
            return None, False
        newest = max(
            live,
            key=lambda p: (p.get("metadata") or {}).get("creationTimestamp")
            or "")
        return newest, False

    def _deployment_condition_failure(self):
        """Deployment-level failure signals, trusted only when the observed
        generation has caught up with the generation of our PATCH (or, when
        adopted, with the Deployment's own metadata.generation). A stale
        condition during the Recreate gap must not fail a healthy switch."""
        try:
            status, data = self.api.request("GET", self.deploy_path)
        except SwitchFailure:
            return None
        if status != 200:
            return None
        try:
            deployment = json.loads(data)
        except ValueError:
            return None
        meta = deployment.get("metadata") or {}
        stat = deployment.get("status") or {}
        observed = stat.get("observedGeneration")
        if isinstance(observed, int):
            target = self._patched_generation
            if not isinstance(target, int):
                target = meta.get("generation")
            if not (isinstance(target, int) and observed >= target):
                return None  # conditions predate the patch we are waiting on
        else:
            return None
        for condition in stat.get("conditions") or []:
            ctype = condition.get("type")
            if ctype == "ReplicaFailure" and condition.get("status") == "True":
                # This is how a Pod Security Admission rejection shows up.
                return (f"pod creation refused: {condition.get('reason', '')}: "
                        f"{_clip(condition.get('message', ''))}")
            if (ctype == "Progressing"
                    and condition.get("reason") == "ProgressDeadlineExceeded"):
                return "rollout progress deadline exceeded"
        return None

    # -- backend interface ------------------------------------------------------

    def replace(self, profile, set_phase):
        cfg = self.config
        set_phase("patching")
        requested = f"{int(self.clock() * 1000)}-{self._nonce6()}"
        self._requested = requested
        self._requested_since = self.clock()
        self._unschedulable_since = None
        self._restart_seen = False
        body = {
            "spec": {
                "template": {
                    "metadata": {
                        "annotations": {
                            ANN_PROFILE: profile.name,
                            ANN_REQUESTED: requested,
                        },
                    },
                    "spec": {
                        "containers": [{
                            "name": cfg.k8s_container,
                            "args": pod_args(profile),
                        }],
                    },
                },
            },
        }
        status, data = self.api.request(
            "PATCH", self.deploy_path, body=body,
            content_type="application/strategic-merge-patch+json")
        if status == 404:
            self._requested = None
            raise SwitchFailure(
                f"deployment {cfg.k8s_deployment} not found in "
                f"{self._ns} (manifests applied?)")
        if status != 200:
            self._requested = None
            reason = ""
            try:
                reason = json.loads(data).get("message", "") or ""
            except ValueError:
                pass
            raise SwitchFailure(f"patch returned {status}: {_clip(reason)}")
        try:
            self._patched_generation = ((json.loads(data).get("metadata")
                                         or {}).get("generation"))
        except ValueError:
            self._patched_generation = None
        set_phase("rolling out")

    def check_alive(self):
        """Evaluated in order; returns a failure reason string or None."""
        pod, list_failed = self._select_pod(self._requested)
        if list_failed:
            return None  # (a) API hiccup: keep waiting, timeout still applies
        if pod is None:
            return self._deployment_condition_failure()  # (b)

        now = self.clock()
        status = pod.get("status") or {}

        # (c) Unschedulable long enough
        unschedulable = None
        for condition in status.get("conditions") or []:
            if (condition.get("type") == "PodScheduled"
                    and condition.get("status") == "False"
                    and condition.get("reason") == "Unschedulable"):
                unschedulable = condition
                break
        if unschedulable is not None:
            if self._unschedulable_since is None:
                self._unschedulable_since = now
                return None
            elapsed = now - self._unschedulable_since
            if elapsed >= self.config.unschedulable_seconds:
                return (f"pod unschedulable for {int(elapsed)} s: "
                        f"{_clip(unschedulable.get('message', ''))}")
            return None
        self._unschedulable_since = None

        cs = self._container_status(pod)
        if cs is not None:
            # (d0) a restart happened at some point: the interesting logs are
            # those of the PREVIOUS container instance, even when the current
            # state is a fatal waiting reason (CrashLoopBackOff back-offs do
            # not reset restartCount, and the restart branch below would
            # never run if the waiting check returned first).
            if (cs.get("restartCount") or 0) > 0:
                self._restart_seen = True
            # (d) fatal container waiting reasons
            waiting = (cs.get("state") or {}).get("waiting") or {}
            reason = waiting.get("reason", "")
            if reason in FATAL_WAITING_REASONS:
                return (f"container waiting: {reason}: "
                        f"{_clip(waiting.get('message', ''))}")
            # (d1) the container DIED and kubelet has not restarted it yet
            # (restartCount still 0): fail fast; logs_tail then reads the
            # current (dead) container, so previous stays false.
            terminated = (cs.get("state") or {}).get("terminated") or {}
            if terminated:
                return (f"container terminated: "
                        f"{terminated.get('reason', 'Unknown')} "
                        f"(exit {terminated.get('exitCode', '?')})")
            # (e) a restart of the serving container fails the attempt
            if (cs.get("restartCount") or 0) > 0:
                terminated = ((cs.get("lastState") or {}).get("terminated")
                              or {})
                return (f"container restarted: "
                        f"{terminated.get('reason', 'Unknown')} "
                        f"(exit {terminated.get('exitCode', '?')})")

        # (f) pod phase Failed
        if status.get("phase") == "Failed":
            return f"pod failed: {status.get('reason', '')}"
        return None

    def requested_serving(self):
        """True only when the pod THIS attempt waits for exists, is not being
        deleted, and reports serving readiness: the serving container's
        status has ready == true, or the pod has condition Ready == True.
        While False the controller must not trust /v1/models: right after a
        patch the Service can still route to the OLD pod, which on a
        same-profile replace answers with the expected model id."""
        pod, list_failed = self._select_pod(self._requested)
        if list_failed or pod is None:
            return False
        cs = self._container_status(pod)
        if cs is not None and cs.get("ready") is True:
            return True
        for condition in (pod.get("status") or {}).get("conditions") or []:
            if (condition.get("type") == "Ready"
                    and condition.get("status") == "True"):
                return True
        return False

    def logs_tail(self, n=40):
        try:
            pod, list_failed = self._select_pod(self._requested)
            if list_failed or pod is None:
                return ""
            name = (pod.get("metadata") or {}).get("name")
            if not name:
                return ""
            status, data = self.api.request(
                "GET", self._log_path(name, n, self._restart_seen))
            if status != 200:
                return ""
            return data.decode("utf-8", "replace")
        except Exception:
            return ""

    def commit_adoption(self, obs):
        """Record an adopted rollout as THIS controller's attempt. The
        controller calls this under its lock, only when an observation is
        actually applied (and before it starts waiting on the adopted
        workload), so a replace() that lands meanwhile is never overwritten
        by a stale inspection."""
        self._requested = obs.requested
        self._requested_since = self.clock()
        self._patched_generation = obs.generation
        self._unschedulable_since = None
        self._restart_seen = False

    def inspect(self):
        """Read-only: NEVER writes attempt bookkeeping (drift_check calls
        this unlocked; a replace() racing the inspection would otherwise be
        overwritten with the stale template's value). The template's
        requested-at and the Deployment generation travel inside the
        Observed; commit_adoption() is what turns them into bookkeeping."""
        try:
            status, data = self.api.request("GET", self.deploy_path)
        except SwitchFailure as e:
            return Observed(None, "unknown", str(e))
        if status == 404:
            return Observed(None, "absent", "deployment not found")
        if status != 200:
            return Observed(None, "unknown", f"deployment get returned {status}")
        try:
            deployment = json.loads(data)
        except ValueError:
            return Observed(None, "unknown", "deployment get: invalid JSON")

        spec = deployment.get("spec") or {}
        template = spec.get("template") or {}
        annotations = ((template.get("metadata") or {}).get("annotations")
                       or {})
        # Adopt an in-progress rollout: wait on the pod that carries the
        # template's requested-at annotation.
        requested = annotations.get(ANN_REQUESTED)
        generation = (deployment.get("metadata") or {}).get("generation")
        profile = self._profile_from_template(template)
        if spec.get("replicas") == 0:
            return Observed(profile, "absent", "scaled to 0",
                            requested=requested, generation=generation)

        pod, list_failed = self._select_pod(requested)
        if list_failed:
            return Observed(profile, "unknown", "pod list failed",
                            requested=requested, generation=generation)
        if pod is None:
            return Observed(profile, "pending", "no matching pod yet",
                            requested=requested, generation=generation)
        status_obj = pod.get("status") or {}
        cs = self._container_status(pod)
        if cs is not None:
            if (cs.get("state") or {}).get("running"):
                return Observed(profile, "running", "",
                                requested=requested, generation=generation)
            waiting = (cs.get("state") or {}).get("waiting") or {}
            if (waiting.get("reason") in FATAL_WAITING_REASONS
                    or (cs.get("restartCount") or 0) > 0):
                return Observed(profile, "failed",
                                f"container waiting: "
                                f"{waiting.get('reason', 'restarted')}",
                                requested=requested, generation=generation)
        if status_obj.get("phase") == "Failed":
            return Observed(profile, "failed",
                            f"pod failed: {status_obj.get('reason', '')}",
                            requested=requested, generation=generation)
        return Observed(profile, "pending", status_obj.get("phase", ""),
                        requested=requested, generation=generation)
