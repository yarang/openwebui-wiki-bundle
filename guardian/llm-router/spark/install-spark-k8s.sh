#!/usr/bin/env bash
# install-spark-k8s.sh — install spark-switch + vLLM on the single-node k3s
# of a DGX Spark (design: docs/internal/SPARK-K8S-DESIGN.md §5, §7).
#
# Run ON the Spark as the normal user:
#   ./install-spark-k8s.sh                 # dry-run of --apply (changes nothing)
#   ./install-spark-k8s.sh --apply         # secrets + manifests + wait for /health
#   ./install-spark-k8s.sh --dry-run --apply   # print what --apply would run
#   ./install-spark-k8s.sh --device-plugin # RuntimeClass + NVIDIA device plugin
#   ./install-spark-k8s.sh --import-image  # docker save | sudo k3s ctr import
#   ./install-spark-k8s.sh --migrate-from-docker  # docker stop (NOT rm) + --apply
#   ./install-spark-k8s.sh --rollback-to-docker   # scale to 0 + docker start
#   ./install-spark-k8s.sh --rotate-token  # new SWITCH_TOKEN (update the Mac too)
#   ./install-spark-k8s.sh --with-policy   # optional ValidatingAdmissionPolicy
#
# Secrets never appear in argv, stdout or shell variables: values move only
# through 0600 files inside a private staging directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="spark-llm"

KUBECTL="${KUBECTL:-kubectl}"
VLLM_IMAGE="${VLLM_IMAGE:-nvcr.io/nvidia/vllm:26.02-py3}"
VLLM_KEY_FILE="${VLLM_KEY_FILE:-$HOME/vllm-work/.vllm-env}"
SWITCH_ENV_FILE="${SWITCH_ENV_FILE:-$HOME/spark-switch/env}"
HF_CACHE_DIR="${HF_CACHE_DIR:-$HOME/.cache/huggingface}"

DRY_RUN=0
ACTION="dryrun"   # dryrun|apply|import-image|device-plugin|with-policy|migrate|rollback|rotate

usage() {
  cat <<'EOF'
Usage: install-spark-k8s.sh [--dry-run] [--apply] [--import-image]
                            [--device-plugin] [--with-policy]
                            [--migrate-from-docker] [--rollback-to-docker]
                            [--rotate-token] [-h|--help]

  (no action flag)  dry-run of --apply: preflight + server-side dry-run apply
  --apply               create secrets (only if missing) and apply manifests
  --import-image        import the vLLM image from Docker into containerd
  --device-plugin       apply RuntimeClass nvidia + the NVIDIA device plugin
  --with-policy         apply the optional ValidatingAdmissionPolicy (stage B)
  --migrate-from-docker docker stop spark-switch vllm-coder (never rm), then --apply
  --rollback-to-docker  scale spark-llm to 0, wait for its pods to terminate,
                        delete the Services, then docker start
  --rotate-token        generate a new SWITCH_TOKEN and update the Secret
  --dry-run             with an action: print state-changing commands only
  -h, --help            this help

Environment overrides: KUBECTL, VLLM_IMAGE, VLLM_KEY_FILE, SWITCH_ENV_FILE,
HF_CACHE_DIR, OFFLINE. The namespace is fixed: spark-llm.

OFFLINE=1  air-gapped install (bundle from pack-spark-offline.sh, loaded by
           install-spark-offline.sh): adds offline-env-patch.yaml
           (HF_HUB_OFFLINE / TRANSFORMERS_OFFLINE / TIKTOKEN_ENCODINGS_BASE)
           to the STAGED overlay kustomization only. The repository copy is
           never modified; OFFLINE unset or 0 stages the plain overlay.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --apply) ACTION="apply" ;;
    --import-image) ACTION="import-image" ;;
    --device-plugin) ACTION="device-plugin" ;;
    --with-policy) ACTION="with-policy" ;;
    --migrate-from-docker) ACTION="migrate" ;;
    --rollback-to-docker) ACTION="rollback" ;;
    --rotate-token) ACTION="rotate" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# No action flag = dry-run of --apply.
if [[ "$ACTION" == "dryrun" ]]; then
  DRY_RUN=1
fi

run() {
  echo "+ $*"
  if [[ $DRY_RUN -eq 0 ]]; then
    "$@"
  fi
}

