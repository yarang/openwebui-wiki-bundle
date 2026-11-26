#!/usr/bin/env bash
# install-spark-switch.sh — install the spark-switch controller on a DGX Spark.
#
# Run ON the Spark as the normal user (member of the docker group):
#   ./install-spark-switch.sh --dry-run   # show what would happen
#   ./install-spark-switch.sh             # copy files, create env
#   ./install-spark-switch.sh --start     # also (re)start the controller container
#
# This script never stops, removes or restarts the vllm-coder container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/spark-switch"
VLLM_KEY_FILE="${VLLM_KEY_FILE:-$HOME/vllm-work/.vllm-env}"
VLLM_IMAGE="${VLLM_IMAGE:-nvcr.io/nvidia/vllm:26.02-py3}"
SWITCH_PORT="${SWITCH_PORT:-8010}"
DRY_RUN=0
do_start=0

usage() {
  cat <<'EOF'
Usage: install-spark-switch.sh [--dry-run] [--start] [-h|--help]

  --dry-run  print every command/write, change nothing
  --start    also (re)start the spark-switch controller container
  -h, --help show this help

Environment overrides: SWITCH_PORT, VLLM_IMAGE, VLLM_KEY_FILE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --start) do_start=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

run() {
  echo "+ $*"
  if [[ $DRY_RUN -eq 0 ]]; then
    "$@"
  fi
}

note() { echo "[install] $*"; }

