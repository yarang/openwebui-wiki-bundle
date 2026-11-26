#!/bin/bash
# Acceptance test for two upgrade fixes (build Mac only, a human runs it). All test data is synthetic.
#   1. install-all.sh --upgrade-app stops only the LM Studio service THIS run started (the guardian step can
#      leave one running with --run-as-service), never one that was open before the install began.
#   2. the gemma model-id alias pair (google/gemma-4-e4b <-> gemma-4-e4b-it-mlx): the wiki .env is matched to
#      the id this Mac's LM Studio lists, and install-claude-code.sh swaps a taken-over id for its alias.
# Nothing real is touched: stub installers in fake bundles, mktemp fake HOMEs, a stub HTTP server on 127.0.0.1
# for LM Studio's /v1/models, and a fake "LM Studio" process — a copy of /bin/sh re-signed ad hoc (this macOS
# kills a plain copy of a platform binary) — always cleaned up at the end. When a REAL LM Studio is running on
# this Mac, section 1 is skipped entirely and that process is never signalled.
# Usage: [CLAUDE_LMS_PY=<python>] guardian/tests/accept_upgrade_fixes.sh
#        (the python only serves the stub /v1/models; "ACCEPT PASS" and exit 0 when everything passed)
set -u
SECONDS=0
G="$(cd "$(dirname "$0")/.." && pwd)"
IA="$G/install-all.sh"
IW="$G/install-wiki.sh"
ICC="$G/install-claude-code.sh"
PY="${CLAUDE_LMS_PY:-$HOME/.guardian-llm/venv/bin/python}"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-upgrade.XXXXXX")"
T="$(cd "$T" && pwd)"
mkdir -p "$T/tmp"
KILL_PIDS="$T/kill-pids"   # every pid this test must clean up: fake LM Studio processes, stub servers
: >"$KILL_PIDS"
trap '{ while IFS= read -r p; do kill -9 "$p" 2>/dev/null; done <"$KILL_PIDS"; wait; } 2>/dev/null; rm -rf "${T:?}"' EXIT
fail=0
pass() { echo "PASS $1"; }
skip() { echo "SKIP $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }
has()  { local f="$1" s="$2"; grep -Fq -e "$s" "$f"; }
hasnt(){ local f="$1" s="$2"; ! grep -Fq -e "$s" "$f"; }

[ -x "$PY" ] || { echo "FAIL python missing: $PY (set CLAUDE_LMS_PY)"; exit 1; }

# ---- 0. syntax ------------------------------------------------------------------------------------
for f in "$IA" "$IW" "$ICC" "$0"; do
    if /bin/bash -n "$f"; then pass "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f")" "does not parse"; fi
done

CALLS="$T/calls.log"
export CALLS

# stub FILE NAME — a stub installer that records its argv, the way accept_install_all.sh does.
stub() {
    local p="$1" n="$2"
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\nexit 0\n' "$n" >"$p"
    chmod 755 "$p"
}

# wait_gone PID — 0 once the pid is no longer running (checks for up to 5s).
wait_gone() {
    local p="$1" i
    for i in $(seq 1 25); do
        if ! kill -0 "$p" 2>/dev/null; then return 0; fi
        sleep 0.2
    done
    return 1
}

# ---- 1. --upgrade-app stops only the service this run started -------------------------------------
# A fake HOME whose Applications holds LM Studio.app 0.0.0: the fake copy wins the folder pick over the real
# /Applications, and 0.0.0 is older than the bundle's app_version, so the --upgrade-app path always runs.
mk_home() {
    local h="$1"
    mkdir -p "$h/Applications/LM Studio.app/Contents"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n<key>CFBundleShortVersionString</key>\n<string>0.0.0</string>\n</dict>\n</plist>\n' \
        >"$h/Applications/LM Studio.app/Contents/Info.plist"
}

