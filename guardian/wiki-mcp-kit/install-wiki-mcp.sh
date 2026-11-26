#!/usr/bin/env bash
# ==============================================================================
# wiki-mcp kit — ONE shared wiki-mcp HTTP server for Claude Code, the VS Code Claude Code
# extension and Open WebUI
#
# Shipped as a self-contained folder (wiki-mcp-kit-<ver>/) built by guardian/pack-wiki-mcp-kit.sh;
# run from inside that folder (its own SHA256SUMS is verified first). Written for bash 3.2.
# Nothing is downloaded and no sudo is used. It needs the wiki layer (wiki-layer/install-wiki.sh,
# i.e. guardian/install-wiki.sh in the merged bundle) already installed: that layer owns the venv,
# the mcpo agent (dev.guardian.wiki-mcpo) and watch (dev.guardian.wiki-watch).
#
# Why: Chroma keeps its HNSW index in memory per process, so only one process may write or search
# the vector store. Today mcpo spawns its own stdio wiki-mcp child for Open WebUI while Claude Code
# users register a SECOND stdio server (INSTALL.md §5). This kit runs one long-lived wiki-mcp HTTP
# server (127.0.0.1:<port>/mcp, Bearer key) as dev.guardian.wiki-mcp and points everyone at it:
#   - mcpo keeps its label, port and key but relays (--server-type streamable-http,
#     WIKI_MCPO_UPSTREAM=http in .env), so Open WebUI's DB tool connection does not change
#   - Claude Code gets a user-scope HTTP entry named `wiki`; the VS Code extension reads the same
#     ~/.claude.json, so it needs nothing extra
#   - dev.guardian.wiki-watch is not touched (it never writes Chroma)
# The runner's stdio `serve` mode refuses to start while the shared HTTP server is up (one writer).
#
# Usage:  ./install-wiki-mcp.sh [options]
#   --dry-run            print what would happen, change nothing
#   --no-start           write everything, load nothing (prints the commands to run by hand)
#   --wiki-home=DIR      wiki home (default ~/llm-wiki, as the wiki layer set it)
#   --port=N             shared HTTP server port (default 8765, or the kit MANIFEST's mcp_port)
#   --no-claude          skip the Claude Code registration and the ~/.claude.json scan
#   --no-wheel           skip the wiki-mcp wheel upgrade check
#   --uninstall          stop the HTTP server, restore the stdio mcpo, drop the Claude entry
#   -h, --help           show this help
# ==============================================================================

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
note() { echo "    $*"; }
run() {
    if [ "${DRY}" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi
}

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=0
DO_START=1
UNINSTALL=0
NO_CLAUDE=0
NO_WHEEL=0
WIKI_HOME="${HOME}/llm-wiki"
PORT=""
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY=1 ;;
        --no-start) DO_START=0 ;;
        --wiki-home=*)
            WIKI_HOME="${arg#--wiki-home=}"
            [ -n "${WIKI_HOME}" ] || die "--wiki-home= needs a directory" ;;
        --port=*)
            PORT="${arg#--port=}"
            [ -n "${PORT}" ] || die "--port= needs a number" ;;
        --no-claude) NO_CLAUDE=1 ;;
        --no-wheel) NO_WHEEL=1 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) sed -n '3,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

# ---- 0. the kit must be exactly what was packed -------------------------------------------
# run() is defined above; from here on every write, launchctl, pip and claude call goes through it
# or through an explicit [ "${DRY}" = 1 ] branch.
(cd "${KIT}" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) \
    || die "SHA256SUMS does not match in ${KIT}: the kit is damaged, re-extract it"
manifest() { sed -n "s/^$1=//p" "${KIT}/MANIFEST.env" | head -1; }
WANT_VER="$(manifest wiki_mcp)"
WHEEL_REL="$(manifest wheel)"
LABEL="$(manifest label)"
[ -n "${WANT_VER}" ] && [ -n "${WHEEL_REL}" ] || die "MANIFEST.env is unreadable in ${KIT}"
[ -n "${LABEL}" ] || LABEL="dev.guardian.wiki-mcp"
PORT="${PORT:-$(manifest mcp_port)}"
PORT="${PORT:-8765}"
case "${PORT}" in ''|*[!0-9]*) die "--port must be a number (got '${PORT}')" ;; esac
if [ "${PORT}" -lt 1024 ] || [ "${PORT}" -gt 65535 ]; then die "--port must be 1024-65535 (got ${PORT})"; fi