[[ -f "$SCRIPT_DIR/spark_switch.py" ]] || { echo "spark_switch.py not found next to this script" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/spark_common.py" ]] || { echo "spark_common.py not found next to this script" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/spark_backend_docker.py" ]] || { echo "spark_backend_docker.py not found next to this script" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/spark_backend_kube.py" ]] || { echo "spark_backend_kube.py not found next to this script" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/profiles.json" ]]  || { echo "profiles.json not found next to this script" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/env.example" ]]    || { echo "env.example not found next to this script" >&2; exit 1; }

# --- docker reachable? (capture output first, then test it) -----------------
docker_info_out="$(docker info 2>&1)" || {
  echo "docker is not usable for this user:" >&2
  echo "$docker_info_out" >&2
  echo "Is \$USER in the docker group? Try: getent group docker" >&2
  exit 1
}

# --- app dir ----------------------------------------------------------------
run mkdir -p "$APP_DIR"
run chmod 700 "$APP_DIR"

run cp "$SCRIPT_DIR/spark_switch.py" "$APP_DIR/spark_switch.py"
run cp "$SCRIPT_DIR/spark_common.py" "$APP_DIR/spark_common.py"
run cp "$SCRIPT_DIR/spark_backend_docker.py" "$APP_DIR/spark_backend_docker.py"
run cp "$SCRIPT_DIR/spark_backend_kube.py" "$APP_DIR/spark_backend_kube.py"

if [[ ! -f "$APP_DIR/profiles.json" ]]; then
  run cp "$SCRIPT_DIR/profiles.json" "$APP_DIR/profiles.json"
else
  if cmp -s "$SCRIPT_DIR/profiles.json" "$APP_DIR/profiles.json"; then
    note "profiles.json unchanged"
  else
    run cp "$SCRIPT_DIR/profiles.json" "$APP_DIR/profiles.json.new"
    note "profiles.json differs from the shipped one;"
    note "  new version written to $APP_DIR/profiles.json.new (edit it by hand;"
    note "  you may have customized your copy)."
  fi
fi

# --- env file (token generated here, never echoed) ---------------------------
if [[ ! -f "$APP_DIR/env" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    note "would create $APP_DIR/env from env.example"
    note "  SWITCH_TOKEN=<freshly generated, not shown in dry-run>"
    note "  HF_CACHE_HOST=$HOME/.cache/huggingface"
  else
    # One python3 process generates the token AND writes the file: the token
    # never appears in any argv (a sed argument is visible in the process
    # list), on stdout, or in a shell variable. O_EXCL refuses a leftover
    # partial file, and the mode is 600 from the first byte on.
    python3 - "$SCRIPT_DIR/env.example" "$APP_DIR/env" \
              "$HOME/.cache/huggingface" <<'PYEOF'
import os
import secrets
import sys

src, dest, hf_cache = sys.argv[1], sys.argv[2], sys.argv[3]
token = secrets.token_urlsafe(32)
lines = []
with open(src, encoding="utf-8") as f:
    for raw in f:
        line = raw.rstrip("\n")
        if line.startswith("SWITCH_TOKEN="):
            line = "SWITCH_TOKEN=" + token
        elif line.startswith("HF_CACHE_HOST="):
            line = "HF_CACHE_HOST=" + hf_cache
        lines.append(line)
fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PYEOF
    note "created $APP_DIR/env (SWITCH_TOKEN generated, mode 600)"
  fi
else
  # An existing env is kept exactly as it is: the token is not rotated.
  run chmod 600 "$APP_DIR/env"
  note "keeping existing $APP_DIR/env"
fi

# --- vllm key file ------------------------------------------------------------
if [[ ! -f "$VLLM_KEY_FILE" ]]; then
  echo "vLLM env file not found: $VLLM_KEY_FILE" >&2
  echo "Create it with one line: VLLM_API_KEY=<your vLLM API key>" >&2
  echo "(or set VLLM_KEY_FILE to its location and re-run)" >&2
  exit 1
fi
# The file belongs to this user and holds the vLLM API key: if group/others
# can read it, tighten it (the content is never printed). GNU stat first
# (the Spark is Linux), BSD stat as a fallback so a Mac can dry-run this too.
vllm_mode="$(stat -c '%a' "$VLLM_KEY_FILE" 2>/dev/null || stat -f '%Lp' "$VLLM_KEY_FILE")"
if [[ $((8#${vllm_mode} & 8#077)) -ne 0 ]]; then
  run chmod 600 "$VLLM_KEY_FILE"
  note "chmod 600 $VLLM_KEY_FILE (it was group/other readable, mode $vllm_mode)"
fi
note "using vLLM env file: $VLLM_KEY_FILE (content never printed)"

if [[ $do_start -eq 0 ]]; then
  note "files installed. To start the controller now, run:"
  echo "  $0 --start"
  exit 0
fi

# --- controller container (only 'spark-switch'; vllm-coder is untouched) ------
if [[ $DRY_RUN -eq 1 ]]; then
  echo "+ docker rm -f spark-switch (ignore 'No such container')"
else
  rm_out="$(docker rm -f spark-switch 2>&1 || true)"
  note "removed old spark-switch container (if any)"
fi

run docker run -d --name spark-switch --restart unless-stopped \
  -p "${SWITCH_PORT}:8010" \
  --add-host host.docker.internal:host-gateway \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$APP_DIR:/app:ro" \
  -v "$VLLM_KEY_FILE:/config/vllm-env:ro" \
  --entrypoint python3 "$VLLM_IMAGE" \
  /app/spark_switch.py --env-file /app/env

if [[ $DRY_RUN -eq 1 ]]; then
  echo "+ waiting for http://127.0.0.1:${SWITCH_PORT}/health (skipped in dry-run)"
else
  healthy=0
  for _ in $(seq 1 30); do
    body="$(curl -fsS "http://127.0.0.1:${SWITCH_PORT}/health" 2>/dev/null || true)"
    if [[ "$body" == *'"ok"'* ]]; then
      healthy=1
      break
    fi
    sleep 1
  done
  if [[ $healthy -eq 1 ]]; then
    note "controller is healthy on http://127.0.0.1:${SWITCH_PORT}/health"
  else
    note "WARNING: controller did not answer /health within 30 s;"
    note "         check: docker logs spark-switch"
  fi
fi

note "done. The vllm-coder container was NOT touched."
echo
echo "The API token lives in ~/spark-switch/env (SWITCH_TOKEN). Do not paste it"
echo "into shells; read it at call time, e.g.:"
echo '  curl -s -H "Authorization: Bearer $(sed -n '\''s/^SWITCH_TOKEN=//p'\'' ~/spark-switch/env)" \'
echo "       http://127.0.0.1:${SWITCH_PORT}/status"
