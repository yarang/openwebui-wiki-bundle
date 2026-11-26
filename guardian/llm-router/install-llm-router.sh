#!/usr/bin/env bash
# ==============================================================================
# llm-router for a guardian LLM bundle - one Anthropic base URL in front of LM Studio and a DGX Spark
#
# Installs the user-level pieces so Claude Code can use both backends through http://127.0.0.1:1240:
#   1. router.py into ~/.guardian-llm/llm-router (copied to .partial, then moved into place)
#   2. ~/.config/llm-router/env, written once from env.example with mode 600 (the Spark API key lives
#      there and nowhere else; an existing file is kept as it is, only tightened to 600 if too open)
#   3. ~/.local/bin/spark-model, the CLI that switches the served Spark model through the router
#      (curl + stdlib json only; it needs no tokens)
#   4. the LaunchAgent dev.guardian.llm-router (RunAtLoad + KeepAlive; the router reads the env file
#      itself, so the plist holds no secrets) plus ~/.guardian-llm/logs for its output
# Nothing is downloaded and no sudo is used. bash 3.2 is enough.
#
# Usage:  install-llm-router.sh [options]
#   --dry-run        print what would happen, change nothing
#   --python=PATH    python that can import fastapi, httpx and uvicorn
#                    (default ~/.guardian-llm/venv/bin/python)
#   --load           bootstrap the LaunchAgent now and wait for /health
#   -h, --help       show this help
# ==============================================================================

set -euo pipefail

LAYER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0
LOAD=0
PY="${HOME}/.guardian-llm/venv/bin/python"

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY=1 ;;
        --load) LOAD=1 ;;
        --python=*) PY="${arg#--python=}" ;;
        -h|--help) sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
note() { echo "    $*"; }
run() {
    if [ "${DRY}" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi
}

PREFIX="${HOME}/.guardian-llm"
DEST="${PREFIX}/llm-router/router.py"
BIN_DIR="${HOME}/.local/bin"
BIN_DEST="${BIN_DIR}/spark-model"
ENV_DIR="${HOME}/.config/llm-router"
ENV_FILE="${ENV_DIR}/env"
AGENTS="${HOME}/Library/LaunchAgents"
LABEL="dev.guardian.llm-router"
PLIST="${AGENTS}/${LABEL}.plist"
LOGS="${PREFIX}/logs"
DOMAIN="gui/$(id -u)"

# ---- 1. python ------------------------------------------------------------------------------
log "checking ${PY}"
if [ ! -x "${PY}" ]; then
    [ "${DRY}" = 1 ] || die "python not found at ${PY}: pass --python=PATH (the guardian venv's python)"
    note "python not there yet (fine for a dry run)"
else
    # Output is captured first: `cmd | grep -q` would eat failures under pipefail.
    out="$("${PY}" -c 'import fastapi, httpx, uvicorn' 2>&1)" \
        || die "${PY} cannot import fastapi/httpx/uvicorn: ${out}"
    note "fastapi, httpx and uvicorn import fine"
fi

# ---- 2. router.py ---------------------------------------------------------------------------
log "installing ${DEST}"
run mkdir -p "${PREFIX}/llm-router"
run cp "${LAYER}/router.py" "${DEST}.partial"
run mv "${DEST}.partial" "${DEST}"

# ---- 3. spark-model CLI ----------------------------------------------------------------------
# Talks to the router only, so there is nothing secret in it and nothing to configure here.
log "installing ${BIN_DEST}"
run mkdir -p "${BIN_DIR}"
run cp "${LAYER}/spark-model" "${BIN_DEST}.partial"
run mv "${BIN_DEST}.partial" "${BIN_DEST}"
run chmod 755 "${BIN_DEST}"

# ---- 4. env file ----------------------------------------------------------------------------
# Written once from env.example. The Spark API key goes in here, so the file must stay mode 600.
log "env file ${ENV_FILE}"
if [ -f "${ENV_FILE}" ]; then
    mode="$(stat -f '%Lp' "${ENV_FILE}")"
    if [ $((8#${mode} & 8#077)) -ne 0 ]; then
        run chmod 600 "${ENV_FILE}"
        note "chmod 600 ${ENV_FILE} (it was group/other readable)"
    else
        note "env file kept (${ENV_FILE}, mode ${mode})"
    fi
elif [ "${DRY}" = 1 ]; then
    echo "    [dry-run] write ${ENV_FILE} (mode 600, from env.example)"
else
    mkdir -p "${ENV_DIR}"
    umask 077
    cp "${LAYER}/env.example" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    note "env file written (mode 600): fill in SPARK_URL and SPARK_API_KEY there, then keep it 600"
fi
# The port the router will actually use, for the health poll below.
PORT="$(sed -n 's/^LLM_ROUTER_PORT=//p' "${ENV_FILE}" 2>/dev/null | head -1 | tr -d '\r"')" || true
case "${PORT}" in ''|*[!0-9]*) PORT=1240 ;; esac

# ---- 5. LaunchAgent -------------------------------------------------------------------------
# No secrets here: ProgramArguments is just the venv python and router.py, which reads the env file
# itself. ThrottleInterval keeps launchd from respinning it during a CrashLoop.
write_plist() {
    [ "${DRY}" = 1 ] && { echo "    [dry-run] write ${PLIST}"; return 0; }
    mkdir -p "${AGENTS}" "${LOGS}"
    cat >"${PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PY}</string>
        <string>${DEST}</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>${LOGS}/llm-router.log</string>
    <key>StandardErrorPath</key><string>${LOGS}/llm-router.log</string>
</dict>
</plist>
PLIST
    chmod 600 "${PLIST}"
    plutil -lint "${PLIST}" >/dev/null || die "plutil rejected ${PLIST}"
}
log "LaunchAgent ${LABEL}"
write_plist

# ---- 6. start -------------------------------------------------------------------------------
# bootout returns before the job is gone; bootstrapping too early fails with an I/O error.
stop_router() {
    run launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
    [ "${DRY}" = 1 ] && return 0
    local _
    for _ in 1 2 3 4 5; do
        launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || return 0
        sleep 1
    done
}

wait_for_health() {
    local i
    for i in $(seq 1 15); do
        if curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
            note "router answers on 127.0.0.1:${PORT} (${i}s); curl that /health to see both backends"
            return 0
        fi
        sleep 1
    done
    die "router did not answer within 15s; see ${LOGS}/llm-router.log"
}

if [ "${LOAD}" = 1 ]; then
    log "starting ${LABEL}"
    stop_router
    run launchctl bootstrap "${DOMAIN}" "${PLIST}"
    if [ "${DRY}" = 1 ]; then
        note "[dry-run] would poll http://127.0.0.1:${PORT}/health for up to 15s"
    else
        wait_for_health
    fi
else
    note "not started: launchctl bootstrap ${DOMAIN} ${PLIST}"
fi
log "done$([ "${DRY}" = 1 ] && echo ' (dry run: nothing was changed)')"
