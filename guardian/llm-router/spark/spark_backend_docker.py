"""Docker backend: drives the managed vLLM container(s) through the Docker
Engine API over the unix socket.

Everything in here is the pre-k8s behaviour, moved verbatim from
spark_switch.py so the existing Docker tests keep passing unchanged. The
controller talks to this class through the same small surface the Kubernetes
backend implements (inspect / replace / check_alive / logs_tail), plus the
slot extension (remove_slots / start_slot) that only this backend provides.

Slots: with RESIDENT_PROFILES empty there is exactly one container (slot 0,
name MANAGED_CONTAINER), which is the historical behaviour. With residents
configured, slot i serves RESIDENT_PROFILES[i] as container
f"{MANAGED_CONTAINER}-{i}" (slot 0 keeps the bare name) on host port
VLLM_HOST_PORT + i; the container port is always 8000. The set of names the
backend may ever stop or remove is derived from the config alone — never by
enumerating containers: a preserved backup container on the host carries the
managed label and must never be touched.
"""

from __future__ import annotations

import json
import struct

from spark_common import LABEL_MANAGED, LABEL_PROFILE, Observed, SwitchFailure


def decode_docker_logs(data: bytes) -> str:
    """Decode the Docker multiplexed stream format (8-byte headers:
    stream byte, 3 zero bytes, big-endian uint32 length). Falls back to
    plain text when the data does not look multiplexed."""
    if not data:
        return ""
    chunks = []
    i = 0
    n = len(data)
    while i < n:
        if n - i < 8:
            return data.decode("utf-8", "replace")
        header = data[i:i + 8]
        if header[1:4] != b"\x00\x00\x00":
            return data.decode("utf-8", "replace")
        if header[0] > 2:
            return data.decode("utf-8", "replace")
        length = struct.unpack(">I", data[i + 4:i + 8])[0]
        i += 8
        if i + length > n:
            return data.decode("utf-8", "replace")
        chunks.append(data[i:i + length])
        i += length
    return b"".join(chunks).decode("utf-8", "replace")


def build_create_body(config, profile, host_port=None):
    """The container definition for `docker create` (moved from
    Controller.build_create_body; the controller keeps a delegating method
    for compatibility). host_port None means config.vllm_host_port (slot 0);
    slots > 0 pass their own port while the container port stays 8000."""
    cfg = config
    if host_port is None:
        host_port = cfg.vllm_host_port
    # Offline (air-gapped) installs: keep huggingface_hub / transformers /
    # tiktoken from reaching the network. VLLM_OFFLINE off must leave the
    # body byte-identical to the pre-offline behaviour (legacy tests).
    env = ["VLLM_API_KEY=" + cfg.vllm_api_key]
    if getattr(cfg, "vllm_offline", False):
        env += ["HF_HUB_OFFLINE=1",
                "TRANSFORMERS_OFFLINE=1",
                "TIKTOKEN_ENCODINGS_BASE=/root/.cache/huggingface/tiktoken"]
    return {
        "Image": cfg.vllm_image,
        "Cmd": ["vllm", "serve", profile.model,
                "--served-model-name", profile.name,
                "--host", "0.0.0.0", "--port", "8000",
                *profile.args],
        "Env": env,
        "Labels": {LABEL_PROFILE: profile.name, LABEL_MANAGED: "1"},
        "ExposedPorts": {"8000/tcp": {}},
        "HostConfig": {
            "Binds": [cfg.hf_cache_host + ":/root/.cache/huggingface"],
            "PortBindings": {
                "8000/tcp": [{"HostIp": "0.0.0.0",
                              "HostPort": str(host_port)}]},
            "IpcMode": "host",
            "ShmSize": 67108864,
            "Ulimits": [
                {"Name": "memlock", "Soft": -1, "Hard": -1},
                {"Name": "stack", "Soft": 67108864, "Hard": 67108864},
            ],
            "RestartPolicy": {"Name": "unless-stopped"},
            "DeviceRequests": [
                {"Driver": "", "Count": -1, "Capabilities": [["gpu"]]}],
        },
    }


