#!/bin/bash
# Router-by-default acceptance test for the bundle installers (build Mac only; a human runs it).
# Nothing real is touched: install-all.sh runs against a stub bundle under a mktemp fake HOME, the
# claude step against a kit whose llm-router installer is a stub (no launchctl, env from
# env.example mode 600), and the VS Code add-on against a staged add-on folder with a dead router
# port. All secrets in test data are synthetic. Usage:
#   [CLAUDE_LMS_PY=<python with fastapi/httpx/uvicorn>] accept_router_default.sh [CLAUDE_BIN]
set -u
SECONDS=0
G="$(cd "$(dirname "$0")/.." && pwd)"
IA="$G/install-all.sh"
ICC="$G/install-claude-code.sh"
IVS="$G/vscode-addon/install-vscode.sh"
CB="${1:-$HOME/.local/bin/claude}"
PY="${CLAUDE_LMS_PY:-$HOME/.guardian-llm/venv/bin/python}"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-router-default.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "${T:?}"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }
has()  { local f="$1" s="$2"; grep -Fq -e "$s" "$f"; }
hasnt(){ local f="$1" s="$2"; ! grep -Fq -e "$s" "$f"; }

[ -x "$CB" ] || { echo "FAIL claude binary missing: $CB"; exit 1; }
"$PY" -I -c 'import fastapi, httpx, uvicorn' >/dev/null 2>&1 \
    || { echo "FAIL $PY cannot import fastapi/httpx/uvicorn"; exit 1; }
BINREAL="$(readlink -f "$CB")"
VER="$("$BINREAL" --version | awk '{print $1}')"

# ---- 1. install-all.sh: which router flags the claude step gets --------------------------------
CALLS="$T/calls.log"
export CALLS
stub() {
    local p="$1" n="$2"
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$n" >"$p"
    chmod 755 "$p"
}
mk_bundle() {
    local d="$1"
    mkdir -p "$d/wiki-layer" "$d/claude-code"
    cp "$IA" "$d/install-all.sh"
    printf 'app_name=LM Studio.app\napp_version=0.0.1\napp_dmg=\n' >"$d/MANIFEST.env"
    stub "$d/install.sh" install.sh
    stub "$d/wiki-layer/install-wiki.sh" install-wiki.sh
    stub "$d/claude-code/install-claude-code.sh" install-claude-code.sh
}
run_all() {
    local b="$1" o="$2" e="$3"; shift 3
    HOME="$T/home" bash "$b/install-all.sh" "$@" >"$o" 2>"$e"
}
mkdir -p "$T/home"
B="$T/bundle"
mk_bundle "$B"
cl_file="$T/claude-line.txt"
claude_line() { grep -m1 '^install-claude-code\.sh ' "$CALLS" >"$cl_file"; cat "$cl_file"; }

# (a) no router option at all: --router-load, never --with-router
: >"$CALLS"
run_all "$B" "$T/a1.out" "$T/a1.err" --dry-run --no-app
rc=$?
[ "$rc" = 0 ] && pass "1a default run exits 0" || bad "1a default run exits 0" "rc=$rc $(tail -2 "$T/a1.err")"
claude_line >/dev/null
has "$cl_file" "--router-load" && pass "1a default passes --router-load" || bad "1a default passes --router-load" "$(cat "$cl_file")"
hasnt "$cl_file" "--with-router" && pass "1a default passes no --with-router" || bad "1a default passes no --with-router" "$(cat "$cl_file")"

# (b) --no-router: no router flag at all
: >"$CALLS"
run_all "$B" "$T/a2.out" "$T/a2.err" --dry-run --no-app --no-router
rc=$?
[ "$rc" = 0 ] && pass "1b --no-router exits 0" || bad "1b --no-router exits 0" "rc=$rc $(tail -2 "$T/a2.err")"
claude_line >/dev/null
if has "$cl_file" "--router-load" || has "$cl_file" "--with-router"; then
    bad "1b --no-router passes no router flag" "$(cat "$cl_file")"
else
    pass "1b --no-router passes no router flag"
fi