AGENTS="${HOME}/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
MCPO_LABEL="dev.guardian.wiki-mcpo"
VENV=""
PY=""

# How many seconds wait_http_401 waits for the shared server. 60 in production; the acceptance
# test shrinks it via WIKI_MCP_KIT_WAIT (1-360) so a failing cutover takes seconds, not a minute.
WAIT_TRIES=60
case "${WIKI_MCP_KIT_WAIT:-}" in
    ''|*[!0-9]*) : ;;
    *)
        if [ "${WIKI_MCP_KIT_WAIT}" -ge 1 ] && [ "${WIKI_MCP_KIT_WAIT}" -le 360 ]; then
            WAIT_TRIES="${WIKI_MCP_KIT_WAIT}"
        fi
        ;;
esac

# A dotted-numeric compare: version_ge A B is true when A >= B (0.10.0 > 0.2.5).
version_ge() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        n = split(a, A, "."); m = split(b, B, ".")
        for (i = 1; i <= n || i <= m; i++) {
            x = (i in A) ? A[i] + 0 : 0; y = (i in B) ? B[i] + 0 : 0
            if (x != y) exit (x < y ? 1 : 0)
        }
    }'
}

# A value out of ${WIKI_HOME}/.env, parsed exactly the way run-wiki-mcp.sh parses it (quotes,
# inline comments, CRLF). load-env.sh never overrides an exported variable, so the key is unset
# inside the subshell first.
env_value() {
    local key="$1"
    (
        unset "${key}" 2>/dev/null || true
        . "${KIT}/load-env.sh"
        load_env "${WIKI_HOME}/.env"
        printf '%s' "${!key:-}"
    )
}

# mcpo's port: WIKI_MCPO_PORT out of .env, or 8766 when it is unset there (the runner's own
# default) — the one place the fallback lives, so check_mcpo and the summary cannot drift apart.
mcpo_port() {
    local p
    p="$(env_value WIKI_MCPO_PORT)"
    echo "${p:-8766}"
}

# ---- 1. preflight -------------------------------------------------------------------------
preflight() {
    [ "$(uname)" = "Darwin" ] || die "macOS only (uname says $(uname))"
    [ -f "${WIKI_HOME}/.env" ] \
        || die "${WIKI_HOME}/.env not found: install the wiki layer first (wiki-layer/install-wiki.sh)"
    VENV="$(env_value WIKI_VENV)"
    [ -n "${VENV}" ] || die "${WIKI_HOME}/.env has no WIKI_VENV"
    [ -x "${VENV}/bin/python" ] || die "${VENV}/bin/python is missing: run the wiki layer installer first"
    [ -x "${VENV}/bin/mcpo" ] || die "${VENV}/bin/mcpo is missing: run the wiki layer installer first"
    PY="${VENV}/bin/python"
    local t
    for t in curl plutil launchctl lsof; do
        command -v "${t}" >/dev/null 2>&1 || die "${t} not found on PATH"
    done
    # A listener on the port that is not our own agent would collide with the server we start.
    if [ -n "$(lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t 2>/dev/null)" ]; then
        launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1 \
            || die "port ${PORT} is already in use (lsof -nP -iTCP:${PORT} -sTCP:LISTEN); pass --port=N"
    fi
}