class DockerBackend:
    """Backend over the Docker Engine API (`docker` is a DockerAPI instance,
    or any object with .request(method, path, body=None, timeout=None) that
    returns (status, bytes))."""

    supports_drift_check = False

    def __init__(self, config, profiles, docker):
        self.config = config
        self.profiles = profiles
        self.docker = docker
        # Which slot containers belong to the current attempt / serving set
        # (names). remove_slots clears it, start_slot appends, inspect sets
        # it to the containers it found (adoption).
        self._active = [self.slot_name(0)]

    # -- slots ---------------------------------------------------------------

    def slot_name(self, index):
        """Container name of slot i: slot 0 keeps the bare MANAGED_CONTAINER
        name (byte-identical history), slots > 0 are suffixed."""
        if index == 0:
            return self.config.managed_container
        return f"{self.config.managed_container}-{index}"

    def _managed_slot_names(self):
        """Every slot name this backend may ever stop or remove: slots
        0..len(RESIDENT_PROFILES)-1, or just slot 0 when the pair mode is
        off. Derived from config only — never from a container listing."""
        count = max(len(self.config.resident_names), 1)
        return [self.slot_name(i) for i in range(count)]

    # -- inspection ---------------------------------------------------------

    def _profile_from_info(self, info):
        conf = info.get("Config") or {}
        label = (conf.get("Labels") or {}).get(LABEL_PROFILE)
        if label in self.profiles:
            return label
        cmd = conf.get("Cmd") or []
        for i, item in enumerate(cmd):
            if (item == "--served-model-name" and i + 1 < len(cmd)
                    and cmd[i + 1] in self.profiles):
                return cmd[i + 1]
        return None

    def _observe_single(self, name, info):
        """Observed for one existing container (the pre-slot behaviour)."""
        self._active = [name]
        profile = self._profile_from_info(info)
        state = info.get("State") or {}
        if state.get("Running"):
            return Observed(profile, "running", "")
        return Observed(profile, "failed",
                        f"exited (code {state.get('ExitCode')})")

    def _inspect_one(self, name):
        try:
            status, data = self.docker.request("GET", f"/containers/{name}/json")
            if status == 404:
                return Observed(None, "absent", "container not found")
            if status != 200:
                return Observed(None, "unknown", f"inspect returned {status}")
            info = json.loads(data)
        except Exception as e:
            return Observed(None, "unknown", f"inspect failed: {type(e).__name__}")
        return self._observe_single(name, info)

    def inspect(self):
        """Never raises; errors become state "unknown". With the pair mode
        off this is exactly the historical single-container inspect."""
        residents = self.config.resident_names
        if not residents:
            return self._inspect_one(self.slot_name(0))
        names = self._managed_slot_names()
        infos = []
        for name in names:
            try:
                status, data = self.docker.request(
                    "GET", f"/containers/{name}/json")
                if status == 404:
                    infos.append(None)
                    continue
                if status != 200:
                    return Observed(None, "unknown", f"inspect returned {status}")
                infos.append(json.loads(data))
            except ValueError:
                return Observed(None, "unknown", "inspect returned bad json")
            except Exception as e:
                return Observed(None, "unknown",
                                f"inspect failed: {type(e).__name__}")
        existing = [(name, info) for name, info in zip(names, infos)
                    if info is not None]
        self._active = [name for name, _ in existing]
        if len(existing) == len(names):
            if all(self._profile_from_info(info) == residents[i]
                   for i, info in enumerate(infos)):
                running = [bool((info.get("State") or {}).get("Running"))
                           for info in infos]
                if all(running):
                    return Observed("pair", "running", "")
                down = running.index(False)
                state = infos[down].get("State") or {}
                return Observed("pair", "failed",
                                f"slot {names[down]} exited "
                                f"(code {state.get('ExitCode')})")
            return Observed(None, "unknown",
                            "slot containers do not match RESIDENT_PROFILES")
        if len(existing) == 1 and existing[0][0] == names[0]:
            # Only slot 0 is deployed: report it like the single-container
            # controller always did (e.g. an exclusive big-profile load).
            return self._observe_single(names[0], existing[0][1])
        present = ", ".join(name for name, _ in existing) or "none"
        return Observed(None, "unknown", f"partial slot set: {present}")

    def commit_adoption(self, obs):
        """No-op: the Docker backend keeps no rollout bookkeeping (there is
        no in-progress rollout to adopt — replace() removes the old
        container before creating the new one)."""
        pass

    def requested_serving(self):
        """Always True: replace() removes the old container before creating
        the new one, so whatever answers on the mapped port IS the
        workload this attempt waits for."""
        return True

    def check_alive(self):
        """Called on every readiness poll; a non-None string means the
        attempt has failed. Same rules as the old inline Docker inspect:
        only a 200 with a parsable body that says not-Running counts as an
        exit; anything else keeps waiting (transport errors propagate to
        the controller's unexpected-exception path, exactly as before).
        With several active slots the first not-running one fails the
        attempt; a single active slot named MANAGED_CONTAINER keeps the
        historical message."""
        names = list(self._active) or [self.slot_name(0)]
        for name in names:
            status, data = self.docker.request(
                "GET", f"/containers/{name}/json")
            if status != 200:
                continue
            try:
                info = json.loads(data)
            except ValueError:
                continue
            state = info.get("State") or {}
            if not state.get("Running"):
                if names == [self.config.managed_container]:
                    return f"container exited (code {state.get('ExitCode')})"
                return (f"container {name} exited "
                        f"(code {state.get('ExitCode')})")
        return None

    def logs_tail(self, n=40):
        """Raw (un-redacted) log tails of the active slots, concatenated;
        "" on any error; never raises. With more than one active slot each
        tail is prefixed with a "== <name> ==" line."""
        names = list(self._active) or [self.slot_name(0)]
        parts = []
        for name in names:
            try:
                status, data = self.docker.request(
                    "GET",
                    f"/containers/{name}/logs?stdout=1&stderr=1&tail={n}")
                if status == 200:
                    parts.append((name, decode_docker_logs(data)))
            except Exception:
                pass
        if not parts:
            return ""
        if len(parts) == 1:
            return parts[0][1]
        out = []
        for name, tail in parts:
            out.append(f"== {name} ==")
            out.append(tail)
        return "\n".join(out)

    # -- replacement ----------------------------------------------------------

    def remove_slots(self, set_phase):
        """Stop (same timeout handling as always) and force-delete every
        managed slot container. 404/304 are tolerated exactly like the old
        replace() did; anything else raises SwitchFailure. Clears the
        active set on success."""
        cfg = self.config
        set_phase("stopping")
        for cname in self._managed_slot_names():
            # The socket timeout must outlive the stop timeout we ask Docker
            # for: a container that ignores SIGTERM gets SIGKILLed only
            # after stop_timeout seconds, and the HTTP reply arrives after
            # that.
            status, _ = self.docker.request(
                "POST", f"/containers/{cname}/stop?t={cfg.stop_timeout}",
                timeout=cfg.stop_timeout + 30)
            if status not in (204, 304, 404):
                raise SwitchFailure(f"stop returned {status}")
            status, _ = self.docker.request(
                "DELETE", f"/containers/{cname}?force=true")
            if status not in (204, 404):
                raise SwitchFailure(f"delete returned {status}")
        self._active = []

    def start_slot(self, index, profile, set_phase):
        """Create (slot name, host port VLLM_HOST_PORT+index) and start the
        container serving `profile`. Raises SwitchFailure(<short reason>)
        on failure; the controller attaches the redacted log tail."""
        cfg = self.config
        cname = self.slot_name(index)
        if cfg.resident_names:
            set_phase(f"creating {profile.name}")
        else:
            set_phase("creating")
        body = build_create_body(cfg, profile,
                                 host_port=cfg.vllm_host_port + index)
        status, _ = self.docker.request(
            "POST", f"/containers/create?name={cname}", body=body)
        if status != 201:
            raise SwitchFailure(f"create returned {status}")
        status, _ = self.docker.request("POST", f"/containers/{cname}/start")
        if status not in (204, 304):
            raise SwitchFailure(f"start returned {status}")
        self._active.append(cname)

    def replace(self, profile, set_phase):
        """Single-container compatibility path (slot 0): the identical
        stop → delete → create → start request sequence the backend has
        always issued on MANAGED_CONTAINER."""
        self.remove_slots(set_phase)
        self.start_slot(0, profile, set_phase)