# (c) --with-router: install only, no load
: >"$CALLS"
run_all "$B" "$T/a3.out" "$T/a3.err" --dry-run --no-app --with-router
rc=$?
[ "$rc" = 0 ] && pass "1c --with-router exits 0" || bad "1c --with-router exits 0" "rc=$rc $(tail -2 "$T/a3.err")"
claude_line >/dev/null
has "$cl_file" "--with-router" && pass "1c passes --with-router" || bad "1c passes --with-router" "$(cat "$cl_file")"
hasnt "$cl_file" "--router-load" && pass "1c passes no --router-load" || bad "1c passes no --router-load" "$(cat "$cl_file")"

# (d) the last router option wins: --no-router --router-load loads, --with-router --no-router does not
: >"$CALLS"
run_all "$B" "$T/a4.out" "$T/a4.err" --dry-run --no-app --no-router --router-load
rc=$?
[ "$rc" = 0 ] && pass "1d --no-router --router-load exits 0" || bad "1d --no-router --router-load exits 0" "rc=$rc $(tail -2 "$T/a4.err")"
claude_line >/dev/null
has "$cl_file" "--router-load" && pass "1d last wins: --router-load" || bad "1d last wins: --router-load" "$(cat "$cl_file")"
hasnt "$cl_file" "--with-router" && pass "1d no --with-router alongside" || bad "1d no --with-router alongside" "$(cat "$cl_file")"
: >"$CALLS"
run_all "$B" "$T/a5.out" "$T/a5.err" --dry-run --no-app --with-router --no-router
rc=$?
[ "$rc" = 0 ] && pass "1e --with-router --no-router exits 0" || bad "1e --with-router --no-router exits 0" "rc=$rc $(tail -2 "$T/a5.err")"
claude_line >/dev/null
if has "$cl_file" "--router-load" || has "$cl_file" "--with-router"; then
    bad "1e last wins: no router flag" "$(cat "$cl_file")"
else
    pass "1e last wins: no router flag"
fi

# (f) --spark-url/--spark-env reach the claude step untouched
: >"$CALLS"
run_all "$B" "$T/a6.out" "$T/a6.err" --dry-run --no-app --spark-url=http://10.9.9.9:8000 --spark-env=/nope/spark.env
rc=$?
[ "$rc" = 0 ] && pass "1f spark options run exits 0" || bad "1f spark options run exits 0" "rc=$rc $(tail -2 "$T/a6.err")"
claude_line >/dev/null
has "$cl_file" "--spark-url=http://10.9.9.9:8000" && pass "1f passes --spark-url" || bad "1f passes --spark-url" "$(cat "$cl_file")"
has "$cl_file" "--spark-env=/nope/spark.env" && pass "1f passes --spark-env" || bad "1f passes --spark-env" "$(cat "$cl_file")"

# (g) --help: lists the new options, stops before the closing === line
bash "$B/install-all.sh" --help >"$T/a7.out" 2>&1; rc=$?
[ "$rc" = 0 ] && pass "1g --help exits 0" || bad "1g --help exits 0" "rc=$rc"
has "$T/a7.out" "--no-router" && pass "1g --help lists --no-router" || bad "1g --help lists --no-router" "missing"
has "$T/a7.out" "--spark-env=FILE" && pass "1g --help lists --spark-env" || bad "1g --help lists --spark-env" "missing"
hasnt "$T/a7.out" "==============" && pass "1g --help stops before the === line" || bad "1g --help stops before the === line" "header range too long"
has "$T/a7.out" "openwebui-wiki-bundle-0.10.2" && pass "1g --help last line intact" || bad "1g --help last line intact" "$(tail -1 "$T/a7.out")"