# ---- 2. wheel -----------------------------------------------------------------------------
install_wheel() {
    if [ "${NO_WHEEL}" = 1 ]; then note "wiki-mcp wheel step skipped (--no-wheel)"; return 0; fi
    log "wiki-mcp ${WANT_VER} from ${WHEEL_REL}"
    [ -f "${KIT}/${WHEEL_REL}" ] || die "${KIT}/${WHEEL_REL} is missing: the kit is incomplete"
    local installed=""
    installed="$("${PY}" -I -c 'from importlib.metadata import version; print(version("wiki-mcp"))' 2>/dev/null || true)"
    if [ -n "${installed}" ] && version_ge "${installed}" "${WANT_VER}"; then
        note "wiki-mcp ${installed} already in the venv — same or newer: kept"
        return 0
    fi
    run "${PY}" -m pip install --no-index --no-deps --upgrade --quiet --disable-pip-version-check \
        "${KIT}/${WHEEL_REL}"
    if [ "${DRY}" = 1 ]; then
        note "[dry-run] import check skipped (nothing was installed from here)"
        return 0
    fi
    # wiki_mcp.server indexes on import; wiki_mcp.auth does not import server, so this probe has
    # no side effects. Empty WIKI_PATH/WIKI_DATA_DIR and EMBEDDING_DISABLED keep it inert anyway.
    local vtmp
    vtmp="$(mktemp -d "${TMPDIR:-/tmp}/wikikit-verify.XXXXXX")"
    if ! WIKI_PATH="${vtmp}" WIKI_DATA_DIR="${vtmp}" EMBEDDING_DISABLED=1 \
        "${PY}" -I -c 'import wiki_mcp.auth, uvicorn' >/dev/null 2>&1; then
        rm -rf "${vtmp:?}"
        die "wiki-mcp ${WANT_VER} in ${VENV} cannot import wiki_mcp.auth / uvicorn"
    fi
    rm -rf "${vtmp:?}"
    note "import check ok (wiki_mcp.auth + uvicorn)"
}

# ---- 3. .env (mode stays 600) --------------------------------------------------------------
backup_env() {
    run cp -p "${WIKI_HOME}/.env" "${WIKI_HOME}/.env.bak-${STAMP}"
    run chmod 600 "${WIKI_HOME}/.env.bak-${STAMP}"
}

# Replace the first KEY= line, or append under the "# wiki-mcp kit" block. The edit goes to a
# temp file (umask 077) and is then catted over .env, keeping the inode and its 600 mode —
# the same trick as upgrade_env in the wiki layer installer. Only ever called with non-secret
# values; WIKI_MCP_API_KEY is handled by hand so its value is never printed.
env_ensure() {
    local key="$1" value="$2" env="${WIKI_HOME}/.env" tmp="${WIKI_HOME}/.env.tmp-${STAMP}"
    if [ "${DRY}" = 1 ]; then
        echo "    [dry-run] .env: set ${key}=${value}"
        return 0
    fi
    if grep -q "^${key}=" "${env}" 2>/dev/null; then
        ( umask 077; sed "s#^${key}=.*#${key}=${value}#" "${env}" > "${tmp}" )
    else
        ( umask 077; {
            cat "${env}"
            [ -n "$(tail -c 1 "${env}" 2>/dev/null)" ] && echo ""
            grep -q "^# wiki-mcp kit" "${env}" 2>/dev/null \
                || echo "# wiki-mcp kit — one shared HTTP server (single Chroma writer)"
            printf '%s=%s\n' "${key}" "${value}"
        } > "${tmp}" )
    fi
    cat "${tmp}" > "${env}"
    rm -f "${tmp}"
}

update_env() {
    backup_env
    env_ensure WIKI_MCP_PORT "${PORT}"
    local cur=""
    cur="$(env_value WIKI_MCP_API_KEY)"
    if [ -n "${cur}" ]; then
        note "WIKI_MCP_API_KEY: kept"
    else
        if [ "${DRY}" = 1 ]; then
            echo "    [dry-run] .env: set WIKI_MCP_API_KEY=<openssl rand -hex 24>"
        else
            env_ensure WIKI_MCP_API_KEY "$(openssl rand -hex 24)"
        fi
        note "WIKI_MCP_API_KEY: generated"
    fi
}

# ---- 4. program files ----------------------------------------------------------------------
populate_home() {
    log "wiki home ${WIKI_HOME}"
    if [ -f "${WIKI_HOME}/run-wiki-mcp.sh" ] && ! cmp -s "${KIT}/run-wiki-mcp.sh" "${WIKI_HOME}/run-wiki-mcp.sh"; then
        run cp -p "${WIKI_HOME}/run-wiki-mcp.sh" "${WIKI_HOME}/run-wiki-mcp.sh.bak-${STAMP}"
        note "existing run-wiki-mcp.sh kept as run-wiki-mcp.sh.bak-${STAMP}"
    fi
    run cp "${KIT}/run-wiki-mcp.sh" "${WIKI_HOME}/run-wiki-mcp.sh"
    run cp "${KIT}/load-env.sh" "${WIKI_HOME}/load-env.sh"
    run chmod 755 "${WIKI_HOME}/run-wiki-mcp.sh"
    run mkdir -p "${WIKI_HOME}/logs" "${WIKI_HOME}/backup"
}