# A bundle whose MANIFEST.env ships a dmg (app_dmg non-empty, app_version 99.0.0) and whose app/ holds the
# (empty) dmg file: a dry run never mounts it, a real run stops at its "cannot mount" — which is what lets the
# real-run case stop right after the service stop without mounting anything.
mk_dmg_bundle() {
    local d="$1" n
    n="$(basename "${d}")-lmstudio.dmg"
    mkdir -p "$d/app" "$d/wiki-layer" "$d/claude-code" "$d/wiki-mcp-kit" "$d/vscode-addon" "$d/hop-viewer"
    cp "$IA" "$d/install-all.sh"
    printf 'app_name=LM Studio.app\napp_version=99.0.0\napp_dmg=%s\n' "$n" >"$d/MANIFEST.env"
    : >"$d/app/$n"
    stub "$d/install.sh" install.sh
    stub "$d/wiki-layer/install-wiki.sh" install-wiki.sh
    stub "$d/claude-code/install-claude-code.sh" install-claude-code.sh
    stub "$d/wiki-mcp-kit/install-wiki-mcp.sh" install-wiki-mcp.sh
    stub "$d/vscode-addon/install-vscode.sh" install-vscode.sh
    stub "$d/hop-viewer/install-hop.sh" install-hop.sh
}

# The fake "LM Studio" executable: a copy of /bin/sh re-signed ad hoc — a plain copy of a platform binary is
# SIGKILLed on exec by this macOS, the re-signed copy runs and keeps the exact process name "LM Studio".
mk_fake_lm() {
    mkdir -p "$T/fake"
    cp /bin/sh "$T/fake/LM Studio"
    codesign -f -s - "$T/fake/LM Studio" >/dev/null 2>&1
}

# start_fake_lm PIDFILE FLAG — runs the fake "LM Studio" process (with FLAG, e.g. --run-as-service), records
# the pid in PIDFILE and in $KILL_PIDS, and returns only once pgrep -x sees it.
start_fake_lm() {
    local pidfile="$1" flag="${2:-}" i
    "$T/fake/LM Studio" -c 'while :; do sleep 1; done' x ${flag} &
    echo "$!" >"$pidfile"
    echo "$!" >>"$KILL_PIDS"
    for i in $(seq 1 20); do
        if pgrep -x "LM Studio" >/dev/null 2>&1; then return 0; fi
        sleep 0.1
    done
    bad "fake LM Studio process starts" "pgrep -x found nothing within 2s"
    return 1
}

# spawn_stub FILE FLAG — the guardian installer stub for a fake bundle: starts a fake "LM Studio" service the
# way the real `lms runtime select` does (PPID 1 once the stub exits), records the pid in $SPAWN_PIDFILE and
# returns only once pgrep -x sees it, so the app step always finds it running.
spawn_stub() {
    local p="$1" flag="${2:-}"
    cat >"$p" <<STUB
#!/bin/sh
echo "install.sh \$*" >> "\$CALLS"
"$T/fake/LM Studio" -c 'while :; do sleep 1; done' x ${flag} &
echo "\$!" >> "$KILL_PIDS"
echo "\$!" > "$SPAWN_PIDFILE"
i=0
while [ "\$i" -lt 100 ]; do
    pgrep -x "LM Studio" >/dev/null 2>&1 && exit 0
    sleep 0.1
    i=\$((i + 1))
done
exit 0
STUB
    chmod 755 "$p"
}

# run_all HOME BUNDLE OUT ERR args... — install-all.sh against a fake HOME; TMPDIR is the test's own folder,
# so the dmg mount's leaked staging dir never lands outside it.
run_all() {
    local h="$1" b="$2" o="$3" e="$4"; shift 4
    HOME="$h" TMPDIR="$T/tmp" bash "$b/install-all.sh" "$@" >"$o" 2>"$e"
}

# cleanup_fake PIDFILE... — kill the fake processes a case started and wait until they are gone, so the next
# case's pgrep waits and snapshots see a clean slate.
cleanup_fake() {
    local f p
    for f in "$@"; do
        p="$(cat "$f" 2>/dev/null)"
        [ -n "$p" ] && kill "$p" 2>/dev/null
    done
    for f in "$@"; do
        p="$(cat "$f" 2>/dev/null)"
        [ -n "$p" ] && wait_gone "$p"
    done
}

REAL_LM=0
if pgrep -x "LM Studio" >/dev/null 2>&1; then REAL_LM=1; fi

if [ "$REAL_LM" = 1 ]; then
    skip "1a --upgrade-app --dry-run (a real LM Studio is running on this Mac; never touched)"
    skip "1b --upgrade-app real run stops the started service (a real LM Studio is running)"
    skip "1c a service open before the install is never killed (a real LM Studio is running)"
    skip "1d a started service without --run-as-service is never killed (a real LM Studio is running)"
    skip "1e nothing running: the install goes on (a real LM Studio is running)"