# ---- 2. install-claude-code.sh: spark env, picker line, validation -----------------------------
mkkit() {
    local k="$1"; mkdir -p "$k" "$k/llm-router"
    cp "$ICC" "$G/claude-lms" "$k/"
    chmod 755 "$k/install-claude-code.sh" "$k/claude-lms"
    if [ -f "$T/kit/claude" ]; then cp -c "$T/kit/claude" "$k/claude"; else cp "$BINREAL" "$k/claude"; fi
    echo "$VER" > "$k/VERSION"
    for f in router.py spark-model env.example README.md; do cp "$G/llm-router/$f" "$k/llm-router/"; done
    # stub router installer (the real one would call launchctl): logs argv, creates the env from
    # env.example with mode 600 when missing, nothing else. A --dry-run call writes nothing —
    # same as the real installer, which only says "[dry-run] write" and changes nothing.
    cat >"$k/llm-router/install-llm-router.sh" <<'STUB'
#!/bin/bash
set -u
LOG="$HOME/.stub-router.log"
ENVF="$HOME/.config/llm-router/env"
printf 'call:%s\n' "$*" >>"$LOG"
case "$*" in *--dry-run*) exit 0 ;; esac
if [ ! -f "$ENVF" ]; then
    mkdir -p "$(dirname "$ENVF")"
    d="$(cd "$(dirname "$0")" && pwd)"
    ( umask 077; cp "$d/env.example" "$ENVF" )
fi
STUB
    chmod 755 "$k/llm-router/install-llm-router.sh" "$k/llm-router/spark-model"
}
mkhome() {
    local h="$1"; mkdir -p "$h/.local/share/claude/versions" "$h/.local/bin"
    cp -c "$T/kit/claude" "$h/.local/share/claude/versions/$VER"
    ln -s "$h/.local/share/claude/versions/$VER" "$h/.local/bin/claude"
}
inst() {
    local n="$1" h="$2"; shift 2
    HOME="$h" CLAUDE_LMS_PY="$PY" XDG_CONFIG_HOME="$h/.config" TMPDIR="$T/tmp" \
        "$T/kit/install-claude-code.sh" --model=test-model --lmstudio-url=http://127.0.0.1:9 --no-path --no-skills "$@" \
        > "$T/$n.out" 2>&1
    echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }
show() { sed 's/^/    /' "$T/$1.out" | tail -15; }
mkdir -p "$T/tmp"
mkkit "$T/kit"
RENV=".config/llm-router/env"
CENV=".config/claude-lms/env"

# (a) --with-router: picker line, default spark urls, 600, template SPARK_URLS activated
H="$T/c1"; mkhome "$H"
inst c1 "$H" --with-router
[ "$(rc c1)" = 0 ] && pass "2a exits 0" || { bad "2a exits 0" "rc=$(rc c1)"; show c1; }
grep -q "^CLAUDE_LMS_PICKER='spark-large qwen3-coder local-fast qwen3-instruct'\$" "$H/$CENV" && pass "2a adds the picker line" \
    || bad "2a adds the picker line" "$(grep PICKER "$H/$CENV" 2>&1)"
grep -q '^SPARK_URL=http://spark.local:8000$' "$H/$RENV" && pass "2a SPARK_URL default" \
    || bad "2a SPARK_URL default" "$(grep '^SPARK_URL' "$H/$RENV" 2>&1)"
grep -q '^SPARK_SWITCH_URL=http://spark.local:8010$' "$H/$RENV" && pass "2a SPARK_SWITCH_URL default" \
    || bad "2a SPARK_SWITCH_URL default" "$(grep '^SPARK_SWITCH_URL' "$H/$RENV" 2>&1)"
[ "$(stat -f %Lp "$H/$RENV" 2>/dev/null)" = 600 ] && pass "2a router env 600" \
    || bad "2a router env 600" "$(stat -f %Lp "$H/$RENV" 2>/dev/null)"
[ "$(grep -c '^SPARK_URLS=http://spark.local:8000,http://spark.local:8001$' "$H/$RENV" 2>/dev/null)" = 1 ] \
    && pass "2a SPARK_URLS default activated" \
    || bad "2a SPARK_URLS default activated" "grep -c=$(grep -c '^SPARK_URLS=' "$H/$RENV" 2>/dev/null)"
if grep -q '^#SPARK_URLS=' "$H/$RENV"; then bad "2a no commented SPARK_URLS left" "template line kept"; \
    else pass "2a no commented SPARK_URLS left"; fi
grep -q '^LOCAL_URL=http://127.0.0.1:9$' "$H/$RENV" && pass "2a LOCAL_URL rewritten" \
    || bad "2a LOCAL_URL rewritten" "$(grep '^LOCAL_URL' "$H/$RENV" 2>&1)"