# ---- 5. LaunchAgent ------------------------------------------------------------------------
write_agent() {
    local label="$1" cmd="$2" plist="${AGENTS}/$1.plist"
    [ "${DRY}" = 1 ] && { echo "    [dry-run] write ${plist}"; return 0; }
    mkdir -p "${AGENTS}"
    cat >"${plist}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WIKI_HOME}/run-wiki-mcp.sh</string>
        <string>${cmd}</string>
    </array>
    <key>WorkingDirectory</key><string>${WIKI_HOME}</string>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>${WIKI_HOME}/logs/${cmd}.log</string>
    <key>StandardErrorPath</key><string>${WIKI_HOME}/logs/${cmd}.log</string>
</dict>
</plist>
PLIST
    chmod 600 "${plist}"
    plutil -lint "${plist}" >/dev/null || die "${plist} does not lint"
}

# ---- services ------------------------------------------------------------------------------
stop_agent() {
    run launchctl bootout "${DOMAIN}/$1" 2>/dev/null || true
    [ "${DRY}" = 1 ] && return 0
    # bootout returns before the job is gone; bootstrapping too early fails with an I/O error.
    local _i
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "${DOMAIN}/$1" >/dev/null 2>&1 || return 0
        sleep 1
    done
}

start_agent() {
    run launchctl bootstrap "${DOMAIN}" "${AGENTS}/$1.plist"
}

# A POST without a key gets 401 as soon as the server's auth middleware is up. 000 = not up yet.
wait_http_401() {
    local i code
    for i in $(seq 1 "${WAIT_TRIES}"); do
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 -X POST \
            -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
            -d '{}' "http://127.0.0.1:${PORT}/mcp" 2>/dev/null)" || code=000
        [ "${code}" = "401" ] && return 0
        sleep 1
    done
    return 1
}

# ---- 6. cutover: never two Chroma writers ---------------------------------------------------
# mcpo (old: stdio child of its own) goes down FIRST, then the HTTP server comes up, then .env is
# flipped, and only then mcpo is started again — now as a relay. At no point do two wiki-mcp
# processes hold the vector store. When the 401 check fails, rollback_cutover puts everything
# back the way it was: .env is still stdio at that point, so the HTTP server must go down FIRST
# (otherwise the restarted stdio mcpo would be a second writer), then mcpo comes back up.
rollback_cutover() {
    stop_agent "${LABEL}"
    if [ -f "${AGENTS}/${MCPO_LABEL}.plist" ]; then
        start_agent "${MCPO_LABEL}"
        ROLLBACK_MSG="mcpo was restarted in stdio mode"
    else
        ROLLBACK_MSG="mcpo was NOT restarted (${AGENTS}/${MCPO_LABEL}.plist missing) - start it by hand"
    fi
    note "rollback: ${ROLLBACK_MSG}"
}

cutover() {
    log "cutover: mcpo down -> HTTP server up -> mcpo back as a relay"
    if [ "${DO_START}" = 1 ]; then
        stop_agent "${MCPO_LABEL}"
        stop_agent "${LABEL}"
        start_agent "${LABEL}"
        if [ "${DRY}" = 1 ]; then
            echo "    [dry-run] wait until POST http://127.0.0.1:${PORT}/mcp without a key returns 401 (${WAIT_TRIES}s)"
        else
            wait_http_401 || {
                rollback_cutover
                die "the shared HTTP server did not answer on 127.0.0.1:${PORT} within ${WAIT_TRIES}s; rolled back: the HTTP server was stopped and ${ROLLBACK_MSG}; see ${WIKI_HOME}/logs/http.log"
            }
            note "wiki-mcp HTTP server up on 127.0.0.1:${PORT} (401 without a key)"
        fi
    else
        note "not started (--no-start); run these by hand, in this order:"
        note "  launchctl bootout ${DOMAIN}/${MCPO_LABEL}"
        note "  launchctl bootout ${DOMAIN}/${LABEL}"
        note "  launchctl bootstrap ${DOMAIN} ${AGENTS}/${LABEL}.plist"
        note "  launchctl bootstrap ${DOMAIN} ${AGENTS}/${MCPO_LABEL}.plist"
    fi
    env_ensure WIKI_MCPO_UPSTREAM http
    if [ ! -f "${AGENTS}/${MCPO_LABEL}.plist" ]; then
        # A real run stops here: bootstrapping a missing plist would fail anyway. A dry run keeps
        # going and still prints the bootstrap line, since the wiki layer normally wrote the plist.
        [ "${DRY}" = 1 ] || die "${AGENTS}/${MCPO_LABEL}.plist missing: run the wiki layer installer first"
        note "warning: ${AGENTS}/${MCPO_LABEL}.plist not found yet (the wiki layer writes it)"
    fi
    if [ "${DO_START}" = 1 ]; then
        start_agent "${MCPO_LABEL}"
    fi
}

# ---- 7. checks ------------------------------------------------------------------------------
check_http() {
    local body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
    local code
    # The key goes in via -H @- from a here-string, so it never shows up in the process list.
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -H @- -d "${body}" "http://127.0.0.1:${PORT}/mcp" \
        <<< "Authorization: Bearer $(env_value WIKI_MCP_API_KEY)" 2>/dev/null)" || code=000
    [ "${code}" = "200" ] \
        || die "initialize with the key returned HTTP ${code} (want 200); see ${WIKI_HOME}/logs/http.log"
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -d "${body}" "http://127.0.0.1:${PORT}/mcp" 2>/dev/null)" || code=000
    [ "${code}" = "401" ] \
        || die "initialize without a key returned HTTP ${code} (want 401); see ${WIKI_HOME}/logs/http.log"
    note "wiki-mcp HTTP answers on 127.0.0.1:${PORT}/mcp and enforces the Bearer key"
}

# Same idea as the wiki layer's check_mcpo: an empty POST to a tool with required arguments is
# 422 when the mcpo key was accepted (auth is checked before the body) and 401/403 when not.
check_mcpo() {
    local i base="http://127.0.0.1:$(mcpo_port)" up="" tool code mcpo_key
    mcpo_key="$(env_value WIKI_MCPO_KEY)"
    [ -n "${mcpo_key}" ] || die "${WIKI_HOME}/.env has no WIKI_MCPO_KEY"
    for i in $(seq 1 60); do
        curl -sf -o /dev/null "${base}/openapi.json" && { up="${i}"; break; }
        sleep 1
    done
    [ -n "${up}" ] || die "mcpo did not answer within 60s; see ${WIKI_HOME}/logs/mcpo.log"
    tool="$(curl -sf "${base}/openapi.json" | "${PY}" -I -c '
import json, sys
d = json.load(sys.stdin)
schemas = d.get("components", {}).get("schemas", {})
for path, ops in sorted(d.get("paths", {}).items()):
    s = ops.get("post", {}).get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema", {})
    s = schemas.get(s.get("$ref", "").rsplit("/", 1)[-1], s)
    if s.get("required"):
        print(path)
        break
')" || die "mcpo openapi.json is unreadable"
    [ -n "${tool}" ] || die "mcpo lists no tool with required arguments; cannot check the key"
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H @- -d '{}' \
        "${base}${tool}" <<< "Authorization: Bearer ${mcpo_key}")" || true
    case "${code}" in
        422)     note "mcpo answers on ${base} (${up}s) and accepts the key (relay to :${PORT})" ;;
        401|403) die "mcpo rejects WIKI_MCPO_KEY (HTTP ${code}); compare ${WIKI_HOME}/.env with the running mcpo" ;;
        *)       die "mcpo key check on ${tool} returned HTTP ${code}; see ${WIKI_HOME}/logs/mcpo.log" ;;
    esac
}

# ---- 8. Claude Code -------------------------------------------------------------------------
find_claude() {
    CLAUDE_BIN=""
    if command -v claude >/dev/null 2>&1; then
        CLAUDE_BIN="$(command -v claude)"
    elif [ -x "${HOME}/.local/bin/claude" ]; then
        CLAUDE_BIN="${HOME}/.local/bin/claude"
    fi
}

claude_code() {
    local json
    json="$(printf '{"type":"http","url":"http://127.0.0.1:%s/mcp","headers":{"Authorization":"Bearer ***"}}' "${PORT}")"
    if [ "${NO_CLAUDE}" = 1 ]; then
        note "Claude Code step skipped (--no-claude); the HTTP entry would be:"
        note "  claude mcp add-json wiki '${json}' -s user"
        return 0
    fi
    if [ -z "${CLAUDE_BIN}" ]; then
        note "claude CLI not found; add the HTTP entry by hand:"
        note "  claude mcp add-json wiki '${json}' -s user"
        scan_claude_json
        return 0
    fi
    log "Claude Code (user scope)"
    if [ "${DRY}" = 1 ]; then
        echo "    [dry-run] ${CLAUDE_BIN} mcp remove wiki -s user (ignore failure)"
        echo "    [dry-run] ${CLAUDE_BIN} mcp add-json wiki '${json}' -s user"
    else
        "${CLAUDE_BIN}" mcp remove wiki -s user >/dev/null 2>&1 || true
        "${CLAUDE_BIN}" mcp add-json wiki "$(printf '{"type":"http","url":"http://127.0.0.1:%s/mcp","headers":{"Authorization":"Bearer %s"}}' "${PORT}" "$(env_value WIKI_MCP_API_KEY)")" -s user
    fi
    note "claude mcp: wiki -> http://127.0.0.1:${PORT}/mcp (user scope, Bearer *** in ~/.claude.json)"
    scan_claude_json
    if [ "${DRY}" = 0 ]; then
        if printf '%s' "$("${CLAUDE_BIN}" mcp get wiki 2>&1 || true)" | grep -q "Connected"; then
            note "claude mcp get wiki: Connected"
        else
            note "warning: claude mcp get wiki did not report Connected — is the HTTP server up? (claude mcp list)"
        fi
    fi
}

# Read-only scan of ~/.claude.json and ./.mcp.json. Prints only names and paths — never headers,
# env or args values — and never deletes anything: old local/project entries shadow the new
# user-scope one (resolution local > project > user), and any stdio wiki-mcp entry is a second
# Chroma writer.
scan_claude_json() {
    "${PY}" -I - <<'PY' || true
import json, os

def stdio(e):
    return isinstance(e, dict) and (e.get("type") in (None, "", "stdio"))

def mentions(e):
    if not isinstance(e, dict):
        return False
    parts = [str(e.get("command") or "")]
    a = e.get("args")
    if isinstance(a, list):
        parts += [str(x) for x in a]
    blob = " ".join(parts)
    return "run-wiki-mcp.sh" in blob or "wiki-mcp" in blob

cfg = {}
try:
    with open(os.path.expanduser("~/.claude.json"), encoding="utf-8") as f:
        loaded = json.load(f)
    if isinstance(loaded, dict):
        cfg = loaded
except FileNotFoundError:
    pass
except Exception as exc:
    print(f"    warning: ~/.claude.json unreadable ({exc})")

for name, e in sorted((cfg.get("mcpServers") or {}).items()):
    if stdio(e) and mentions(e):
        print(f"    warning: user-scope MCP '{name}' runs wiki-mcp over stdio - a second writer")
        print(f"    fix: claude mcp remove {name} -s user")

for path in sorted(cfg.get("projects") or {}):
    p = cfg.get("projects", {}).get(path)
    if not isinstance(p, dict):
        continue
    for name, e in sorted((p.get("mcpServers") or {}).items()):
        if name == "wiki":
            print(f"    warning: local-scope MCP 'wiki' in {path} shadows the user-scope entry")
            print(f"    fix: (cd '{path}' && claude mcp remove wiki -s local)")
        elif stdio(e) and mentions(e):
            print(f"    warning: local-scope MCP '{name}' in {path} runs wiki-mcp over stdio - a second writer")
            print(f"    fix: (cd '{path}' && claude mcp remove {name} -s local)")

try:
    with open(".mcp.json", encoding="utf-8") as f:
        proj = json.load(f)
    if isinstance(proj, dict):
        for name, e in sorted((proj.get("mcpServers") or {}).items()):
            if name == "wiki" or (stdio(e) and mentions(e)):
                print(f"    warning: ./.mcp.json defines '{name}' (project scope wins over user scope)")
                print("    fix: edit ./.mcp.json and remove that entry")
except (FileNotFoundError, NotADirectoryError):
    pass
PY
}

# ---- 9. summary ------------------------------------------------------------------------------
install_summary() {
    log "done$([ "${DRY}" = 1 ] && echo ' (dry run: nothing was changed)')"
    note "endpoints:"
    note "  wiki-mcp HTTP   http://127.0.0.1:${PORT}/mcp   (Bearer WIKI_MCP_API_KEY)"
    note "  mcpo (Open WebUI)   http://127.0.0.1:$(mcpo_port)   (key unchanged: WIKI_MCPO_KEY)"
    note "keys live in ${WIKI_HOME}/.env (mode 600) and, for Claude Code, in ~/.claude.json"
    note "reminder: an older wiki layer installer (install-wiki.sh) overwrites"
    note "  ${WIKI_HOME}/run-wiki-mcp.sh with a version without 'http' — run this kit again afterwards"
}

# ---- uninstall --------------------------------------------------------------------------------
do_uninstall() {
    log "uninstall: HTTP server off, mcpo back to its own stdio wiki-mcp"
    if [ "${DO_START}" = 1 ]; then
        stop_agent "${MCPO_LABEL}"
        stop_agent "${LABEL}"
    else
        # Like --no-start on install: no launchctl at all, just the commands to run by hand.
        note "not stopping (--no-start); run these by hand, in this order:"
        note "  launchctl bootout ${DOMAIN}/${MCPO_LABEL}"
        note "  launchctl bootout ${DOMAIN}/${LABEL}"
    fi
    if [ -f "${AGENTS}/${LABEL}.plist" ]; then
        run mkdir -p "${WIKI_HOME}/backup"
        run mv "${AGENTS}/${LABEL}.plist" "${WIKI_HOME}/backup/${LABEL}.plist.${STAMP}"
        note "plist kept at ${WIKI_HOME}/backup/${LABEL}.plist.${STAMP}"
    else
        note "${AGENTS}/${LABEL}.plist not present (nothing to move)"
    fi
    # WIKI_MCP_* lines stay in .env (they are inert without the agent); only the upstream flips.
    backup_env
    env_ensure WIKI_MCPO_UPSTREAM stdio
    if [ "${DO_START}" = 1 ]; then
        if [ ! -f "${AGENTS}/${MCPO_LABEL}.plist" ]; then
            [ "${DRY}" = 1 ] || die "${AGENTS}/${MCPO_LABEL}.plist missing: run the wiki layer installer first"
            note "warning: ${AGENTS}/${MCPO_LABEL}.plist not found yet (the wiki layer writes it)"
        fi
        start_agent "${MCPO_LABEL}"
    else
        note "not started (--no-start): launchctl bootstrap ${DOMAIN} ${AGENTS}/${MCPO_LABEL}.plist"
    fi
    if [ "${DRY}" = 0 ] && [ "${DO_START}" = 1 ]; then check_mcpo; fi
    if [ "${NO_CLAUDE}" != 1 ] && [ -n "${CLAUDE_BIN}" ]; then
        if [ "${DRY}" = 1 ]; then
            echo "    [dry-run] ${CLAUDE_BIN} mcp remove wiki -s user (ignore failure)"
        else
            "${CLAUDE_BIN}" mcp remove wiki -s user >/dev/null 2>&1 || true
        fi
    fi
    log "done$([ "${DRY}" = 1 ] && echo ' (dry run: nothing was changed)')"
    note "Claude Code has no 'wiki' entry now. To go back to a private stdio server (INSTALL.md §5):"
    note "  claude mcp add wiki -s user -- ${WIKI_HOME}/run-wiki-mcp.sh serve"
    note "WIKI_MCP_* lines were left in ${WIKI_HOME}/.env; the shared-server kit reuses the key"
}

# ---- main --------------------------------------------------------------------------------------
preflight
find_claude
if [ "${UNINSTALL}" = 1 ]; then
    do_uninstall
    exit 0
fi
install_wheel
update_env
populate_home
log "LaunchAgent ${LABEL}"
write_agent "${LABEL}" http
cutover
if [ "${DRY}" = 0 ] && [ "${DO_START}" = 1 ]; then
    check_http
    check_mcpo
fi
claude_code
install_summary