else
    mk_fake_lm

    # 1a. dry-run: the started service is announced and left alive
    B1="$T/b1"; mk_dmg_bundle "$B1"
    H1="$T/h1"; mk_home "$H1"
    : >"$CALLS"
    SPAWN_PIDFILE="$T/spawn-a.pid"; export SPAWN_PIDFILE
    spawn_stub "$B1/install.sh" "--run-as-service"
    run_all "$H1" "$B1" "$T/a.out" "$T/a.err" --upgrade-app --dry-run
    rc=$?
    spa="$(cat "$SPAWN_PIDFILE" 2>/dev/null)"
    if [ $rc -eq 0 ]; then pass "1a --upgrade-app --dry-run exits 0"; else bad "1a --upgrade-app --dry-run exits 0" "rc=$rc $(tail -2 "$T/a.err")"; fi
    if has "$T/a.out" "[dry-run] would stop the LM Studio service this run started (pid "; then
        pass "1a prints the [dry-run] would-stop line"
    else
        bad "1a prints the [dry-run] would-stop line" "$(grep 'LM Studio service' "$T/a.out" | head -1)"
    fi
    if [ -n "$spa" ] && kill -0 "$spa" 2>/dev/null; then
        pass "1a the service this run started is still alive"
    else
        bad "1a the service this run started is still alive" "pid '${spa:-none}'"
    fi
    cleanup_fake "$SPAWN_PIDFILE"

    # 1b. real run: the started service is stopped (SIGTERM), no "close it first", then the empty dmg stops
    # the install at its mount — nothing outside the fake HOME was touched
    B2="$T/b2"; mk_dmg_bundle "$B2"
    H2="$T/h2"; mk_home "$H2"
    : >"$CALLS"
    SPAWN_PIDFILE="$T/spawn-b.pid"; export SPAWN_PIDFILE
    spawn_stub "$B2/install.sh" "--run-as-service"
    run_all "$H2" "$B2" "$T/b.out" "$T/b.err" --upgrade-app
    rc=$?
    spa="$(cat "$SPAWN_PIDFILE" 2>/dev/null)"
    if [ -n "$spa" ] && wait_gone "$spa"; then
        pass "1b the service this run started is gone"
    else
        bad "1b the service this run started is gone" "pid '${spa:-none}' still running (rc=$rc)"
    fi
    if hasnt "$T/b.out" "close it first" && hasnt "$T/b.err" "close it first"; then
        pass "1b never says close it first"
    else
        bad "1b never says close it first" "$(grep -h 'close it first' "$T/b.out" "$T/b.err" | head -1)"
    fi
    if has "$T/b.out" "stopping the LM Studio service this run started (pid "; then
        pass "1b prints the stopping note"
    else
        bad "1b prints the stopping note" "$(grep 'LM Studio service' "$T/b.out" | head -1)"
    fi
    if [ $rc -ne 0 ] && { has "$T/b.err" "cannot mount" || has "$T/b.err" "has no LM Studio.app"; }; then
        pass "1b stops at the empty dmg after the service is down (allowed failure)"
    else
        bad "1b stops at the empty dmg after the service is down (allowed failure)" "rc=$rc $(tail -1 "$T/b.err")"
    fi

    # 1c. a service that was open BEFORE the install: install-all's startup snapshot holds its pid, so it is
    # the user's — the run dies asking them to close it and kills nothing (the stub's own service survives too)
    B3="$T/b3"; mk_dmg_bundle "$B3"
    H3="$T/h3"; mk_home "$H3"
    : >"$CALLS"
    SPAWN_PIDFILE="$T/spawn-c.pid"; export SPAWN_PIDFILE
    spawn_stub "$B3/install.sh" "--run-as-service"
    start_fake_lm "$T/user-c.pid" "--run-as-service"
    up="$(cat "$T/user-c.pid" 2>/dev/null)"
    run_all "$H3" "$B3" "$T/c.out" "$T/c.err" --upgrade-app
    rc=$?
    spa="$(cat "$SPAWN_PIDFILE" 2>/dev/null)"
    if [ $rc -ne 0 ]; then pass "1c exits non-zero"; else bad "1c exits non-zero" "rc=0"; fi
    if has "$T/c.err" "LM Studio is running: close it first"; then
        pass "1c says close it first"
    else
        bad "1c says close it first" "$(tail -1 "$T/c.err")"
    fi
    if [ -n "$up" ] && kill -0 "$up" 2>/dev/null; then
        pass "1c the process open before the install is still alive"
    else
        bad "1c the process open before the install is still alive" "pid '${up:-none}'"
    fi
    if [ -n "$spa" ] && kill -0 "$spa" 2>/dev/null; then
        pass "1c the service this run started is still alive too"
    else
        bad "1c the service this run started is still alive too" "pid '${spa:-none}'"
    fi
    cleanup_fake "$T/user-c.pid" "$SPAWN_PIDFILE"

    # 1d. a service WITHOUT --run-as-service: not this run's, whatever the snapshot says
    B4="$T/b4"; mk_dmg_bundle "$B4"
    H4="$T/h4"; mk_home "$H4"
    : >"$CALLS"
    SPAWN_PIDFILE="$T/spawn-d.pid"; export SPAWN_PIDFILE
    spawn_stub "$B4/install.sh" ""
    run_all "$H4" "$B4" "$T/d.out" "$T/d.err" --upgrade-app
    rc=$?
    spa="$(cat "$SPAWN_PIDFILE" 2>/dev/null)"
    if [ $rc -ne 0 ]; then pass "1d exits non-zero"; else bad "1d exits non-zero" "rc=0"; fi
    if has "$T/d.err" "LM Studio is running: close it first"; then
        pass "1d says close it first"
    else
        bad "1d says close it first" "$(tail -1 "$T/d.err")"
    fi
    if [ -n "$spa" ] && kill -0 "$spa" 2>/dev/null; then
        pass "1d the service without --run-as-service is still alive"
    else
        bad "1d the service without --run-as-service is still alive" "pid '${spa:-none}'"
    fi
    cleanup_fake "$SPAWN_PIDFILE"

    # 1e. nothing running: the install goes on without any close-it-first note
    B5="$T/b5"; mk_dmg_bundle "$B5"
    H5="$T/h5"; mk_home "$H5"
    run_all "$H5" "$B5" "$T/e.out" "$T/e.err" --upgrade-app
    rc=$?
    if [ $rc -ne 0 ]; then pass "1e exits non-zero (at the empty dmg)"; else bad "1e exits non-zero (at the empty dmg)" "rc=0"; fi
    if hasnt "$T/e.out" "close it first" && hasnt "$T/e.err" "close it first"; then
        pass "1e no close it first when nothing is running"
    else
        bad "1e no close it first when nothing is running" "$(grep -h 'close it first' "$T/e.out" "$T/e.err" | head -1)"
    fi
    if has "$T/e.err" "cannot mount" || has "$T/e.err" "has no LM Studio.app"; then
        pass "1e reaches the dmg step"
    else
        bad "1e reaches the dmg step" "$(tail -1 "$T/e.err")"
    fi