# Read-only commands (kubectl kustomize, kubectl get, kubectl apply
# --dry-run=server|client) that CANNOT change cluster state. Unlike run(),
# run_ro ALWAYS executes — including in dry-run mode — so the dry-run
# action actually validates the manifests instead of printing commands.
# A failure aborts the script (set -e), which is the point.
run_ro() {
  echo "+ $*"
  "$@"
}

note() { echo "[install-k8s] $*"; }

# ---------------------------------------------------------------- staging ----
# kustomize refuses files outside the kustomization root, so the app files
# (which live next to this script) are copied into a staged copy of k8s/.
# The repository copies are never modified: the PV hostPath placeholder and
# the image tag are rewritten in the staged files only (python3, not sed -i:
# BSD and GNU sed -i are incompatible).
STAGE="$(mktemp -d)"
chmod 700 "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

for f in spark_switch.py spark_common.py spark_backend_docker.py \
         spark_backend_kube.py profiles.json; do
  [[ -f "$SCRIPT_DIR/$f" ]] || { echo "$f not found next to this script" >&2; exit 1; }
done
[[ -d "$SCRIPT_DIR/k8s" ]] || { echo "k8s/ not found next to this script" >&2; exit 1; }

cp -R "$SCRIPT_DIR/k8s" "$STAGE/k8s"
mkdir -p "$STAGE/k8s/base/app"
for f in spark_switch.py spark_common.py spark_backend_docker.py \
         spark_backend_kube.py profiles.json; do
  cp "$SCRIPT_DIR/$f" "$STAGE/k8s/base/app/$f"
done

python3 - "$STAGE/k8s/overlays/spark/hf-cache-pv-patch.yaml" \
          "$STAGE/k8s/overlays/spark/kustomization.yaml" \
          "$HF_CACHE_DIR" "$VLLM_IMAGE" "${OFFLINE:-0}" <<'PYEOF'
import sys

patch_path, kustom_path, hf_cache, image, offline = sys.argv[1:6]
placeholder = "/home/YOUR_USER/.cache/huggingface"
with open(patch_path, encoding="utf-8") as f:
    text = f.read()
if placeholder not in text:
    sys.exit("staged hf-cache-pv-patch.yaml lost its placeholder path")
with open(patch_path, "w", encoding="utf-8") as f:
    f.write(text.replace(placeholder, hf_cache))

if "@" in image:
    sys.exit(f"VLLM_IMAGE must be name:tag, not a digest ref — got {image!r}")
name, _, tag = image.rpartition(":")
if not name or not tag or "/" in tag:
    sys.exit(f"VLLM_IMAGE must be name:tag — got {image!r}")
# Rewrite the WHOLE images entry: newName (the registry/repository part)
# as well as newTag — `name:` stays the match key equal to the base
# manifests' image. Without newName, an override pointing at another
# registry/repository silently deployed the nvcr.io image.
with open(kustom_path, encoding="utf-8") as f:
    text = f.read()
old = ("- name: nvcr.io/nvidia/vllm\n"
       "    newTag: 26.02-py3")
new = (f"- name: nvcr.io/nvidia/vllm\n"
       f"    newName: {name}\n"
       f"    newTag: {tag}")
if old not in text:
    sys.exit("staged overlay lost its images entry")
text = text.replace(old, new)

# OFFLINE=1 only: append the offline env patch to the STAGED patches list
# (the repo kustomization never references it). With OFFLINE unset/0 the
# staged file stays byte-identical to the online install.
if offline == "1":
    marker = "\nimages:\n"
    entry = ("\n  - path: offline-env-patch.yaml\n"
             "    target:\n"
             "      kind: Deployment\n"
             "      name: vllm-coder")
    if marker not in text:
        sys.exit("staged overlay lost its images section")
    if "offline-env-patch.yaml" in text:
        sys.exit("staged overlay already has the offline patch")
    text = text.replace(marker, entry + marker)
with open(kustom_path, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF

# -------------------------------------------------------------- preflight ----
# All read-only (except tightening an env file's mode to 600). Every failure
# is collected; the script exits before ANY change if one was found.
#
# Prerequisites are PER ACTION: an emergency --rollback-to-docker must not
# be blocked by a broken GPU device plugin, and --import-image must not be
# blocked by the very image it is about to import.
#   rollback       kubectl usable + docker present (what it starts)
#   import-image   docker present + containerd queryable
#   device-plugin  kubectl usable (it creates the RuntimeClass/GPU itself)
#   with-policy    kubectl usable
#   rotate         kubectl usable + switch env file checks
#   migrate        the apply set + docker present (it stops the containers)
#   dryrun/apply   everything below (GPU, RuntimeClass, image, both
#                  secret files, HF cache; ports for apply)
preflight_failures=0

fail() {
  echo "preflight: $*" >&2
  preflight_failures=$((preflight_failures + 1))
}

if ! "$KUBECTL" version >/dev/null 2>&1; then
  fail "$KUBECTL is not usable (is k3s installed and kubeconfig set up?)"
fi

NEED_GPU=0; NEED_IMAGE=0; NEED_SECRETS=0; NEED_HF=0
NEED_DOCKER=0; NEED_CTR_QUERY=0
case "$ACTION" in
  rollback)     NEED_DOCKER=1 ;;
  import-image) NEED_DOCKER=1; NEED_CTR_QUERY=1 ;;
  device-plugin|with-policy) ;;
  rotate)       NEED_SECRETS=1 ;;
  migrate)      NEED_GPU=1; NEED_IMAGE=1; NEED_SECRETS=2; NEED_HF=1
                NEED_DOCKER=1 ;;
  *) NEED_GPU=1; NEED_IMAGE=1; NEED_SECRETS=2; NEED_HF=1 ;;
esac

if [[ $NEED_DOCKER -eq 1 ]] && ! command -v docker >/dev/null 2>&1; then
  fail "docker is required by this action but was not found in PATH"
fi

gpu_allocatable() {
  "$KUBECTL" get nodes \
    -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}' \
    2>/dev/null || true
}

if [[ $NEED_GPU -eq 1 ]]; then
  gpu="$(gpu_allocatable)"
  if [[ "$gpu" != "1" ]]; then
    fail "node allocatable nvidia.com/gpu is '${gpu:-<empty>}' (expected 1); \
try --device-plugin first"
  fi
  if ! "$KUBECTL" get runtimeclass nvidia >/dev/null 2>&1; then
    fail "RuntimeClass nvidia not found; try --device-plugin first"
  fi
fi

if [[ $NEED_IMAGE -eq 1 || $NEED_CTR_QUERY -eq 1 ]]; then
  if ctr_out="$(sudo -n k3s ctr -n k8s.io images ls -q 2>/dev/null)"; then
    if [[ $NEED_IMAGE -eq 1 && "$ctr_out" != *"$VLLM_IMAGE"* ]]; then
      fail "$VLLM_IMAGE not found in containerd; try --import-image first"
    fi
  elif [[ $NEED_CTR_QUERY -eq 1 ]]; then
    fail "cannot query containerd (sudo -n k3s ctr failed); the import cannot run"
  else
    note "WARNING: cannot query containerd (sudo -n failed); skipping the image check"
  fi
fi

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

check_secret_file() {  # path key
  local path="$1" key="$2"
  if [[ ! -f "$path" ]]; then
    fail "$path does not exist"
    return
  fi
  local mode
  mode="$(file_mode "$path")"
  if [[ -n "$mode" && $((8#${mode} & 8#077)) -ne 0 ]]; then
    run chmod 600 "$path"
    note "chmod 600 $path (was mode $mode)"
  fi
  # Presence check only; the value is never printed.
  if ! grep -q "^${key}=" "$path" 2>/dev/null; then
    fail "$path does not contain a ${key}= line"
  fi
}

# Value validation (spark_switch.py would refuse to start on an empty
# VLLM_API_KEY or a SWITCH_TOKEN shorter than 24 chars — catch it BEFORE
# any state change, e.g. before --migrate-from-docker stops Docker). Only
# the file path and the key name are passed around; the value stays inside
# python and the failure message never quotes it.
check_secret_value() {  # path key min_len
  python3 - "$1" "$2" "$3" <<'PYEOF'
import sys

src, key, min_len = sys.argv[1], sys.argv[2], int(sys.argv[3])
value = ""
with open(src, encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
            v = v[1:-1]
        if k == key:
            value = v
            break
sys.exit(0 if len(value) >= min_len else 1)
PYEOF
}

if [[ $NEED_SECRETS -ge 1 ]]; then
  check_secret_file "$SWITCH_ENV_FILE" SWITCH_TOKEN
  if [[ -f "$SWITCH_ENV_FILE" ]] \
      && ! check_secret_value "$SWITCH_ENV_FILE" SWITCH_TOKEN 24; then
    fail "$SWITCH_ENV_FILE: SWITCH_TOKEN must be set and at least 24 characters"
  fi
fi
if [[ $NEED_SECRETS -ge 2 ]]; then
  check_secret_file "$VLLM_KEY_FILE" VLLM_API_KEY
  if [[ -f "$VLLM_KEY_FILE" ]] \
      && ! check_secret_value "$VLLM_KEY_FILE" VLLM_API_KEY 1; then
    fail "$VLLM_KEY_FILE: VLLM_API_KEY must be set and non-empty"
  fi
fi

if [[ $NEED_HF -eq 1 && ! -d "$HF_CACHE_DIR" ]]; then
  fail "HF cache directory not found: $HF_CACHE_DIR"
fi

# Port check: plain --apply only (migration keeps Docker holding the ports
# until it stops the containers). Each Service is checked SEPARATELY, and
# only the port whose Service does not exist must be free (a re-apply is
# fine — ServiceLB rebinds existing Services; a port held by an existing
# k8s Service is not "Docker still running").
if [[ "$ACTION" == "apply" ]]; then
  ss_out="$(ss -ltnH 2>/dev/null || true)"
  for pair in "vllm-coder:8000:Docker vLLM" \
              "spark-switch:8010:Docker controller"; do
    svc="${pair%%:*}"
    rest="${pair#*:}"
    port="${rest%%:*}"
    holder="${rest#*:}"
    if "$KUBECTL" -n "$NS" get service "$svc" >/dev/null 2>&1; then
      continue
    fi
    if [[ "$ss_out" == *":${port}"* ]]; then
      fail "port $port is already listening (${holder} still running? see --migrate-from-docker)"
    fi
  done
fi

if [[ $preflight_failures -gt 0 ]]; then
  echo "preflight found $preflight_failures problem(s); nothing was changed." >&2
  exit 1
fi

# ---------------------------------------------------------------- secrets ----
# Secret values never travel through argv (a literal-value flag would show
# them in the process list). python3 (same env-file parsing as
# spark_switch.parse_env_text) writes ONLY the needed KEY=value line into a
# 0600 file inside the private staging dir; kubectl reads it from there, and
# the file is deleted right after.
write_secret_envfile() {  # src key dest
  python3 - "$1" "$2" "$3" <<'PYEOF'
import os
import sys

src, key, dest = sys.argv[1:4]
value = ""
with open(src, encoding="utf-8") as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
            v = v[1:-1]
        if k == key:
            value = v
            break
if not value:
    sys.exit(f"required key {key} not found in {src}")
fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(f"{key}={value}\n")
PYEOF
}

create_secret() {  # name key src [force]
  local name="$1" key="$2" src="$3" force="${4:-0}"
  if [[ "$force" != "1" ]] \
      && "$KUBECTL" -n "$NS" get secret "$name" >/dev/null 2>&1; then
    note "secret $name already exists; keeping it"
    return 0
  fi
  local envfile="$STAGE/secret-$name.env"
  write_secret_envfile "$src" "$key" "$envfile"
  echo "+ $KUBECTL -n $NS create secret generic $name --from-env-file=<staged 0600 file> --dry-run=client -o yaml | $KUBECTL apply --server-side --field-manager=install-spark-k8s -f -"
  if [[ $DRY_RUN -eq 0 ]]; then
    "$KUBECTL" -n "$NS" create secret generic "$name" \
      --from-env-file="$envfile" --dry-run=client -o yaml \
      | "$KUBECTL" apply --server-side --field-manager=install-spark-k8s -f - \
      >/dev/null
  fi
  rm -f "$envfile"
}

# ------------------------------------------------------------------ apply ----

wait_health() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ poll http://127.0.0.1:8010/health for up to 30 s (skipped in dry-run)"
    return 0
  fi
  local healthy=0 body
  for _ in $(seq 1 30); do
    body="$(curl -fsS "http://127.0.0.1:8010/health" 2>/dev/null || true)"
    if [[ "$body" == *'"ok"'* ]]; then
      healthy=1
      break
    fi
    sleep 1
  done
  if [[ $healthy -eq 1 ]]; then
    note "controller is healthy on http://127.0.0.1:8010/health"
  else
    note "WARNING: controller did not answer /health within 30 s;"
    note "         check: $KUBECTL -n $NS logs deploy/spark-switch"
  fi
}

apply_flow() {
  run "$KUBECTL" apply -f "$STAGE/k8s/base/namespace.yaml" || return 1
  create_secret vllm-api-key VLLM_API_KEY "$VLLM_KEY_FILE" || return 1
  create_secret spark-switch-token SWITCH_TOKEN "$SWITCH_ENV_FILE" || return 1
  # Client-side apply on purpose: it patches only the diff between
  # last-applied and the manifest, so it does NOT revert the container args
  # the controller patched after the last apply.
  run "$KUBECTL" apply -k "$STAGE/k8s/overlays/spark" || return 1
  run "$KUBECTL" -n "$NS" rollout status deploy/spark-switch --timeout=180s \
    || return 1
  wait_health
  note "vLLM itself may need 10+ minutes on a first model load; watch with:"
  echo "  $KUBECTL -n $NS get pods -w"
}

case "$ACTION" in
  dryrun)
    # The validation commands are read-only, so they ALWAYS run (run_ro),
    # even in dry-run: "dry-run complete" must mean the staged manifests
    # were actually built and dry-run applied. A failure exits non-zero.
    run_ro "$KUBECTL" kustomize "$STAGE/k8s/overlays/spark"
    if "$KUBECTL" get namespace "$NS" >/dev/null 2>&1; then
      run_ro "$KUBECTL" apply -k "$STAGE/k8s/overlays/spark" --dry-run=server
    else
      # Server dry-run of namespaced objects fails while the namespace does
      # not exist yet; fall back to a client dry-run for them.
      run_ro "$KUBECTL" apply -f "$STAGE/k8s/base/namespace.yaml" --dry-run=server
      run_ro "$KUBECTL" apply -k "$STAGE/k8s/overlays/spark" --dry-run=client
    fi
    note "dry-run complete; nothing was changed. Apply with: $0 --apply"
    ;;
  apply)
    apply_flow
    note "done."
    ;;
  import-image)
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "+ docker save $VLLM_IMAGE | sudo k3s ctr -n k8s.io images import -"
    else
      ctr_out="$(sudo -n k3s ctr -n k8s.io images ls -q 2>/dev/null || true)"
      if [[ "$ctr_out" == *"$VLLM_IMAGE"* ]]; then
        note "$VLLM_IMAGE already present in containerd; nothing to import"
      else
        echo "+ docker save $VLLM_IMAGE | sudo k3s ctr -n k8s.io images import -"
        docker save "$VLLM_IMAGE" | sudo k3s ctr -n k8s.io images import -
        note "image imported into containerd"
      fi
    fi
    ;;
  device-plugin)
    run "$KUBECTL" apply -f "$STAGE/k8s/device-plugin/runtimeclass-nvidia.yaml"
    run "$KUBECTL" apply -f "$STAGE/k8s/device-plugin/nvidia-device-plugin.yaml"
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "+ poll node allocatable nvidia.com/gpu for up to 120 s (skipped in dry-run)"
    else
      gpu_ok=0
      for _ in $(seq 1 24); do
        gpu="$(gpu_allocatable)"
        if [[ "$gpu" == "1" ]]; then
          gpu_ok=1
          break
        fi
        sleep 5
      done
      if [[ $gpu_ok -eq 1 ]]; then
        note "node reports allocatable nvidia.com/gpu: 1"
      else
        note "WARNING: nvidia.com/gpu did not appear within 120 s;"
        note "         check: $KUBECTL -n kube-system get pods -l name=nvidia-device-plugin"
        exit 1
      fi
    fi
    ;;
  with-policy)
    # Stage B only: verify the installed k3s supports ValidatingAdmissionPolicy
    # (GA in k8s 1.30+) before applying this.
    run "$KUBECTL" apply -f "$STAGE/k8s/policy/vap-spark-switch.yaml"
    note "ValidatingAdmissionPolicy applied (third security layer)."
    ;;
  migrate)
    # Stop only — containers are never removed: rollback is a
    # `docker start` away, and unless-stopped containers stay down
    # across reboots.
    run docker stop spark-switch vllm-coder
    if apply_flow; then
      note "migration applied; Docker containers are stopped (not removed)."
    else
      echo "migration failed; to return to Docker: $0 --rollback-to-docker" >&2
      exit 1
    fi
    ;;
  rollback)
    # Failures of the scale-down / service deletion are only warnings: the
    # goal of rollback is to get Docker back even when the namespace or the
    # Deployments are gone (an --apply that failed early). The hard gate in
    # front of `docker start` is the pod wait below.
    if ! run "$KUBECTL" -n "$NS" scale deploy --all --replicas=0; then
      note "WARNING: scale to 0 failed (namespace or deployments missing?); continuing"
    fi
    if ! run "$KUBECTL" -n "$NS" delete service vllm-coder spark-switch \
        --ignore-not-found; then
      note "WARNING: deleting the spark-llm services failed; continuing"
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "+ $KUBECTL -n $NS wait --for=delete pod -l 'app in (vllm-coder,spark-switch)' --timeout=300s"
      echo "+ poll :8000/:8010 free (up to 60 s), then docker start vllm-coder spark-switch"
      run docker start vllm-coder spark-switch
    else
      # `kubectl scale` returning does NOT mean the pods are gone: the GPU
      # stays held until the vLLM pod terminates, and a listening-port check
      # cannot prove that. Wait for actual deletion (an already-empty pod
      # list counts as success — kubectl wait exits non-zero with "no
      # matching resources found" in that case, so re-check with get).
      pods_gone=0
      if "$KUBECTL" -n "$NS" wait --for=delete pod \
          -l 'app in (vllm-coder,spark-switch)' --timeout=300s; then
        pods_gone=1
      else
        # The wait failing is NOT "pods gone": the get behind it can fail
        # too (API error), and `|| true` would turn that into an empty pod
        # list. Only a get that SUCCEEDED with empty output proves the pods
        # are gone; on a failed get, refuse (the GPU may still be held).
        if remaining="$("$KUBECTL" -n "$NS" get pods \
            -l 'app in (vllm-coder,spark-switch)' -o name 2>/dev/null)"; then
          if [[ -z "${remaining//[[:space:]]/}" ]]; then
            pods_gone=1
          fi
        fi
      fi
      if [[ $pods_gone -ne 1 ]]; then
        echo "ERROR: spark-llm pods still present 300 s after scaling to 0;" >&2
        echo "       not starting Docker containers (the GPU may still be held)." >&2
        echo "       Check: $KUBECTL -n $NS get pods -w" >&2
        exit 1
      fi
      ports_free=0
      for _ in $(seq 1 30); do
        ss_out="$(ss -ltnH 2>/dev/null || true)"
        if [[ "$ss_out" != *":8000"* && "$ss_out" != *":8010"* ]]; then
          ports_free=1
          break
        fi
        sleep 2
      done
      if [[ $ports_free -eq 1 ]]; then
        run docker start vllm-coder spark-switch
        note "rolled back to Docker; spark-llm workloads are scaled to 0."
      else
        echo "ports :8000/:8010 still busy after 60 s; not starting Docker containers." >&2
        exit 1
      fi
    fi
    ;;
  rotate)
    # New token generated and written by one python3 process: the value never
    # appears in argv, stdout or a shell variable. The file mode is kept.
    if [[ $DRY_RUN -eq 1 ]]; then
      # A dry-run must leave the current token in place: the Mac side (and
      # any running client) still authenticates with it.
      echo "+ python3 rewrite SWITCH_TOKEN in $SWITCH_ENV_FILE (mode kept at 600)"
      echo "+ $KUBECTL -n $NS create secret generic spark-switch-token --from-env-file=<staged 0600 file> --dry-run=client -o yaml | $KUBECTL apply --server-side --field-manager=install-spark-k8s -f -"
      echo "+ $KUBECTL -n $NS rollout restart deploy/spark-switch"
      note "dry-run: the SWITCH_TOKEN in $SWITCH_ENV_FILE is left unchanged"
      exit 0
    fi
    python3 - "$SWITCH_ENV_FILE" <<'PYEOF'
import os
import secrets
import sys

path = sys.argv[1]
token = secrets.token_urlsafe(32)
lines = []
found = False
with open(path, encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if line.startswith("SWITCH_TOKEN="):
            line = "SWITCH_TOKEN=" + token
            found = True
        lines.append(line)
if not found:
    sys.exit("SWITCH_TOKEN line not found")
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
    note "generated a new SWITCH_TOKEN in $SWITCH_ENV_FILE (mode kept at 600)"
    create_secret spark-switch-token SWITCH_TOKEN "$SWITCH_ENV_FILE" 1
    run "$KUBECTL" -n "$NS" rollout restart deploy/spark-switch
    note "token rotated. The Mac side must be updated too:"
    note "  copy the new SWITCH_TOKEN value to the Mac's SPARK_SWITCH_TOKEN"
    note "  (read it on the Spark with: sed -n 's/^SWITCH_TOKEN=//p' $SWITCH_ENV_FILE)"
    ;;
esac