[ "$(grep -c '^SPARK_API_KEY=$' "$H/$RENV" 2>/dev/null)" = 1 ] && pass "2a SPARK_API_KEY still empty" \
    || bad "2a SPARK_API_KEY still empty" "changed"

# (b) --spark-url: both URLs follow it
H="$T/c2"; mkhome "$H"
inst c2 "$H" --with-router --spark-url=http://10.9.9.9:8000
[ "$(rc c2)" = 0 ] && pass "2b exits 0" || { bad "2b exits 0" "rc=$(rc c2)"; show c2; }
grep -q '^SPARK_URL=http://10.9.9.9:8000$' "$H/$RENV" && pass "2b SPARK_URL" \
    || bad "2b SPARK_URL" "$(grep '^SPARK_URL' "$H/$RENV" 2>&1)"
grep -q '^SPARK_URLS=http://10.9.9.9:8000$' "$H/$RENV" && pass "2b SPARK_URLS" \
    || bad "2b SPARK_URLS" "$(grep '^SPARK_URLS' "$H/$RENV" 2>&1)"
grep -q '^SPARK_SWITCH_URL=http://10.9.9.9:8010$' "$H/$RENV" && pass "2b SPARK_SWITCH_URL" \
    || bad "2b SPARK_SWITCH_URL" "$(grep '^SPARK_SWITCH_URL' "$H/$RENV" 2>&1)"

# (b2) --spark-url with a comma list: SPARK_URL keeps the first entry, SPARK_URLS the whole list
H="$T/c2b"; mkhome "$H"
inst c2b "$H" --with-router --spark-url=http://10.9.9.9:8000,http://10.9.9.9:8001
[ "$(rc c2b)" = 0 ] && pass "2b2 exits 0" || { bad "2b2 exits 0" "rc=$(rc c2b)"; show c2b; }
grep -q '^SPARK_URL=http://10.9.9.9:8000$' "$H/$RENV" && pass "2b2 SPARK_URL first entry" \
    || bad "2b2 SPARK_URL first entry" "$(grep '^SPARK_URL' "$H/$RENV" 2>&1)"
grep -q '^SPARK_URLS=http://10.9.9.9:8000,http://10.9.9.9:8001$' "$H/$RENV" && pass "2b2 SPARK_URLS whole list" \
    || bad "2b2 SPARK_URLS whole list" "$(grep '^SPARK_URLS' "$H/$RENV" 2>&1)"
grep -q '^SPARK_SWITCH_URL=http://10.9.9.9:8010$' "$H/$RENV" && pass "2b2 SPARK_SWITCH_URL from the first entry" \
    || bad "2b2 SPARK_SWITCH_URL from the first entry" "$(grep '^SPARK_SWITCH_URL' "$H/$RENV" 2>&1)"

# (c) --spark-env: aliases land in the router env, values never in the output, other keys named
printf 'VLLM_API_KEY=test-key-123\nSWITCH_TOKEN=test-tok-456\nOTHER=x\n' > "$T/spark.env"
chmod 600 "$T/spark.env"
H="$T/c3"; mkhome "$H"
inst c3 "$H" --with-router --spark-env="$T/spark.env"
[ "$(rc c3)" = 0 ] && pass "2c exits 0" || { bad "2c exits 0" "rc=$(rc c3)"; show c3; }
grep -q '^SPARK_API_KEY=test-key-123$' "$H/$RENV" && pass "2c SPARK_API_KEY from the file" \
    || bad "2c SPARK_API_KEY from the file" "$(grep -c '^SPARK_API_KEY=' "$H/$RENV" 2>&1)"
grep -q '^SPARK_SWITCH_TOKEN=test-tok-456$' "$H/$RENV" && pass "2c SPARK_SWITCH_TOKEN from the file" \
    || bad "2c SPARK_SWITCH_TOKEN from the file" "missing"
c3out="$(cat "$T/c3.out")"
case "$c3out" in *test-key-123*) bad "2c never prints the key" "value leaked" ;; *) pass "2c never prints the key" ;; esac
case "$c3out" in *test-tok-456*) bad "2c never prints the token" "value leaked" ;; *) pass "2c never prints the token" ;; esac
case "$c3out" in *ignored*keys:*OTHER*|*ignored*keys*OTHER*) pass "2c names the ignored key" ;; *) bad "2c names the ignored key" "no ignored-keys line" ;; esac
[ "$(stat -f %Lp "$H/$RENV" 2>/dev/null)" = 600 ] && pass "2c router env 600" \
    || bad "2c router env 600" "$(stat -f %Lp "$H/$RENV" 2>/dev/null)"

# (d) existing env: untouched without spark options; the user's picker line survives
H="$T/c4"; mkhome "$H"
mkdir -p "$H/.config/llm-router" "$H/.config/claude-lms"
printf 'LLM_ROUTER_PORT=1241\nSPARK_API_KEY=canary-KEEP\n' > "$H/$RENV"
chmod 600 "$H/$RENV"
cp "$H/$RENV" "$T/c4.orig"
printf "CLAUDE_LMS_PICKER='qwen3-coder'\n" > "$H/$CENV"
chmod 600 "$H/$CENV"
inst c4 "$H" --with-router
[ "$(rc c4)" = 0 ] && pass "2d exits 0" || { bad "2d exits 0" "rc=$(rc c4)"; show c4; }
cmp -s "$T/c4.orig" "$H/$RENV" && pass "2d existing router env untouched" \
    || bad "2d existing router env untouched" "changed"
[ "$(grep -c "^CLAUDE_LMS_PICKER='qwen3-coder'\$" "$H/$CENV")" = 1 ] && pass "2d user picker kept" \
    || bad "2d user picker kept" "$(grep PICKER "$H/$CENV" 2>&1)"

# (d2) existing env + --spark-url: the three URL keys rewritten, the user's key untouched
H="$T/c4b"; mkhome "$H"
mkdir -p "$H/.config/llm-router"
printf 'SPARK_URL=http://old:8000\nSPARK_API_KEY=keep-me\n' > "$H/$RENV"
chmod 600 "$H/$RENV"
inst c4b "$H" --with-router --spark-url=http://10.2.2.2:8000,http://10.2.2.2:8001
[ "$(rc c4b)" = 0 ] && pass "2d2 exits 0" || { bad "2d2 exits 0" "rc=$(rc c4b)"; show c4b; }
grep -q '^SPARK_URL=http://10.2.2.2:8000$' "$H/$RENV" && pass "2d2 SPARK_URL updated" \
    || bad "2d2 SPARK_URL updated" "$(grep '^SPARK_URL' "$H/$RENV" 2>&1)"
grep -q '^SPARK_URLS=http://10.2.2.2:8000,http://10.2.2.2:8001$' "$H/$RENV" && pass "2d2 SPARK_URLS added" \
    || bad "2d2 SPARK_URLS added" "$(grep '^SPARK_URLS' "$H/$RENV" 2>&1)"
grep -q '^SPARK_SWITCH_URL=http://10.2.2.2:8010$' "$H/$RENV" && pass "2d2 SPARK_SWITCH_URL updated" \
    || bad "2d2 SPARK_SWITCH_URL updated" "$(grep '^SPARK_SWITCH_URL' "$H/$RENV" 2>&1)"
grep -q '^SPARK_API_KEY=keep-me$' "$H/$RENV" && pass "2d2 SPARK_API_KEY kept" \
    || bad "2d2 SPARK_API_KEY kept" "$(grep '^SPARK_API_KEY' "$H/$RENV" 2>&1)"
c4bout="$(cat "$T/c4b.out")"
case "$c4bout" in *keep-me*) bad "2d2 never prints the key" "value leaked" ;; *) pass "2d2 never prints the key" ;; esac

# (e) bad --spark-url / missing --spark-env: refused before anything is written
for case in "url-ftp:--spark-url=ftp://x:8000" "url-quote:--spark-url=http://a'b" \
    "url-comma-trail:--spark-url=http://a:8000," "url-comma-double:--spark-url=http://a:8000,,http://a:8001" \
    "url-second-bad:--spark-url=http://a:8000,ftp://a:8001" "env-missing:--spark-env=$T/missing.env"; do
    n="c5-${case%%:*}"; opt="${case#*:}"
    H="$T/$n"; mkhome "$H"
    inst "$n" "$H" --with-router "$opt"
    if [ "$(rc "$n")" != 0 ]; then pass "2e $n refused"; else bad "2e $n refused" "rc=0"; fi
    [ ! -e "$H/.config" ] && [ ! -e "$H/.local/bin/claude-lms" ] && [ ! -e "$H/.guardian-llm" ] \
        && pass "2e $n writes nothing" || bad "2e $n writes nothing" "$(find "$H" -not -path "$H/.local*" -not -path "$H" | head -3)"