fi

# ---- 2. install-wiki.sh upgrade_env: the gemma alias pair -----------------------------------------
# Dry runs only — a real run would bootout/bootstrap LaunchAgents, which is off limits. The wiki-layer is a
# minimal real one: install-wiki.sh only needs wheels/ beside itself and load-env.sh to read a kept .env's key.
mk_wiki_layer() {
    local d="$1"
    mkdir -p "$d/wiki-layer/wheels"
    cp "$IW" "$d/wiki-layer/install-wiki.sh"
    cp "$G/../load-env.sh" "$d/wiki-layer/load-env.sh"
    printf 'wiki_mcp=stub-wheel\n' >"$d/MANIFEST.env"
}
mk_wiki_layer "$T/wl"

# start_models_stub DIR PORTFILE — serves DIR as /v1/models on 127.0.0.1 from an ephemeral port (written to
# PORTFILE). The JSON file is rewritten between cases; the server reads it again per request.
start_models_stub() {
    local dir="$1" portfile="$2" i port
    "$PY" -I -c '
import functools, sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
port_file, directory = sys.argv[1], sys.argv[2]
class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass
handler = functools.partial(Quiet, directory=directory)
httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler)
with open(port_file, "w") as f:
    f.write(str(httpd.server_address[1]) + "\n")
httpd.serve_forever()
' "$portfile" "$dir" >/dev/null 2>&1 &
    echo "$!" >>"$KILL_PIDS"
    for i in $(seq 1 50); do
        [ -s "$portfile" ] && port="$(cat "$portfile")" && [ -n "$port" ] \
            && curl -fsS -m 1 "http://127.0.0.1:${port}/v1/models" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    bad "stub /v1/models server answers" "${portfile} never answered"
    return 1
}

# A fake wiki home with a kept .env (synthetic key): mode 600, as the installer writes it.
mk_wiki_home() {
    local h="$1" ingest="$2"
    mkdir -p "$h/llm-wiki"
    printf 'EMBEDDING_MODEL=text-embedding-bge-m3\nWIKI_MCPO_KEY=test-key-12345\nWIKI_INGEST_MODEL=%s\n' "$ingest" \
        >"$h/llm-wiki/.env"
    chmod 600 "$h/llm-wiki/.env"
}

run_wiki() {
    local h="$1" o="$2" e="$3" url="$4"
    HOME="$h" TMPDIR="$T/tmp" WIKI_LMSTUDIO_URL="$url" \
        bash "$T/wl/wiki-layer/install-wiki.sh" --dry-run --no-start --wiki-home="$h/llm-wiki" >"$o" 2>"$e"
}

WSTUB="$T/wstub"; mkdir -p "$WSTUB/v1"
: >"$WSTUB/v1/models"
WPORT_FILE="$WSTUB.port"
start_models_stub "$WSTUB" "$WPORT_FILE"
WPORT="$(cat "$WPORT_FILE")"
WURL="http://127.0.0.1:${WPORT}/v1"

# 2a. the .env's id is listed: kept
W="$T/w2a"; mk_wiki_home "$W" "google/gemma-4-e4b"
cp "$W/llm-wiki/.env" "$T/w2a.orig"
printf '{"data":[{"id":"google/gemma-4-e4b"},{"id":"text-embedding-bge-m3"}]}' >"$WSTUB/v1/models"
run_wiki "$W" "$T/w2a.out" "$T/w2a.err" "$WURL"
rc=$?
if [ $rc -eq 0 ]; then pass "2a dry run exits 0"; else bad "2a dry run exits 0" "rc=$rc $(tail -2 "$T/w2a.err")"; fi
if hasnt "$T/w2a.out" "WIKI_INGEST_MODEL"; then pass "2a keeps a listed id, no swap note"; else bad "2a keeps a listed id, no swap note" "$(grep WIKI_INGEST_MODEL "$T/w2a.out" | head -1)"; fi
if cmp -s "$T/w2a.orig" "$W/llm-wiki/.env"; then pass "2a .env byte-identical"; else bad "2a .env byte-identical" "changed"; fi
if [ "$(stat -f %Lp "$W/llm-wiki/.env")" = 600 ]; then pass "2a .env still mode 600"; else bad "2a .env still mode 600" "$(stat -f %Lp "$W/llm-wiki/.env")"; fi

# 2b. the hub-catalog id is in the .env but only the bundle's id is listed: swap announced (dry run writes nothing)
W="$T/w2b"; mk_wiki_home "$W" "google/gemma-4-e4b"
cp "$W/llm-wiki/.env" "$T/w2b.orig"
printf '{"data":[{"id":"gemma-4-e4b-it-mlx"},{"id":"text-embedding-bge-m3"}]}' >"$WSTUB/v1/models"
run_wiki "$W" "$T/w2b.out" "$T/w2b.err" "$WURL"
rc=$?
if [ $rc -eq 0 ]; then pass "2b dry run exits 0"; else bad "2b dry run exits 0" "rc=$rc $(tail -2 "$T/w2b.err")"; fi
if has "$T/w2b.out" "[dry-run] .env WIKI_INGEST_MODEL: google/gemma-4-e4b -> gemma-4-e4b-it-mlx"; then
    pass "2b announces the swap to the bundle id"
else
    bad "2b announces the swap to the bundle id" "$(grep WIKI_INGEST_MODEL "$T/w2b.out" | head -1)"
fi
if cmp -s "$T/w2b.orig" "$W/llm-wiki/.env"; then pass "2b dry run leaves the .env byte-identical"; else bad "2b dry run leaves the .env byte-identical" "changed"; fi
if [ "$(stat -f %Lp "$W/llm-wiki/.env")" = 600 ]; then pass "2b .env still mode 600"; else bad "2b .env still mode 600" "$(stat -f %Lp "$W/llm-wiki/.env")"; fi

# 2c. the other direction: the bundle's id is in the .env, the hub catalog's id is the only one listed
W="$T/w2c"; mk_wiki_home "$W" "gemma-4-e4b-it-mlx"
cp "$W/llm-wiki/.env" "$T/w2c.orig"
printf '{"data":[{"id":"google/gemma-4-e4b"},{"id":"text-embedding-bge-m3"}]}' >"$WSTUB/v1/models"
run_wiki "$W" "$T/w2c.out" "$T/w2c.err" "$WURL"
rc=$?
if [ $rc -eq 0 ]; then pass "2c dry run exits 0"; else bad "2c dry run exits 0" "rc=$rc $(tail -2 "$T/w2c.err")"; fi
if has "$T/w2c.out" "[dry-run] .env WIKI_INGEST_MODEL: gemma-4-e4b-it-mlx -> google/gemma-4-e4b"; then
    pass "2c announces the swap to the hub catalog id"
else
    bad "2c announces the swap to the hub catalog id" "$(grep WIKI_INGEST_MODEL "$T/w2c.out" | head -1)"
fi
if cmp -s "$T/w2c.orig" "$W/llm-wiki/.env"; then pass "2c dry run leaves the .env byte-identical"; else bad "2c dry run leaves the .env byte-identical" "changed"; fi

# 2d. LM Studio does not answer: the value is left as it is, with a note
W="$T/w2d"; mk_wiki_home "$W" "google/gemma-4-e4b"
cp "$W/llm-wiki/.env" "$T/w2d.orig"
run_wiki "$W" "$T/w2d.out" "$T/w2d.err" "http://127.0.0.1:9/v1"
rc=$?
if [ $rc -eq 0 ]; then pass "2d dry run exits 0"; else bad "2d dry run exits 0" "rc=$rc $(tail -2 "$T/w2d.err")"; fi
if has "$T/w2d.out" "LM Studio is not answering: WIKI_INGEST_MODEL left as google/gemma-4-e4b"; then
    pass "2d says LM Studio is not answering"
else
    bad "2d says LM Studio is not answering" "$(grep 'not answering' "$T/w2d.out" | head -1)"
fi
if cmp -s "$T/w2d.orig" "$W/llm-wiki/.env"; then pass "2d .env byte-identical"; else bad "2d .env byte-identical" "changed"; fi

# 2e. a value outside the pair (set by hand): never touched, never asked about
W="$T/w2e"; mk_wiki_home "$W" "my/custom-model"
cp "$W/llm-wiki/.env" "$T/w2e.orig"
printf '{"data":[{"id":"google/gemma-4-e4b"},{"id":"text-embedding-bge-m3"}]}' >"$WSTUB/v1/models"
run_wiki "$W" "$T/w2e.out" "$T/w2e.err" "$WURL"
rc=$?
if [ $rc -eq 0 ]; then pass "2e dry run exits 0"; else bad "2e dry run exits 0" "rc=$rc $(tail -2 "$T/w2e.err")"; fi
if hasnt "$T/w2e.out" "WIKI_INGEST_MODEL" && hasnt "$T/w2e.out" "not answering"; then
    pass "2e leaves a hand-set value alone"
else
    bad "2e leaves a hand-set value alone" "$(grep -E 'WIKI_INGEST_MODEL|not answering' "$T/w2e.out" | head -1)"
fi
if cmp -s "$T/w2e.orig" "$W/llm-wiki/.env"; then pass "2e .env byte-identical"; else bad "2e .env byte-identical" "changed"; fi

# 2f. the real write, without running install-wiki.sh itself (its non-dry-run path would stop and start
# LaunchAgents): upgrade_env, model_alias and lmstudio_ids are extracted from the script with sed and sourced
# into a subshell with DRY=0. The other lines of the .env must survive byte for byte, mode 600 included.
W="$T/w2f"; mk_wiki_home "$W" "google/gemma-4-e4b"
printf '{"data":[{"id":"gemma-4-e4b-it-mlx"},{"id":"text-embedding-bge-m3"}]}' >"$WSTUB/v1/models"
extract_fn() { sed -n "/^$1() {/,/^}/p" "$IW"; }
{
    printf 'note() { echo "    $*"; }\n'
    extract_fn model_alias
    extract_fn lmstudio_ids
    extract_fn upgrade_env
} >"$T/upgrade_env_only.sh"
(
    DRY=0
    # install-wiki.sh sets this before upgrade_env runs; this script runs under set -u, so it is needed here too
    EMBEDDING_MODEL="text-embedding-bge-m3"
    LMSTUDIO_URL="$WURL"
    . "$T/upgrade_env_only.sh"
    upgrade_env "$W/llm-wiki/.env"
) >"$T/w2f.out" 2>&1
if grep -q '^WIKI_INGEST_MODEL=gemma-4-e4b-it-mlx$' "$W/llm-wiki/.env"; then
    pass "2f the .env line is really swapped"
else
    bad "2f the .env line is really swapped" "$(grep WIKI_INGEST_MODEL "$W/llm-wiki/.env" | head -1)"
fi
if grep -q '^WIKI_MCPO_KEY=test-key-12345$' "$W/llm-wiki/.env" && grep -q '^EMBEDDING_MODEL=text-embedding-bge-m3$' "$W/llm-wiki/.env"; then
    pass "2f the other lines are byte-identical"
else
    bad "2f the other lines are byte-identical" "$(cat "$W/llm-wiki/.env")"
fi
if [ "$(stat -f %Lp "$W/llm-wiki/.env")" = 600 ]; then pass "2f .env still mode 600"; else bad "2f .env still mode 600" "$(stat -f %Lp "$W/llm-wiki/.env")"; fi
if [ "$(wc -l <"$W/llm-wiki/.env" | tr -d ' ')" = 3 ]; then pass "2f no line added or lost"; else bad "2f no line added or lost" "$(cat "$W/llm-wiki/.env")"; fi

# ---- 3. install-claude-code.sh: a taken-over model id is swapped for its alias --------------------
CC_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
if [ -x "$CC_BIN" ]; then
    pass "3 claude binary present"
else
    echo "FAIL claude binary missing: $CC_BIN"; exit 1
fi
CCREAL="$(readlink -f "$CC_BIN")"
CCVER="$("$CCREAL" --version | awk '{print $1}')"

# mk_cc_kit DIR — the folder install-claude-code.sh expects: the installer, claude-lms, the signed claude
# binary and VERSION. No skills (--no-skills) and no router, so no kit skills and no llm-router are needed.
mk_cc_kit() {
    local k="$1"
    mkdir -p "$k"
    cp "$ICC" "$G/claude-lms" "$k/"
    chmod 755 "$k/install-claude-code.sh" "$k/claude-lms"
    cp "$CCREAL" "$k/claude"
    echo "$CCVER" >"$k/VERSION"
}
mk_cc_kit "$T/kit"

# mk_cc_home DIR — a fake HOME whose wiki .env names the bundle's id, with claude already installed at the
# same version so step 1 skips the copy.
mk_cc_home() {
    local h="$1"
    mkdir -p "$h/.local/share/claude/versions" "$h/.local/bin" "$h/llm-wiki"
    cp "$T/kit/claude" "$h/.local/share/claude/versions/$CCVER"
    ln -s "$h/.local/share/claude/versions/$CCVER" "$h/.local/bin/claude"
    printf 'WIKI_INGEST_MODEL=gemma-4-e4b-it-mlx\n' >"$h/llm-wiki/.env"
}

run_cc() {
    local n="$1" h="$2"; shift 2
    HOME="$h" CLAUDE_LMS_PY="$PY" XDG_CONFIG_HOME="$h/.config" TMPDIR="$T/tmp" \
        "$T/kit/install-claude-code.sh" --lmstudio-url="http://127.0.0.1:$CPORT" --no-skills --no-path "$@" \
        >"$T/$n.out" 2>&1
    echo $? >"$T/$n.rc"
}

CSTUB="$T/cstub"; mkdir -p "$CSTUB/v1"
: >"$CSTUB/v1/models"
CPORT_FILE="$CSTUB.port"
start_models_stub "$CSTUB" "$CPORT_FILE"
CPORT="$(cat "$CPORT_FILE")"

# 3a. the wiki's id is not listed, its alias is: swap, note, conf holds the listed id
H="$T/c3a"; mk_cc_home "$H"
printf '{"data":[{"id":"google/gemma-4-e4b"},{"id":"text-embedding-bge-m3"}]}' >"$CSTUB/v1/models"
run_cc c3a "$H"
rc="$(cat "$T/c3a.rc")"
if [ "$rc" = 0 ]; then pass "3a exits 0"; else bad "3a exits 0" "rc=$rc $(tail -3 "$T/c3a.out")"; fi
if grep -q "^CLAUDE_LMS_MODEL='google/gemma-4-e4b'\$" "$H/.config/claude-lms/env"; then
    pass "3a conf holds the alias this Mac lists"
else
    bad "3a conf holds the alias this Mac lists" "$(grep CLAUDE_LMS_MODEL "$H/.config/claude-lms/env")"
fi
if has "$T/c3a.out" "gemma-4-e4b-it-mlx is listed as google/gemma-4-e4b on this Mac's LM Studio: using google/gemma-4-e4b"; then
    pass "3a prints the swap note"
else
    bad "3a prints the swap note" "$(grep 'listed as' "$T/c3a.out" | head -1)"
fi
if grep -q '^WIKI_INGEST_MODEL=gemma-4-e4b-it-mlx$' "$H/llm-wiki/.env"; then
    pass "3a the wiki .env is left alone"
else
    bad "3a the wiki .env is left alone" "$(cat "$H/llm-wiki/.env")"
fi

# 3b. an explicit --model that is not listed: refused, nothing written
H="$T/c3b"; mk_cc_home "$H"
run_cc c3b "$H" --model=gemma-4-e4b-it-mlx
rc="$(cat "$T/c3b.rc")"
if [ "$rc" != 0 ]; then pass "3b an unlisted explicit --model fails"; else bad "3b an unlisted explicit --model fails" "rc=0"; fi
if has "$T/c3b.out" "has no model gemma-4-e4b-it-mlx"; then pass "3b names the refused model"; else bad "3b names the refused model" "$(tail -2 "$T/c3b.out")"; fi
if [ ! -e "$H/.config" ] && [ ! -e "$H/.local/bin/claude-lms" ]; then
    pass "3b writes nothing"
else
    bad "3b writes nothing" "$(ls "$H/.config" "$H/.local/bin/claude-lms" 2>&1 | head -2)"
fi

# 3c. the other direction: the conf holds the hub catalog's id, the bundle's id is the only one listed
H="$T/c3c"; mk_cc_home "$H"
mkdir -p "$H/.config/claude-lms"
printf "CLAUDE_LMS_MODEL='google/gemma-4-e4b'\n" >"$H/.config/claude-lms/env"
chmod 600 "$H/.config/claude-lms/env"
printf '{"data":[{"id":"gemma-4-e4b-it-mlx"},{"id":"text-embedding-bge-m3"}]}' >"$CSTUB/v1/models"
run_cc c3c "$H"
rc="$(cat "$T/c3c.rc")"
if [ "$rc" = 0 ]; then pass "3c exits 0"; else bad "3c exits 0" "rc=$rc $(tail -3 "$T/c3c.out")"; fi
if grep -q "^CLAUDE_LMS_MODEL='gemma-4-e4b-it-mlx'\$" "$H/.config/claude-lms/env"; then
    pass "3c conf holds the alias this Mac lists"
else
    bad "3c conf holds the alias this Mac lists" "$(grep CLAUDE_LMS_MODEL "$H/.config/claude-lms/env")"
fi
if has "$T/c3c.out" "google/gemma-4-e4b is listed as gemma-4-e4b-it-mlx on this Mac's LM Studio: using gemma-4-e4b-it-mlx"; then
    pass "3c prints the swap note"
else
    bad "3c prints the swap note" "$(grep 'listed as' "$T/c3c.out" | head -1)"
fi

# 3d. a taken-over id that IS listed: kept as it is, no note
H="$T/c3d"; mk_cc_home "$H"
printf '{"data":[{"id":"gemma-4-e4b-it-mlx"},{"id":"text-embedding-bge-m3"}]}' >"$CSTUB/v1/models"
run_cc c3d "$H"
rc="$(cat "$T/c3d.rc")"
if [ "$rc" = 0 ] && grep -q "^CLAUDE_LMS_MODEL='gemma-4-e4b-it-mlx'\$" "$H/.config/claude-lms/env"; then
    pass "3d keeps a listed id"
else
    bad "3d keeps a listed id" "rc=$rc $(grep CLAUDE_LMS_MODEL "$H/.config/claude-lms/env" 2>/dev/null)"
fi
if hasnt "$T/c3d.out" "is listed as"; then pass "3d prints no swap note"; else bad "3d prints no swap note" "$(grep 'listed as' "$T/c3d.out" | head -1)"; fi

echo
echo "elapsed: ${SECONDS}s"
if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi
