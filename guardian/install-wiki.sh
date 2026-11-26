#!/usr/bin/env bash
# ==============================================================================
# wiki layer for a guardian LLM bundle — wiki-mcp + mcpo + watch on top of the guardian Open WebUI
#
# Shipped inside the merged bundle as wiki-layer/install-wiki.sh and run by ../install-all.sh after the guardian
# installer (which rewrites the Open WebUI LaunchAgent on every run, so this must come second). Written for bash 3.2.
# Nothing is downloaded and no sudo is used.
#
# What it does:
#   1. wiki-mcp (+ docx/pptx/xlsx readers) into the guardian venv, from the bundled wheels (--no-index), and
#      LM Studio's own nomic model into ~/.lmstudio/.internal/bundled-models when absent (the default embedding,
#      bge-m3, is one of the bundle's models that the guardian installer copies); once LM Studio has been
#      launched, its server is set to start with the app (enableLocalService, autoStartOnLaunch)
#   2. optional --migrate-from: copies (never moves) an old standalone bundle's Open WebUI data, secret key, wiki,
#      wiki-data and raw; points the DB's wiki tool server at the new key and the DB's RAG embedding at LM Studio
#   3. <wiki-home>: program files refreshed, data folders (wiki, wiki-data, raw) created only when absent, .env
#      written once (mode 600, random mcpo key); a kept .env whose WIKI_INGEST_MODEL is one id of the gemma alias
#      pair (google/gemma-4-e4b, gemma-4-e4b-it-mlx) is swapped to the other when only the other is listed
#   4. LaunchAgents dev.guardian.wiki-mcpo (127.0.0.1:<mcpo-port>) and dev.guardian.wiki-watch; the Open WebUI
#      LaunchAgent gets TOOL_SERVER_CONNECTIONS and RAG_EMBEDDING_MODEL so a fresh DB registers the wiki tool server
#      and embeds attachments with the wiki's model
#   5. restarts the three services, checks that mcpo answers and that LM Studio lists the .env models
#
# Usage:  wiki-layer/install-wiki.sh [options]
#   --dry-run            print what would happen, change nothing
#   --no-start           write everything, load nothing
#   --prefix=DIR         guardian tool directory (default ~/.guardian-llm)
#   --wiki-home=DIR      wiki home (default ~/llm-wiki; keep it out of ~/Desktop and ~/Documents, which need
#                        privacy approval for background jobs)
#   --mcpo-port=N        mcpo port (default 8766)
#   --webui-host=H       bind address for Open WebUI (default: keep guardian's 127.0.0.1). 0.0.0.0 opens it to the
#                        LAN — create the admin account first
#   --migrate-from=DIR   old standalone openwebui-wiki bundle to copy data from (it must not be running)
#   --embedding-model=M  LM Studio embedding model for a new .env, the Open WebUI LaunchAgent and a migrated DB
#                        (default text-embedding-bge-m3)
# ==============================================================================

set -euo pipefail

LAYER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$(cd "${LAYER}/.." && pwd)"
DRY=0
DO_START=1
PREFIX="${HOME}/.guardian-llm"
WIKI_HOME="${HOME}/llm-wiki"
MCPO_PORT=8766
WEBUI_HOST=""
MIGRATE_FROM=""
EMBEDDING_MODEL="text-embedding-bge-m3"
# LM Studio's server. WIKI_LMSTUDIO_URL overrides it (tests point it at a stub server); the default is unchanged.
LMSTUDIO_URL="${WIKI_LMSTUDIO_URL:-http://127.0.0.1:1234/v1}"
WEBUI_LABEL="dev.guardian.openwebui"
MCPO_LABEL="dev.guardian.wiki-mcpo"
WATCH_LABEL="dev.guardian.wiki-watch"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY=1 ;;
        --no-start) DO_START=0 ;;
        --prefix=*) PREFIX="${arg#--prefix=}" ;;
        --wiki-home=*) WIKI_HOME="${arg#--wiki-home=}" ;;
        --mcpo-port=*) MCPO_PORT="${arg#--mcpo-port=}" ;;
        --webui-host=*) WEBUI_HOST="${arg#--webui-host=}" ;;
        --migrate-from=*) MIGRATE_FROM="${arg#--migrate-from=}" ;;
        --embedding-model=*) EMBEDDING_MODEL="${arg#--embedding-model=}" ;;
        -h|--help) sed -n '3,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
note() { echo "    $*"; }
run() {
    if [ "${DRY}" = 1 ]; then echo "    [dry-run] $*"; else "$@"; fi
}

PY="${PREFIX}/venv/bin/python"
AGENTS="${HOME}/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
OLD_DATA=""

# ---- checks ------------------------------------------------------------------------------
preflight() {
    if [ ! -x "${PY}" ]; then
        [ "${DRY}" = 1 ] || die "guardian venv not found at ${PREFIX}/venv: run ./install.sh first"
        note "guardian venv not there yet (fine for a dry run before ./install.sh)"
    fi
    [ -d "${LAYER}/wheels" ] || die "wiki-layer/wheels missing: the bundle is incomplete"
    case "${WIKI_HOME}" in
        "${HOME}/Desktop"*|"${HOME}/Documents"*|"${HOME}/Downloads"*)
            die "--wiki-home under Desktop/Documents/Downloads needs macOS privacy approval for LaunchAgents" ;;
    esac
    case "${MCPO_PORT}" in ''|*[!0-9]*) die "--mcpo-port must be a number" ;; esac
    if [ -n "${MIGRATE_FROM}" ]; then
        [ -d "${MIGRATE_FROM}" ] || die "--migrate-from: no such directory: ${MIGRATE_FROM}"
        MIGRATE_FROM="$(cd "${MIGRATE_FROM}" && pwd)"
        if [ -f "${MIGRATE_FROM}/data/webui.db" ]; then
            OLD_DATA="${MIGRATE_FROM}/data"
        else
            OLD_DATA="$(ls -d "${MIGRATE_FROM}"/.venv/lib/python3.*/site-packages/open_webui/data 2>/dev/null | head -1)"
        fi
        [ -n "${OLD_DATA}" ] && [ -f "${OLD_DATA}/webui.db" ] || die "no webui.db under ${MIGRATE_FROM}"
        if pgrep -f "${MIGRATE_FROM}/" >/dev/null 2>&1; then
            die "processes from ${MIGRATE_FROM} are still running; stop them first (pgrep -fl '${MIGRATE_FROM}/')"
        fi
        note "migrating from ${OLD_DATA}"
    fi
}

# ---- 1. packages -------------------------------------------------------------------------
install_packages() {
    log "wiki-mcp $(sed -n 's/^wiki_mcp=//p' "${BUNDLE}/MANIFEST.env" 2>/dev/null) into ${PREFIX}/venv"
    run "${PY}" -m pip install --no-index --find-links "${LAYER}/wheels" --find-links "${BUNDLE}/wheels" \
        --disable-pip-version-check --quiet wiki-mcp python-docx python-pptx openpyxl
    [ "${DRY}" = 1 ] || "${PY}" -m pip check --disable-pip-version-check >/dev/null || die "pip check failed in ${PREFIX}/venv"
}

# LM Studio looks for its embedding model in ~/.lmstudio/.internal/bundled-models (the app's own copy is moved
# there on first launch). An existing copy is left alone.
install_embedding() {
    local src="${LAYER}/bundled-models" target="${HOME}/.lmstudio/.internal/bundled-models" d
    [ -d "${src}" ] || return 0
    for d in "${src}"/*/*; do
        [ -d "${d}" ] || continue
        local unit="${d#${src}/}"
        if [ -e "${target}/${unit}" ]; then
            note "embedding model ${unit} already present"
        else
            run mkdir -p "${target}/$(dirname "${unit}")"
            run ditto "${d}" "${target}/${unit}"
            note "+ embedding model ${unit} (LM Studio picks it up on its next start)"
        fi
    done
}

# LM Studio's server must come up with the app, or the wiki has no embeddings after a reboot. settings.json is
# written on the first launch (which needs someone at the console for Gatekeeper), so nothing is done before it
# exists. Other keys, the port and the bind address are left as they are. A running 0.4.26 app kept the merged
# values when tested and applies them on its next launch. A file it cannot parse is reported, not fatal: the wiki
# works without this, only the server then has to be started by hand.
configure_lmstudio() {
    local settings="${HOME}/.lmstudio/settings.json" server="${HOME}/.lmstudio/.internal/http-server-config.json"
    # settings.json appears on the first launch; http-server-config.json only once the server settings are
    # changed in the app, so on a clean Mac it is created here (LM Studio fills in the other keys).
    if [ ! -f "${settings}" ]; then
        note "LM Studio has not been launched yet: open it once at the console, then rerun this script so its"
        note "server starts with the app (or turn on Developer > Start server on launch yourself)"
        return 0
    fi
    if [ "${DRY}" = 1 ]; then
        note "[dry-run] enableLocalService and autoStartOnLaunch would be set to true, unloadPreviousJITModelOnLoad to false"
        return 0
    fi
    if "${PY}" - "${settings}" "${server}" <<'PYEOF'
import json, os, shutil, sys

# Both files are parsed before either is written, so a malformed one leaves both untouched.
# realpath keeps a symlinked settings file a symlink.
# unloadPreviousJITModelOnLoad (default on) unloads the last JIT-loaded model whenever another one loads. The chat
# model and the embedding model are always used together here (mcpo embeds a note while watch is still asking
# gemma to convert the raw file), so with it on each load cancels the other ("Failed to load model … canceled").
jobs = []
for path, wants in (
    (sys.argv[1], ((("enableLocalService",), True), (("developer", "unloadPreviousJITModelOnLoad"), False))),
    (sys.argv[2], ((("autoStartOnLaunch",), True),)),
):
    path = os.path.realpath(path)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = {"port": 1234}
    jobs.append((path, wants, data))

for path, wants, data in jobs:
    changed = []
    for keys, value in wants:
        parent = data
        for k in keys[:-1]:
            parent = parent.setdefault(k, {})
        if parent.get(keys[-1]) is value:
            print(f"    LM Studio {'.'.join(keys)} already {value}")
            continue
        parent[keys[-1]] = value
        changed.append(f"{'.'.join(keys)}={value}")
    if not changed:
        continue
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    os.replace(tmp, path)
    print(f"    LM Studio set {', '.join(changed)}")

port = jobs[1][2].get("port")
if str(port) != "1234":
    print(f"    warning: LM Studio's server port is {port}; Open WebUI and wiki-mcp expect 1234")
PYEOF
    then :; else
        note "warning: LM Studio's settings could not be updated; turn on Developer > Start server on launch yourself"
    fi
    start_lmstudio_server
}

# autoStartOnLaunch is read at launch, and once enableLocalService is on the app ignores quit, so an app that was
# already open keeps its server off until the next login. lms starts it now (offline is fine) so wiki-mcp indexes
# with embeddings. An app that is not running is left alone: starting it from here could hang on Gatekeeper.
start_lmstudio_server() {
    local lms="${HOME}/.lmstudio/bin/lms" i
    curl -sf -m 2 -o /dev/null "${LMSTUDIO_URL}/models" && return 0
    if ! pgrep -f "/LM Studio.app/Contents/MacOS/LM Studio" >/dev/null 2>&1; then
        note "LM Studio is not running: its server starts the next time it is opened"
        return 0
    fi
    if [ ! -x "${lms}" ] || ! "${lms}" server start --port 1234 >/dev/null 2>&1; then
        note "warning: LM Studio's server could not be started; turn it on in the app's Developer tab"
        return 0
    fi
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if curl -sf -m 2 -o /dev/null "${LMSTUDIO_URL}/models"; then
            note "LM Studio server started on :1234 (${i}s)"
            return 0
        fi
        sleep 1
    done
    note "warning: lms started LM Studio's server but :1234 did not answer within 10s"
}

# ---- services ----------------------------------------------------------------------------
stop_agent() {
    run launchctl bootout "${DOMAIN}/$1" 2>/dev/null || true
    [ "${DRY}" = 1 ] && return 0
    # bootout returns before the job is gone; bootstrapping too early fails with an I/O error.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "${DOMAIN}/$1" >/dev/null 2>&1 || return 0
        sleep 1
    done
}

start_agent() {
    run launchctl bootstrap "${DOMAIN}" "${AGENTS}/$1.plist"
}

# ---- 2. migration ------------------------------------------------------------------------
# Open WebUI's settings live in its DB once written (PersistentConfig), so env values cannot fix a migrated DB.
patch_db() {
    "${PY}" - "$1" "http://127.0.0.1:${MCPO_PORT}" "$2" "${EMBEDDING_MODEL}" "${LMSTUDIO_URL}" <<'PY'
import json, sqlite3, sys, time
db, url, key, emb, lms = sys.argv[1:6]
con = sqlite3.connect(db)
def get(k):
    row = con.execute("select value from config where key = ?", (k,)).fetchone()
    return json.loads(row[0]) if row else None
def put(k, v):
    con.execute("insert into config(key, value, updated_at) values(?, ?, ?) "
                "on conflict(key) do update set value = excluded.value, updated_at = excluded.updated_at",
                (k, json.dumps(v, ensure_ascii=False), int(time.time())))
port = url.rsplit(":", 1)[1]
conns = get("tool_server.connections") or []
mine = [c for c in conns if str(c.get("url", "")).rstrip("/").endswith(":" + port)]
for c in mine:
    c["url"], c["key"], c["auth_type"] = url, key, "bearer"
if not mine:
    conns.append({"url": url, "path": "openapi.json", "type": "openapi", "auth_type": "bearer", "key": key,
                  "config": {"enable": True}, "info": {"id": "wiki-mcp", "name": "wiki-mcp", "description": ""}})
put("tool_server.connections", conns)
put("rag.embedding_engine", "openai")
put("rag.embedding_model", emb)
put("rag.openai.api_base_url", lms)
put("rag.openai.api_key", "lm-studio")
con.commit()
print(f"    DB: wiki tool server -> {url} ({'updated' if mine else 'added'}), RAG embedding -> {emb}")
PY
}

count_users() {
    "${PY}" -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select count(*) from user").fetchone()[0])' "$1"
}

migrate_openwebui() {
    local dest="${PREFIX}/openwebui-data"
    log "Open WebUI data: ${OLD_DATA} -> ${dest} (copy)"
    if [ -f "${dest}/webui.db" ]; then
        local users
        users="$(count_users "${dest}/webui.db")"
        [ "${users}" = 0 ] || die "${dest} already has ${users} account(s); refusing to replace it"
        run mv "${dest}" "${dest}.pre-migrate-${STAMP}"
        note "empty guardian data kept at ${dest}.pre-migrate-${STAMP}"
    fi
    # webui.db with its -wal/-shm, uploads, vector_db and cache together, so the copy is consistent.
    run ditto "${OLD_DATA}" "${dest}"
    if [ -f "${MIGRATE_FROM}/.webui_secret_key" ]; then
        run cp -p "${MIGRATE_FROM}/.webui_secret_key" "${dest}/.webui_secret_key"
        run chmod 600 "${dest}/.webui_secret_key"
    fi
    if [ "${DRY}" = 0 ]; then patch_db "${dest}/webui.db" "${MCPO_KEY}"; fi
}

# wiki-data is derived from wiki/. It is only worth copying when it holds vectors of the same model: a BM25-only
# cache would stop vectors from being built, and another dimension makes ChromaDB fail to load.
same_index() {
    local env="${MIGRATE_FROM}/.env"
    [ -f "${env}" ] || return 1
    [ "$(sed -n 's/^EMBEDDING_DISABLED=//p' "${env}" | head -1)" = 0 ] || return 1
    [ "$(sed -n 's/^EMBEDDING_MODEL=//p' "${env}" | head -1)" = "${EMBEDDING_MODEL}" ]
}

migrate_wiki() {
    local d
    for d in wiki wiki-data raw; do
        if [ ! -d "${MIGRATE_FROM}/${d}" ]; then continue; fi
        if [ "${d}" = wiki-data ] && ! same_index; then
            note "old wiki-data was not built with ${EMBEDDING_MODEL}: left behind, the index is rebuilt from wiki/"
            continue
        fi
        if [ -e "${WIKI_HOME}/${d}" ]; then
            note "${WIKI_HOME}/${d} exists, not copied from the old bundle"
        else
            run ditto "${MIGRATE_FROM}/${d}" "${WIKI_HOME}/${d}"
        fi
    done
}

# ---- 3. wiki home ------------------------------------------------------------------------
# Program files are refreshed on every run; the data folders are only created.
populate_home() {
    log "wiki home ${WIKI_HOME}"
    run mkdir -p "${WIKI_HOME}/logs" "${WIKI_HOME}/wiki-data"
    local f
    for f in run-wiki-mcp.sh load-env.sh; do run cp "${LAYER}/${f}" "${WIKI_HOME}/${f}"; done
    run chmod 755 "${WIKI_HOME}/run-wiki-mcp.sh"
    for f in ocr open-webui-tools document-templates docs; do
        [ -d "${LAYER}/${f}" ] && run ditto "${LAYER}/${f}" "${WIKI_HOME}/${f}"
    done
    run xattr -dr com.apple.quarantine "${WIKI_HOME}/ocr"
    [ -e "${WIKI_HOME}/wiki" ] || run ditto "${LAYER}/wiki" "${WIKI_HOME}/wiki"
    [ -e "${WIKI_HOME}/raw" ] || run ditto "${LAYER}/raw" "${WIKI_HOME}/raw"
}

# The .env is written once. A re-run keeps it, and its mcpo key, as they are, except for model ids that earlier
# bundles shipped as defaults and that are replaced (see upgrade_env).
write_env() {
    local env="${WIKI_HOME}/.env"
    if [ -f "${env}" ]; then
        note ".env kept (${env})"
        upgrade_env "${env}"
        return 0
    fi
    [ "${DRY}" = 1 ] && { echo "    [dry-run] write ${env} (mode 600, new mcpo key)"; return 0; }
    umask 077
    sed -e "s#@@VENV@@#${PREFIX}/venv#" -e "s#@@HOME@@#${WIKI_HOME}#g" \
        -e "s#@@MCPO_PORT@@#${MCPO_PORT}#" -e "s#@@MCPO_KEY@@#${MCPO_KEY}#" \
        -e "s#^EMBEDDING_MODEL=.*#EMBEDDING_MODEL=${EMBEDDING_MODEL}#" \
        "${LAYER}/wiki.env.example" >"${env}"
    [ -n "${MIGRATE_FROM}" ] && [ -f "${MIGRATE_FROM}/.env" ] && carry_env "${MIGRATE_FROM}/.env" "${env}"
    chmod 600 "${env}"
    note ".env written (mode 600)"
}

# The gemma alias pair: LM Studio names a model after where its files sit, so the bundle's gemma is listed as
# google/gemma-4-e4b on a Mac that got it through the LM Studio hub catalog (files under the hub's google/ folder)
# and as gemma-4-e4b-it-mlx on a fresh Mac the bundle installed it on. The two ids are the same model, so a kept
# .env can name the id this Mac's LM Studio does not list. This case statement is the one place that knows the
# pair, and only a value inside it is ever swapped — anything else was set by hand and is left alone.
model_alias() {
    case "${1}" in
        google/gemma-4-e4b) MODEL_ALIAS="gemma-4-e4b-it-mlx" ;;
        gemma-4-e4b-it-mlx) MODEL_ALIAS="google/gemma-4-e4b" ;;
        *) MODEL_ALIAS="" ;;
    esac
}

# Model ids LM Studio lists, one per line; empty when its server does not answer (plutil reads the JSON: a clean
# Mac has no python3).
lmstudio_ids() {
    local json i=0 id
    json="$(curl -fsS -m 5 "${LMSTUDIO_URL}/models" 2>/dev/null)" || return 0
    while id="$(printf '%s' "${json}" | plutil -extract "data.${i}.id" raw -o - - 2>/dev/null)"; do
        printf '%s\n' "${id}"
        i=$((i + 1))
    done
}

# Bundles up to 20261025T153406Z wrote these defaults, and nomic finds little in Korean notes. A value someone set
# by hand is left alone. wiki-mcp rebuilds its vector store by itself when the embedding model changes.
upgrade_env() {
    local env="$1" key old new cur ids
    # EMBEDDING_MODEL keeps its unconditional rule: the nomic default of the early bundles is replaced by this
    # bundle's embedding model, whatever the current LM Studio lists.
    key="EMBEDDING_MODEL"
    old="text-embedding-nomic-embed-text-v1.5"
    new="${EMBEDDING_MODEL}"
    cur="$(sed -n "s/^${key}=//p" "${env}" | head -1)"
    if [ "${cur}" = "${old}" ] && [ "${old}" != "${new}" ]; then
        if [ "${DRY}" = 1 ]; then
            note "[dry-run] .env ${key}: ${old} -> ${new}"
        else
            sed "s#^${key}=${old}\$#${key}=${new}#" "${env}" >"${env}.tmp" && cat "${env}.tmp" >"${env}" && rm -f "${env}.tmp"
            note ".env ${key}: ${old} -> ${new}"
        fi
    fi
    # WIKI_INGEST_MODEL: one gemma, two ids LM Studio can list (model_alias above). Swapped only when LM Studio
    # answers, does not list the id the .env names but lists its alias. An unanswered server is left as it is —
    # install-llm-wiki.sh runs this step again after LM Studio's first launch, which fixes it then.
    key="WIKI_INGEST_MODEL"
    cur="$(sed -n "s/^${key}=//p" "${env}" | head -1)"
    model_alias "${cur}"
    [ -n "${MODEL_ALIAS}" ] || return 0
    ids="$(lmstudio_ids)"
    if [ -z "${ids}" ]; then
        note "LM Studio is not answering: ${key} left as ${cur}"
        return 0
    fi
    case $'\n'"${ids}"$'\n' in
        *$'\n'"${cur}"$'\n'*) return 0 ;;    # this Mac's LM Studio lists it: nothing to swap
    esac
    case $'\n'"${ids}"$'\n' in
        *$'\n'"${MODEL_ALIAS}"$'\n'*) ;;
        *) return 0 ;;                        # neither id listed: leave the value alone
    esac
    if [ "${DRY}" = 1 ]; then
        note "[dry-run] .env ${key}: ${cur} -> ${MODEL_ALIAS}"
        return 0
    fi
    sed "s#^${key}=${cur}\$#${key}=${MODEL_ALIAS}#" "${env}" >"${env}.tmp" && cat "${env}.tmp" >"${env}" && rm -f "${env}.tmp"
    note ".env ${key}: ${cur} -> ${MODEL_ALIAS}"
}

# Only tuning values (ingest limits, timeout, templates, OCR switch) are carried over from the old file. Paths, the
# venv, the mcpo address/key and the model choice (gemma-4-e4b, bge-m3) belong to this bundle.
carry_env() {
    "${PY}" - "$1" "$2" <<'PY'
import re, sys
old_path, new_path = sys.argv[1:3]
tuning = re.compile(r"WIKI_INGEST_(MAX_[A-Z_]+|XLSX_MAX_ROWS|TIMEOUT|TEMPLATE|EXT|OCR)$|WIKI_DEFAULT_TEMPLATE$")
def parse(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"\s*([A-Z_][A-Z0-9_]*)=(.*)$", line.rstrip("\r\n"))
        if m:
            out.setdefault(m.group(1), m.group(2))
    return out
old = {k: v for k, v in parse(old_path).items() if tuning.match(k)}
lines = open(new_path, encoding="utf-8").read().splitlines()
seen = set()
for i, line in enumerate(lines):
    m = re.match(r"#?\s*([A-Z_][A-Z0-9_]*)=", line)
    if m and m.group(1) in old and m.group(1) not in seen:
        lines[i] = f"{m.group(1)}={old[m.group(1)]}"
        seen.add(m.group(1))
rest = [k for k in old if k not in seen]
if rest:
    lines += ["", "# carried over from the old bundle"] + [f"{k}={old[k]}" for k in rest]
open(new_path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(f"    .env: {len(old)} setting(s) carried over from the old bundle")
PY
}

# ---- 4. LaunchAgents ---------------------------------------------------------------------
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
}

# Seeds a fresh DB only: once tool_server.connections and rag.embedding_model are in the DB, Open WebUI ignores
# these variables. The guardian installer writes its own RAG_EMBEDDING_MODEL (nomic), replaced here.
patch_webui_agent() {
    local plist="${AGENTS}/${WEBUI_LABEL}.plist"
    if [ ! -f "${plist}" ]; then
        [ "${DRY}" = 1 ] || die "${plist} missing: run ./install.sh first"
        echo "    [dry-run] set TOOL_SERVER_CONNECTIONS and RAG_EMBEDDING_MODEL in ${plist}"; return 0
    fi
    local conn="[{\"url\":\"http://127.0.0.1:${MCPO_PORT}\",\"path\":\"openapi.json\",\"type\":\"openapi\",\"auth_type\":\"bearer\",\"key\":\"${MCPO_KEY}\",\"config\":{\"enable\":true},\"info\":{\"id\":\"wiki-mcp\",\"name\":\"wiki-mcp\",\"description\":\"\"}}]"
    if [ "${DRY}" = 1 ]; then
        echo "    [dry-run] set TOOL_SERVER_CONNECTIONS and RAG_EMBEDDING_MODEL=${EMBEDDING_MODEL} in ${plist}"
    else
        plutil -replace EnvironmentVariables.TOOL_SERVER_CONNECTIONS -string "${conn}" "${plist}"
        plutil -replace EnvironmentVariables.RAG_EMBEDDING_MODEL -string "${EMBEDDING_MODEL}" "${plist}"
        chmod 600 "${plist}"   # it now holds the mcpo key
    fi
    if [ -n "${WEBUI_HOST}" ]; then
        [ "$(plutil -extract ProgramArguments.2 raw "${plist}")" = "--host" ] || die "unexpected ${plist} layout"
        run plutil -replace ProgramArguments.3 -string "${WEBUI_HOST}" "${plist}"
        note "Open WebUI binds to ${WEBUI_HOST}"
    fi
}

# ---- 5. start and check ------------------------------------------------------------------
# mcpo serves openapi.json without auth, so a 200 there says nothing about the key. The key is checked with an empty
# POST to a tool that has required arguments: mcpo checks auth before the body, so 422 means the key was accepted and
# the tool never ran. A tool without required arguments would run on {}, so those are never picked.
check_mcpo() {
    local i base="http://127.0.0.1:${MCPO_PORT}" up="" tool code
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
    # Header from stdin keeps the key out of the process list. A transport failure leaves 000 and falls to the last case.
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -H @- -d '{}' \
        "${base}${tool}" <<< "Authorization: Bearer ${MCPO_KEY}")" || true
    case "${code}" in
        422)     note "mcpo answers on 127.0.0.1:${MCPO_PORT} (${up}s) and accepts the key" ;;
        401|403) die "mcpo rejects WIKI_MCPO_KEY (HTTP ${code}); compare ${WIKI_HOME}/.env with the running mcpo" ;;
        *)       die "mcpo key check on ${tool} returned HTTP ${code}; see ${WIKI_HOME}/logs/mcpo.log" ;;
    esac
}

# A model id LM Studio does not know fails only at use: embeddings drop the wiki to BM25, ingestion stops. LM Studio
# lists downloaded models whether or not they are loaded. With its server down nothing can be checked.
check_models() {
    local env="${WIKI_HOME}/.env" ids key id
    ids="$(curl -sf -m 3 "${LMSTUDIO_URL}/models" 2>/dev/null)" || {
        note "LM Studio server is down: model ids not checked"
        return 0
    }
    for key in EMBEDDING_MODEL WIKI_INGEST_MODEL; do
        id="$(sed -n "s/^${key}=//p" "${env}" | head -1)"
        [ -n "${id}" ] || continue
        if printf '%s' "${ids}" | grep -qF "\"${id}\""; then
            note "LM Studio has ${id} (${key})"
        else
            note "warning: LM Studio does not list ${id} (${key} in ${env}); see ${LMSTUDIO_URL}/models"
        fi
    done
}

# ---- main --------------------------------------------------------------------------------
preflight
install_packages
install_embedding
configure_lmstudio
if [ -f "${WIKI_HOME}/.env" ]; then
    # Parsed the way run-wiki-mcp.sh does (quotes, inline comments, CRLF), so Open WebUI gets the key mcpo runs with.
    MCPO_KEY="$(unset WIKI_MCPO_KEY; . "${LAYER}/load-env.sh"; load_env "${WIKI_HOME}/.env"; printf '%s' "${WIKI_MCPO_KEY:-}")"
    [ -n "${MCPO_KEY}" ] || die "${WIKI_HOME}/.env has no WIKI_MCPO_KEY"
else
    MCPO_KEY="$(openssl rand -hex 24)"
fi

log "stopping services"
for l in "${MCPO_LABEL}" "${WATCH_LABEL}" "${WEBUI_LABEL}"; do stop_agent "${l}"; done
run mkdir -p "${WIKI_HOME}"
if [ -n "${MIGRATE_FROM}" ]; then
    migrate_openwebui
    migrate_wiki
fi
populate_home
write_env

log "LaunchAgents"
write_agent "${MCPO_LABEL}" mcpo
write_agent "${WATCH_LABEL}" watch
patch_webui_agent

if [ "${DO_START}" = 1 ]; then
    log "starting services"
    for l in "${WEBUI_LABEL}" "${MCPO_LABEL}" "${WATCH_LABEL}"; do start_agent "${l}"; done
    [ "${DRY}" = 1 ] || { check_mcpo; check_models; }
else
    note "not started: launchctl bootstrap ${DOMAIN} ~/Library/LaunchAgents/{${WEBUI_LABEL},${MCPO_LABEL},${WATCH_LABEL}}.plist"
fi
log "done$([ "${DRY}" = 1 ] && echo ' (dry run: nothing was changed)')"