done

# (f) --dry-run: nothing written, no secret values, urls and key names previewed
H="$T/c6"; mkhome "$H"
inst c6 "$H" --with-router --spark-env="$T/spark.env" --dry-run
[ "$(rc c6)" = 0 ] && pass "2f dry-run exits 0" || { bad "2f dry-run exits 0" "rc=$(rc c6)"; show c6; }
[ ! -e "$H/.config" ] && [ ! -e "$H/.guardian-llm" ] && pass "2f dry-run writes nothing" \
    || bad "2f dry-run writes nothing" "$(find "$H" -not -path "$H/.local*" -not -path "$H" | head -3)"
c6out="$(cat "$T/c6.out")"
case "$c6out" in *test-key-123*) bad "2f dry-run never prints the key" "value leaked" ;; *) pass "2f dry-run never prints the key" ;; esac
case "$c6out" in *test-tok-456*) bad "2f dry-run never prints the token" "value leaked" ;; *) pass "2f dry-run never prints the token" ;; esac
case "$c6out" in *SPARK_URL=http://spark.local:8000*) pass "2f dry-run previews SPARK_URL" ;; *) bad "2f dry-run previews SPARK_URL" "no url" ;; esac
case "$c6out" in *SPARK_URLS=http://spark.local:8000,http://spark.local:8001*) pass "2f dry-run previews SPARK_URLS" ;; *) bad "2f dry-run previews SPARK_URLS" "no url list" ;; esac
case "$c6out" in *SPARK_API_KEY*from*) pass "2f dry-run previews the key name" ;; *) bad "2f dry-run previews the key name" "no key name" ;; esac

# (g) without --with-router: the spark options are warned about and ignored, exit 0
H="$T/c7"; mkhome "$H"
inst c7 "$H" --spark-url=http://10.1.1.1:8000 --spark-env="$T/spark.env"
[ "$(rc c7)" = 0 ] && pass "2g exits 0 without the router" || { bad "2g exits 0 without the router" "rc=$(rc c7)"; show c7; }
grep -q 'llm-router: skipped' "$T/c7.out" && pass "2g router still skipped" || bad "2g router still skipped" "no skip line"
grep -qi 'ignored' "$T/c7.out" && pass "2g warns the options are ignored" || bad "2g warns the options are ignored" "no warning"
[ ! -e "$H/.config/llm-router" ] && pass "2g no router env" || bad "2g no router env" "exists"

# (h) install-claude-code.sh --help: the new options listed, nothing cut off, no === line
bash "$ICC" --help >"$T/ch.out" 2>&1; rc=$?
[ "$rc" = 0 ] && pass "2h claude help exits 0" || bad "2h claude help exits 0" "rc=$rc"
has "$T/ch.out" "--spark-url=URL" && pass "2h claude help lists --spark-url" || bad "2h claude help lists --spark-url" "missing"
has "$T/ch.out" "--spark-env=FILE" && pass "2h claude help lists --spark-env" || bad "2h claude help lists --spark-env" "missing"
has "$T/ch.out" "--dry-run" && pass "2h claude help not cut short" || bad "2h claude help not cut short" "$(tail -1 "$T/ch.out")"
hasnt "$T/ch.out" "==============" && pass "2h claude help stops before the === line" \
    || bad "2h claude help stops before the === line" "range too long"

# ---- 3. install-vscode.sh: the picker line drives the settings ---------------------------------
make_stage() {
    local d="$1"
    mkdir -p "$d"
    cp "$IVS" "$d/install-vscode.sh"
    chmod 755 "$d/install-vscode.sh"
    cat >"$d/MANIFEST.env" <<'EOF'
vscode_version=1.99.2
vscode_team=UBF8T346G9
foam_version=0.30.2
claude_code_ext_version=2.0.0
claude_team=HQXXXXXXXX
app_dmg=app.dmg
foam_vsix=foam.vsix
claude_vsix=claude.vsix
EOF
    ( cd "$d" && shasum -a 256 install-vscode.sh MANIFEST.env >SHA256SUMS )
}
env_eq() {  # $1 = settings file, $2 = env name, $3 = expected value
    local got
    if [ ! -f "$1" ]; then bad "3 $2: no settings file" "missing"; return 0; fi
    got="$(sed -n "s/.*{\"name\": \"$2\", \"value\": \"\([^\"]*\)\"}.*/\1/p" "$1" | head -1)"
    if [ "${got}" = "$3" ]; then pass "3 $2 = $3"; else bad "3 $2 = $3" "got '${got}'"; fi
}
S="$T/vscode-stage"; make_stage "$S"
mkdir -p "$T/vxdg/claude-lms"
cat >"$T/vxdg/claude-lms/env" <<'EOF'
CLAUDE_LMS_ROUTER='http://127.0.0.1:9'
CLAUDE_LMS_PICKER='spark-large'
CLAUDE_LMS_TOKEN='test-tok-none'
EOF
XDG_CONFIG_HOME="$T/vxdg" "$S/install-vscode.sh" --no-app --no-extensions --no-wiki \
    --user-data-dir="$T/vud" >"$T/vs.out" 2>&1
rc=$?
[ "$rc" = 0 ] && pass "3 router picker run exits 0" || bad "3 router picker run exits 0" "rc=$rc $(tail -3 "$T/vs.out")"
VJ="$T/vud/User/settings.json"
env_eq "$VJ" ANTHROPIC_BASE_URL "http://127.0.0.1:9"
env_eq "$VJ" ANTHROPIC_MODEL "spark-large"
env_eq "$VJ" ANTHROPIC_DEFAULT_OPUS_MODEL "spark-large"
env_eq "$VJ" ANTHROPIC_DEFAULT_SONNET_MODEL "spark-large"
env_eq "$VJ" ANTHROPIC_DEFAULT_FABLE_MODEL "spark-large"
env_eq "$VJ" ANTHROPIC_DEFAULT_HAIKU_MODEL "local-fast"
env_eq "$VJ" ANTHROPIC_SMALL_FAST_MODEL "local-fast"
env_eq "$VJ" CLAUDE_CODE_SUBAGENT_MODEL "spark-large"
hasnt "$VJ" "test-tok-none" && pass "3 token never copied" || bad "3 token never copied" "leaked"

# direct-mode settings kept, but warned about when this run goes through the router
mkdir -p "$T/vud2/User"
printf '{\n  "claudeCode.environmentVariables": [\n    {"name": "ANTHROPIC_BASE_URL", "value": "http://127.0.0.1:1234"}\n  ]\n}\n' >"$T/vud2/User/settings.json"
cp "$T/vud2/User/settings.json" "$T/vud2.before"
XDG_CONFIG_HOME="$T/vxdg" "$S/install-vscode.sh" --no-app --no-extensions --no-wiki \
    --user-data-dir="$T/vud2" >"$T/vs2.out" 2>&1
rc=$?
[ "$rc" = 0 ] && pass "3 direct-mode rerun exits 0" || bad "3 direct-mode rerun exits 0" "rc=$rc $(tail -3 "$T/vs2.out")"
grep -q 'LM Studio direct mode' "$T/vs2.out" && pass "3 warns about the direct-mode settings" \
    || bad "3 warns about the direct-mode settings" "no warn"
cmp -s "$T/vud2.before" "$T/vud2/User/settings.json" && pass "3 settings.json still untouched" \
    || bad "3 settings.json still untouched" "changed"
[ -s "$T/vud2/User/settings.vscode-addon.jsonc" ] && pass "3 side file written" || bad "3 side file written" "missing"

# ---- 4. syntax --------------------------------------------------------------------------------
for f in "$IA" "$ICC" "$IVS" "$G/install-llm-wiki.sh" "$0"; do
    /bin/bash -n "$f" && pass "bash -n $(basename "$f")" || bad "bash -n $(basename "$f")" "does not parse"
done

echo
echo "elapsed: ${SECONDS}s"
if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi
