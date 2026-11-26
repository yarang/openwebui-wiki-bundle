#!/usr/bin/env python3
"""Tests for install-spark-k8s.sh. No cluster, no docker, no network: the
external commands are POSIX-sh stubs on a private PATH that log their argv
(one line per invocation, in order) and answer from STUB_* environment
variables. A no-op `sleep` stub keeps every polling loop instant, so the
whole file runs in seconds instead of minutes."""

import os
import subprocess
import tempfile
import shutil
import stat
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
PARENT = os.path.dirname(HERE)
SCRIPT = os.path.join(PARENT, "install-spark-k8s.sh")

VLLM_KEY = "sk-fake-vllm-key-1234567890abcdef"
OLD_TOKEN = "fake-switch-token-abcdefghijklmnop"
SHORT_TOKEN = "tooshort-token"          # < 24 chars: preflight must refuse

KUBECTL_STUB = r"""#!/bin/sh
printf '%s\n' "kubectl $*" >> "$STUB_LOG"
# capture_k_dir: copy the kustomize root (arg after -k or after kustomize)
# so tests can inspect the STAGED overlay (image override checks)
capture_k_dir() {
  [ -n "${STUB_CAPTURE_DIR:-}" ] || return 0
  prev=""
  for a in "$@"; do
    if [ "$prev" = "kustomize" ] || [ "$prev" = "-k" ]; then
      mkdir -p "$STUB_CAPTURE_DIR"
      rm -rf "$STUB_CAPTURE_DIR/overlay"
      cp -R "$a" "$STUB_CAPTURE_DIR/overlay"
      return 0
    fi
    prev="$a"
  done
}
case "$*" in
  *"-f -") cat >> "$STUB_STDIN_FILE"; exit 0 ;;
  "get nodes -o jsonpath="*) echo "${STUB_GPU:-1}"; exit 0 ;;
  "get runtimeclass nvidia") exit "${STUB_RUNTIMECLASS_RC:-0}" ;;
  "get namespace spark-llm") exit "${STUB_NS_RC:-1}" ;;
  "kustomize "*) capture_k_dir "$@"; exit "${STUB_KUSTOMIZE_RC:-0}" ;;
  "apply -k "*) capture_k_dir "$@"; exit "${STUB_APPLY_RC:-0}" ;;
  "apply -f "*) exit "${STUB_APPLY_RC:-0}" ;;
  *"wait --for=delete pod"*) exit "${STUB_WAIT_RC:-0}" ;;
  *"get pods -l"*) echo "${STUB_PODS:-}"; exit "${STUB_GET_PODS_RC:-0}" ;;
  *"scale deploy --all"*) exit "${STUB_SCALE_RC:-0}" ;;
  *"delete service"*) exit "${STUB_DELETE_RC:-0}" ;;
  *"get service "*)
    # per-service existence: 0 only for names in STUB_SERVICES
    name=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "service" ]; then name="$arg"; break; fi
      prev="$arg"
    done
    case " ${STUB_SERVICES:-} " in
      *" $name "*) exit 0 ;;
    esac
    exit 1 ;;
  *"get secret "*)
    name=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "secret" ]; then name="$arg"; break; fi
      prev="$arg"
    done
    case " ${STUB_SECRETS:-} " in
      *" $name "*) exit 0 ;;
    esac
    exit 1 ;;
  *"create secret"*) echo "kind: Secret"; exit 0 ;;
esac
exit 0
"""

DOCKER_STUB = """#!/bin/sh
printf '%s\\n' "docker $*" >> "$STUB_LOG"
exit 0
"""

SUDO_STUB = r"""#!/bin/sh
printf '%s\n' "sudo $*" >> "$STUB_LOG"
case "$*" in
  *"images ls -q"*)
    # ${VAR-default}: an explicitly EMPTY value means "no images present"
    echo "${STUB_CTR_IMAGES-nvcr.io/nvidia/vllm:26.02-py3}"
    exit 0 ;;
esac
exit "${STUB_SUDO_RC:-0}"
"""

CURL_STUB = """#!/bin/sh
printf '%s\\n' "curl $*" >> "$STUB_LOG"
echo '{"ok": true}'
exit 0
"""

SS_STUB = r"""#!/bin/sh
printf '%s\n' "ss $*" >> "$STUB_LOG"
for p in ${STUB_LISTEN_PORTS:-}; do
  echo "LISTEN 0 0 0.0.0.0:$p 0.0.0.0:*"
done
exit 0
"""

# F11: polling loops must never actually wait in tests
SLEEP_STUB = """#!/bin/sh
exit 0
"""


def read_token(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("SWITCH_TOKEN="):
                return line.partition("=")[2].strip()
    return None


class InstallSparkK8sTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(lambda: shutil.rmtree(self.tmp, ignore_errors=True))
        self.stubdir = os.path.join(self.tmp, "bin")
        self.tmpdir = os.path.join(self.tmp, "tmp")   # mktemp -d goes here
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.stubdir)
        os.makedirs(self.tmpdir)
        os.makedirs(self.home)

        for name, body in (("kubectl", KUBECTL_STUB), ("docker", DOCKER_STUB),
                           ("sudo", SUDO_STUB), ("curl", CURL_STUB),
                           ("ss", SS_STUB), ("sleep", SLEEP_STUB)):
            path = os.path.join(self.stubdir, name)
            with open(path, "w", encoding="utf-8") as f:
                f.write(body)
            os.chmod(path, 0o755)

        self.log = os.path.join(self.tmp, "calls.log")
        self.stdin_file = os.path.join(self.tmp, "stdin.yaml")
        self.capture_dir = os.path.join(self.tmp, "capture")

        # the secret-bearing files the installer reads (mode 600)
        vllm_dir = os.path.join(self.home, "vllm-work")
        os.makedirs(vllm_dir)
        self.vllm_env = os.path.join(vllm_dir, ".vllm-env")
        with open(self.vllm_env, "w", encoding="utf-8") as f:
            f.write(f"VLLM_API_KEY={VLLM_KEY}\n")
        os.chmod(self.vllm_env, 0o600)

        switch_dir = os.path.join(self.home, "spark-switch")
        os.makedirs(switch_dir)
        self.switch_env = os.path.join(switch_dir, "env")
        with open(self.switch_env, "w", encoding="utf-8") as f:
            f.write(f"SWITCH_TOKEN={OLD_TOKEN}\nBACKEND=docker\n")
        os.chmod(self.switch_env, 0o600)

        os.makedirs(os.path.join(self.home, ".cache", "huggingface"))

        env = dict(os.environ)
        env["PATH"] = self.stubdir + os.pathsep + env["PATH"]
        env["HOME"] = self.home
        env["TMPDIR"] = self.tmpdir
        env["STUB_LOG"] = self.log
        env["STUB_STDIN_FILE"] = self.stdin_file
        env.pop("OFFLINE", None)   # offline staging must be opt-in
        self.env = env

    # -- helpers --------------------------------------------------------------

    def run_script(self, *args, **env_over):
        # start from an empty log/stdin capture so every assertion in a test
        # reflects THE LAST run, even when the test invokes the script twice
        for path in (self.log, self.stdin_file):
            if os.path.exists(path):
                os.remove(path)
        env = dict(self.env)
        env.update({k: str(v) for k, v in env_over.items()})
        return subprocess.run(["bash", SCRIPT, *args], env=env,
                              capture_output=True, text=True, timeout=120,
                              cwd=PARENT)

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log, encoding="utf-8") as f:
            return [line.rstrip("\n") for line in f if line.strip()]

    def lines_with(self, fragment):
        return [line for line in self.calls() if fragment in line]

    def assert_no_secret_leak(self, proc, *extra):
        blob = proc.stdout + proc.stderr
        for secret in (VLLM_KEY, OLD_TOKEN, *extra):
            self.assertNotIn(secret, blob)

    # -- static checks ---------------------------------------------------------

    def test_bash_n_and_forbidden_constructs(self):
        proc = subprocess.run(["bash", "-n", SCRIPT], capture_output=True,
                              text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(SCRIPT, encoding="utf-8") as f:
            text = f.read()
        self.assertIn("set -euo pipefail", text)
        self.assertNotIn("set -x", text)
        # the portability bans apply to CODE, not to comments explaining them
        code = "\n".join(ln for ln in text.splitlines()
                         if not ln.lstrip().startswith("#"))
        self.assertNotIn("| grep -q", code)      # never with a pipe producer
        self.assertNotIn("sed -i", code)         # BSD/GNU -i differ
        self.assertNotIn("readlink -f", code)    # not on macOS
        self.assertNotIn("mapfile", code)        # bash-4-only
        self.assertNotIn(" timeout ", code)      # GNU coreutils only
        self.assertNotIn("--from-literal", code) # secrets never in argv
        self.assertNotIn("docker rm", code)      # rollback stays reversible

    # -- default action: dry-run -------------------------------------------------

    def test_default_action_is_a_dry_run_that_creates_nothing(self):
        proc = self.run_script()
        self.assertEqual(proc.returncode, 0,
                         proc.stdout + proc.stderr)
        self.assert_no_secret_leak(proc)

        # run() only ECHOES state-changing commands in dry-run mode; every
        # echoed apply is a dry-run
        echoed = [line[2:] for line in proc.stdout.splitlines()
                  if line.startswith("+ ")]
        applies = [line for line in echoed if line.startswith("kubectl apply")]
        self.assertTrue(applies, "no kubectl apply was echoed")
        for line in applies:
            self.assertIn("--dry-run", line, line)
        self.assertIn("--dry-run=server", " ".join(applies))
        self.assertIn("--dry-run=client", " ".join(applies))
        self.assertIn("dry-run complete; nothing was changed", proc.stdout)

        # F7: the read-only validation commands (kustomize build, dry-run
        # applies) DID execute via run_ro — but every apply that actually
        # ran carries --dry-run, so nothing was changed for real
        executed = self.lines_with("kubectl apply")
        self.assertTrue(executed, "dry-run applied nothing read-only")
        for line in executed:
            self.assertIn("--dry-run", line, line)
        self.assertTrue(self.lines_with("kubectl kustomize"))

        # and nothing state-changing executed
        for mutating in ("kubectl create secret", "kubectl rollout",
                         "kubectl scale", "kubectl delete",
                         "docker ", "curl ", "kubectl wait"):
            self.assertEqual(self.lines_with(mutating), [],
                             f"dry-run executed: {mutating}")
        self.assertFalse(os.path.exists(self.stdin_file))

    def test_dry_run_executes_read_only_validation_and_fails_when_it_fails(self):
        # F7: run_ro really runs — a kustomize or dry-run apply failure must
        # exit non-zero instead of printing "dry-run complete"
        proc = self.run_script(STUB_KUSTOMIZE_RC=1)
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn("dry-run complete", proc.stdout)

        proc = self.run_script(STUB_NS_RC=0, STUB_APPLY_RC=1)
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn("dry-run complete", proc.stdout)

    def test_dry_run_with_existing_namespace_uses_server_side_dry_run(self):
        proc = self.run_script(STUB_NS_RC=0)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        echoed = [line[2:] for line in proc.stdout.splitlines()
                  if line.startswith("+ ")]
        applies = [line for line in echoed
                   if line.startswith("kubectl apply -k")]
        self.assertEqual(len(applies), 1)
        self.assertIn("--dry-run=server", applies[0])
        self.assertNotIn("--dry-run=client", applies[0])

    # -- --apply -----------------------------------------------------------------

    def test_apply_creates_secrets_from_env_files_and_applies(self):
        proc = self.run_script("--apply")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assert_no_secret_leak(proc)

        creates = self.lines_with("create secret generic")
        self.assertEqual(len(creates), 2)
        for line in creates:
            self.assertIn("--from-env-file=", line)
            self.assertNotIn("--from-literal", line)
            self.assertIn("--dry-run=client", line)
        self.assertTrue(any("secret generic vllm-api-key" in c for c in creates))
        self.assertTrue(any("secret generic spark-switch-token" in c
                            for c in creates))

        # the generated Secret objects travelled over stdin to a server-side
        # apply, never through argv
        with open(self.stdin_file, encoding="utf-8") as f:
            stdin_blob = f.read()
        self.assertEqual(stdin_blob.count("kind: Secret"), 2)
        self.assertNotIn(VLLM_KEY, stdin_blob)
        self.assertNotIn(OLD_TOKEN, stdin_blob)

        self.assertEqual(len(self.lines_with(
            "kubectl apply --server-side --field-manager=install-spark-k8s"
            " -f -")), 2)
        self.assertEqual(len(self.lines_with("kubectl apply -k")), 1)
        self.assertTrue(self.lines_with(
            "kubectl -n spark-llm rollout status deploy/spark-switch "
            "--timeout=180s"))
        health = self.lines_with("curl ")
        self.assertTrue(any("127.0.0.1:8010/health" in c for c in health))
        self.assertEqual(self.lines_with("docker "), [])

        # the staging dir (and the secret env files inside it) were removed
        self.assertEqual(os.listdir(self.tmpdir), [])

    def test_apply_keeps_existing_secrets(self):
        proc = self.run_script("--apply", STUB_SECRETS="vllm-api-key "
                                                     "spark-switch-token")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("already exists; keeping it", proc.stdout)
        self.assertEqual(self.lines_with("kubectl create secret"), [])
        self.assertFalse(os.path.exists(self.stdin_file))

    def test_apply_refuses_when_a_port_is_taken(self):
        # neither Service exists yet, port 8000 held: plain --apply must stop
        proc = self.run_script("--apply", STUB_LISTEN_PORTS="8000")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("port 8000 is already listening", proc.stderr)
        self.assertEqual(self.lines_with("kubectl apply"), [])
        self.assertEqual(self.lines_with("docker "), [])

    def test_port_check_is_per_service_an_existing_service_excuses_its_port(self):
        # F14: the vllm-coder Service exists, so port 8000 being held (by that
        # very Service via ServiceLB) is fine; only the port whose Service is
        # MISSING (8010/spark-switch) is still checked
        proc = self.run_script("--apply", STUB_SERVICES="vllm-coder",
                               STUB_LISTEN_PORTS="8000")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        # both Services were looked up individually
        self.assertTrue(self.lines_with("kubectl -n spark-llm get service "
                                        "vllm-coder"))
        self.assertTrue(self.lines_with("kubectl -n spark-llm get service "
                                        "spark-switch"))
        self.assertEqual(len(self.lines_with("kubectl apply -k")), 1)

        # ...but a busy port for a MISSING Service still fails
        proc = self.run_script("--apply", STUB_SERVICES="vllm-coder",
                               STUB_LISTEN_PORTS="8000 8010")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("port 8010 is already listening", proc.stderr)
        self.assertEqual(self.lines_with("kubectl apply"), [])

    # -- preflight ------------------------------------------------------------

    def test_preflight_gpu_missing_fails_before_any_change(self):
        proc = self.run_script("--apply", STUB_GPU=0)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("nvidia.com/gpu", proc.stderr)
        self.assertIn("nothing was changed", proc.stderr)
        self.assertEqual(self.lines_with("kubectl apply"), [])
        self.assertEqual(self.lines_with("kubectl create secret"), [])
        self.assertEqual(self.lines_with("docker "), [])

    def test_preflight_missing_image_fails_with_hint(self):
        proc = self.run_script("--apply", STUB_CTR_IMAGES="")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("not found in containerd", proc.stderr)
        self.assertIn("--import-image", proc.stderr)
        self.assertEqual(self.lines_with("kubectl apply"), [])

    def test_preflight_rejects_bad_secret_values_before_any_change(self):
        # F9: the VALUES are validated (same parser as spark_switch), before
        # any state change — a --migrate-from-docker with an empty
        # VLLM_API_KEY must not even stop the Docker containers
        with open(self.vllm_env, "w", encoding="utf-8") as f:
            f.write("VLLM_API_KEY=\n")
        proc = self.run_script("--migrate-from-docker")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("VLLM_API_KEY must be set and non-empty", proc.stderr)
        self.assertIn("nothing was changed", proc.stderr)
        self.assertEqual(self.lines_with("docker stop"), [])
        self.assertEqual(self.lines_with("kubectl apply"), [])
        self.assert_no_secret_leak(proc)

        # a SWITCH_TOKEN shorter than 24 chars is refused the same way, and
        # the (bad) value never shows up in the output
        with open(self.switch_env, "w", encoding="utf-8") as f:
            f.write(f"SWITCH_TOKEN={SHORT_TOKEN}\nBACKEND=docker\n")
        proc = self.run_script("--apply")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("SWITCH_TOKEN must be set and at least 24 characters",
                      proc.stderr)
        self.assertEqual(self.lines_with("kubectl apply"), [])
        self.assertEqual(self.lines_with("docker "), [])
        self.assert_no_secret_leak(proc, SHORT_TOKEN)

    def test_preflight_is_per_action_emergency_actions_skip_gpu_checks(self):
        # F8: rollback/import-image/device-plugin/with-policy must not be
        # blocked by a broken GPU plugin or a missing RuntimeClass
        broken_gpu = {"STUB_GPU": 0, "STUB_RUNTIMECLASS_RC": 1}

        proc = self.run_script("--rollback-to-docker", **broken_gpu)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertTrue(self.lines_with("docker start"))

        proc = self.run_script("--import-image", **broken_gpu)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("already present in containerd", proc.stdout)

        proc = self.run_script("--dry-run", "--device-plugin", **broken_gpu)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        proc = self.run_script("--dry-run", "--with-policy", **broken_gpu)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        # while the apply path still demands a healthy GPU
        proc = self.run_script("--apply", **broken_gpu)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("nvidia.com/gpu", proc.stderr)

    # -- migration / rollback ---------------------------------------------------

    def test_migrate_stops_docker_containers_before_applying(self):
        proc = self.run_script("--migrate-from-docker")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        stops = self.lines_with("docker stop")
        self.assertEqual(len(stops), 1)
        self.assertIn("spark-switch", stops[0])
        self.assertIn("vllm-coder", stops[0])
        # stop precedes every kubectl mutation...
        stop_idx = self.calls().index(stops[0])
        for line in self.calls()[stop_idx:]:
            if "kubectl apply" in line:
                break
        else:
            self.fail("no kubectl apply after docker stop")
        # ...and nothing was removed
        self.assertEqual(self.lines_with("docker rm"), [])
        self.assertEqual(self.lines_with("docker start"), [])

    def test_rollback_scales_down_deletes_services_then_starts_docker(self):
        proc = self.run_script("--rollback-to-docker")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        calls = self.calls()
        scale_idx = next(i for i, c in enumerate(calls)
                         if "scale deploy --all --replicas=0" in c)
        delete_idx = next(i for i, c in enumerate(calls)
                          if "delete service" in c)
        wait_idx = next(i for i, c in enumerate(calls)
                        if "wait --for=delete pod" in c)
        start_idx = next(i for i, c in enumerate(calls)
                         if "docker start" in c)
        self.assertLess(scale_idx, delete_idx)
        self.assertLess(delete_idx, wait_idx)
        self.assertLess(wait_idx, start_idx)
        # F6: the wait targets exactly the spark-llm workload pods
        wait_call = calls[wait_idx]
        self.assertIn("-l app in (vllm-coder,spark-switch)", wait_call)
        self.assertIn("--timeout=300s", wait_call)
        self.assertIn("--ignore-not-found", calls[delete_idx])
        starts = self.lines_with("docker start")
        self.assertIn("vllm-coder", starts[0])
        self.assertIn("spark-switch", starts[0])
        self.assertEqual(self.lines_with("kubectl create secret"), [])

    def test_rollback_waits_for_pods_before_starting_docker(self):
        # F6: kubectl wait fails AND pods are still listed -> refuse to start
        # Docker (the GPU may still be held by the terminating vLLM pod)
        proc = self.run_script("--rollback-to-docker", STUB_WAIT_RC=1,
                               STUB_PODS="pod/vllm-coder-668d5f4b7-x2k9p")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("pods still present", proc.stderr)
        self.assertIn("not starting Docker containers", proc.stderr)
        self.assertEqual(self.lines_with("docker start"), [])

    def test_rollback_empty_pod_list_counts_as_gone(self):
        # F6: `kubectl wait` exits non-zero with "no matching resources" when
        # the pod list is empty — the empty list is success, not failure
        proc = self.run_script("--rollback-to-docker", STUB_WAIT_RC=1,
                               STUB_PODS="")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertTrue(self.lines_with("docker start"))

    def test_rollback_pod_query_failure_refuses_to_start_docker(self):
        # G6: `kubectl wait` fails AND the confirming `kubectl get pods`
        # exits non-zero with empty stdout (API error). That must NOT be
        # read as "pods gone" — the GPU may still be held by a terminating
        # pod, so docker start is refused and the script exits 1.
        proc = self.run_script("--rollback-to-docker", STUB_WAIT_RC=1,
                               STUB_GET_PODS_RC=1)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("pods still present", proc.stderr)
        self.assertIn("not starting Docker containers", proc.stderr)
        self.assertEqual(self.lines_with("docker start"), [])

    def test_migrate_without_docker_fails_in_preflight(self):
        # G7: --migrate-from-docker needs the docker binary (it stops the
        # containers); a missing one must fail in preflight, BEFORE any
        # kubectl apply, docker stop or file change.
        os.remove(os.path.join(self.stubdir, "docker"))
        before = os.stat(self.switch_env).st_mtime_ns
        proc = self.run_script("--migrate-from-docker")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("docker is required by this action", proc.stderr)
        self.assertIn("nothing was changed", proc.stderr)
        self.assertEqual(self.lines_with("docker stop"), [])
        self.assertEqual(self.lines_with("kubectl apply"), [])
        self.assertEqual(self.lines_with("kubectl create secret"), [])
        self.assertEqual(self.lines_with("kubectl rollout"), [])
        # the env files were not touched either
        self.assertEqual(os.stat(self.switch_env).st_mtime_ns, before)
        self.assertEqual(read_token(self.switch_env), OLD_TOKEN)
        self.assert_no_secret_leak(proc)

    def test_rollback_survives_failing_scale_and_delete(self):
        # F12: a scale-down or service deletion failure is a WARNING; the pod
        # wait still gates docker start and the rollback completes
        proc = self.run_script("--rollback-to-docker", STUB_SCALE_RC=1,
                               STUB_DELETE_RC=1)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("WARNING: scale to 0 failed", proc.stdout)
        self.assertIn("WARNING: deleting the spark-llm services failed",
                      proc.stdout)
        # the hard gate still ran before docker start
        calls = self.calls()
        wait_idx = next(i for i, c in enumerate(calls)
                        if "wait --for=delete pod" in c)
        start_idx = next(i for i, c in enumerate(calls)
                         if "docker start" in c)
        self.assertLess(wait_idx, start_idx)

    def test_rollback_waits_for_ports_and_refuses_if_busy(self):
        proc = self.run_script("--rollback-to-docker", STUB_LISTEN_PORTS="8010")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("still busy", proc.stderr)
        self.assertEqual(self.lines_with("docker start"), [])

    # -- --rotate-token -----------------------------------------------------------

    def test_rotate_token_regenerates_secret_and_restarts(self):
        proc = self.run_script("--rotate-token")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        new_token = read_token(self.switch_env)
        self.assertIsNotNone(new_token)
        self.assertNotEqual(new_token, OLD_TOKEN)
        self.assertGreaterEqual(len(new_token), 24)
        self.assertRegex(new_token, r"^[A-Za-z0-9_-]+$")  # urlsafe charset
        mode = stat.S_IMODE(os.stat(self.switch_env).st_mode)
        self.assertEqual(mode, 0o600)
        self.assert_no_secret_leak(proc, new_token)

        self.assertTrue(self.lines_with(
            "kubectl -n spark-llm rollout restart deploy/spark-switch"))
        creates = self.lines_with("create secret generic")
        self.assertEqual(len(creates), 1)
        self.assertIn("spark-switch-token", creates[0])
        self.assertIn("--from-env-file=", creates[0])

    def test_dry_run_rotate_token_changes_nothing(self):
        # F5: --dry-run --rotate-token must print what would happen and leave
        # the CURRENT token in place (the Mac side still authenticates with
        # it); no secret is created, no rollout restarted
        with open(self.switch_env, "rb") as f:
            before = f.read()
        before_mtime = os.stat(self.switch_env).st_mtime_ns

        proc = self.run_script("--dry-run", "--rotate-token")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assert_no_secret_leak(proc)

        # the file is byte-for-byte unchanged (and was not even rewritten)
        with open(self.switch_env, "rb") as f:
            self.assertEqual(f.read(), before)
        self.assertEqual(os.stat(self.switch_env).st_mtime_ns, before_mtime)
        mode = stat.S_IMODE(os.stat(self.switch_env).st_mode)
        self.assertEqual(mode, 0o600)
        self.assertEqual(read_token(self.switch_env), OLD_TOKEN)

        # what WOULD happen was printed...
        self.assertIn("python3 rewrite SWITCH_TOKEN", proc.stdout)
        self.assertIn("rollout restart deploy/spark-switch", proc.stdout)
        self.assertIn("left unchanged", proc.stdout)
        # ...but nothing executed
        self.assertEqual(self.lines_with("kubectl create secret"), [])
        self.assertEqual(self.lines_with("kubectl rollout"), [])
        self.assertEqual(self.lines_with("kubectl apply"), [])
        self.assertFalse(os.path.exists(self.stdin_file))

    # -- VLLM_IMAGE staging ---------------------------------------------------

    def test_vllm_image_override_sets_newname_and_newtag(self):
        # F13: an override pointing at another registry (with a port!) must
        # rewrite newName AND newTag — without newName the base nvcr.io image
        # would silently deploy
        proc = self.run_script(
            VLLM_IMAGE="registry.example:5000/team/vllm:1.2",
            STUB_CTR_IMAGES="registry.example:5000/team/vllm:1.2",
            STUB_CAPTURE_DIR=self.capture_dir)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        staged = os.path.join(self.capture_dir, "overlay", "kustomization.yaml")
        with open(staged, encoding="utf-8") as f:
            text = f.read()
        self.assertIn("newName: registry.example:5000/team/vllm", text)
        self.assertIn("newTag: 1.2", text)
        self.assertNotIn("newTag: 26.02-py3", text)
        self.assertIn("- name: nvcr.io/nvidia/vllm", text)  # match key intact

    def test_vllm_image_rejects_digest_and_slashed_tag(self):
        # F13: a digest ref cannot be split into newName/newTag; a "/" in the
        # tag means the value was not name:tag at all
        proc = self.run_script(
            VLLM_IMAGE="nvcr.io/nvidia/vllm@sha256:0123abcd")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("digest ref", proc.stderr)

        proc = self.run_script(VLLM_IMAGE="nvcr.io/nvidia/vllm:26.02/py3")
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("VLLM_IMAGE must be name:tag", proc.stderr)

    # -- OFFLINE=1 staging ------------------------------------------------------

    def test_offline_env_adds_patch_to_staged_overlay_only(self):
        # OFFLINE=1 adds the offline-env-patch reference to the STAGED
        # kustomization.yaml only; the repo copy stays byte-identical
        repo_overlay = os.path.join(PARENT, "k8s", "overlays", "spark",
                                    "kustomization.yaml")
        with open(repo_overlay, "rb") as f:
            repo_before = f.read()
        self.assertNotIn(b"offline-env-patch.yaml", repo_before)

        proc = self.run_script(OFFLINE="1",
                               STUB_CAPTURE_DIR=self.capture_dir)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

        staged = os.path.join(self.capture_dir, "overlay",
                              "kustomization.yaml")
        with open(staged, encoding="utf-8") as f:
            text = f.read()
        self.assertIn("path: offline-env-patch.yaml", text)
        self.assertIn("kind: Deployment", text)
        self.assertIn("name: vllm-coder", text)
        # the patch file itself was staged next to the kustomization
        self.assertTrue(os.path.isfile(os.path.join(
            self.capture_dir, "overlay", "offline-env-patch.yaml")))

        # the repo overlay is untouched, byte for byte
        with open(repo_overlay, "rb") as f:
            self.assertEqual(f.read(), repo_before)

    def test_offline_unset_stages_no_patch(self):
        # without OFFLINE=1 the staged overlay has no offline patch — the
        # default (online) install must be identical to before this feature
        proc = self.run_script(STUB_CAPTURE_DIR=self.capture_dir)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        staged = os.path.join(self.capture_dir, "overlay",
                              "kustomization.yaml")
        with open(staged, encoding="utf-8") as f:
            text = f.read()
        self.assertNotIn("offline-env-patch.yaml", text)

        # and OFFLINE=0 behaves exactly like unset
        proc = self.run_script(OFFLINE="0",
                               STUB_CAPTURE_DIR=self.capture_dir)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        with open(staged, encoding="utf-8") as f:
            self.assertNotIn("offline-env-patch.yaml", f.read())


if __name__ == "__main__":
    unittest.main()
