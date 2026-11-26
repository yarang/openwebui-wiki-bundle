#!/bin/bash
# ==============================================================================
# Model picker test for guardian/vscode-addon/install-vscode.sh
#
# Runs the installer against a fake add-on folder (step 0 passes, every other
# step is skipped) and a mock router on 127.0.0.1 that serves /v1/models, so
# only step 4 (user settings) really runs. python3 is used by THIS test only,
# never by the installer. No network beyond 127.0.0.1, no dmg, no real VS Code.
# ==============================================================================

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO}/guardian/vscode-addon/install-vscode.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/vscode-picker-test.XXXXXX")"
SRV_PID=""
SRV2_PID=""
SECRET="SECRET-TOKEN-SHOULD-NOT-APPEAR"

fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

cleanup() {
    for pid in "${SRV_PID}" "${SRV2_PID}"; do
        if [ -n "${pid}" ]; then
            kill "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true   # keeps the job-terminated notice out of the output
        fi
    done
    rm -rf "${T:?}"
}
trap cleanup EXIT

# ---- fake add-on stage -----------------------------------------------------------------------
# MANIFEST.env carries every key step 0 requires; SHA256SUMS seals the files in the stage folder.
make_stage() {  # $1 = stage dir, $2 = install script to copy into it
    local dir="$1" script="$2"
    mkdir -p "${dir}"
    cp "${script}" "${dir}/install-vscode.sh"
    chmod +x "${dir}/install-vscode.sh"
    cat >"${dir}/MANIFEST.env" <<'EOF'
vscode_version=1.99.2
vscode_team=UBF8T346G9
foam_version=0.30.2
claude_code_ext_version=2.0.0
claude_team=HQXXXXXXXX
app_dmg=app.dmg
foam_vsix=foam.vsix
claude_vsix=claude.vsix
EOF
    (cd "${dir}" && shasum -a 256 install-vscode.sh MANIFEST.env >SHA256SUMS)
}

# ---- mock router ------------------------------------------------------------------------------
mkdir -p "${T}/www/v1"
cat >"${T}/www/v1/models" <<'EOF'
{"object":"list","data":[{"id":"spark-large","route":"spark"},{"id":"local-fast","route":"local"},{"id":"qwen3-coder","route":"spark"},{"id":"gpt-oss-120b","route":"spark (not loaded)"}]}
EOF
PORT=""
for p in 18081 18082 18083 18084 18085; do
    if ! (echo >"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then PORT="${p}"; break; fi
done
[ -n "${PORT}" ] || { echo "no free port in 18xxx for the mock router"; exit 1; }
python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${T}/www" >/dev/null 2>&1 &
SRV_PID=$!
ROUTER="http://127.0.0.1:${PORT}"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if curl -fsS -m 2 "${ROUTER}/v1/models" >/dev/null 2>&1; then break; fi
    sleep 0.2
done
curl -fsS -m 2 "${ROUTER}/v1/models" >/dev/null || { echo "the mock router never answered"; exit 1; }
CLOSED_PORT=""
for p in 18091 18092 18093 18094 18095; do
    if (echo >"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then continue; fi
    CLOSED_PORT="${p}"
    break
done
[ -n "${CLOSED_PORT}" ] || { echo "no closed port in 18xxx for case h"; exit 1; }

# ---- second mock router: serves ids a hostile backend could return ----------------------------
# "x'; printf PWNED; : '" is a shell-injection id for the CLAUDE_LMS_PICKER hint (case m) and
# "model\nname" carries a JSON-escaped newline that a line-oriented check would miss (case n).
# Both must be skipped before they reach any output.
PORT2=""
for p in 18086 18087 18088 18089 18090; do
    if ! (echo >"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then PORT2="${p}"; break; fi
done
[ -n "${PORT2}" ] || { echo "no free port in 18xxx for the second mock router"; exit 1; }
mkdir -p "${T}/www2/v1"
cat >"${T}/www2/v1/models" <<'EOF'
{"object":"list","data":[{"id":"x'; printf PWNED; : '","route":"spark"},{"id":"model\nname","route":"local"},{"id":"good-model","route":"spark"},{"id":"spark-large","route":"local"}]}
EOF
python3 -m http.server "${PORT2}" --bind 127.0.0.1 --directory "${T}/www2" >/dev/null 2>&1 &
SRV2_PID=$!
ROUTER2="http://127.0.0.1:${PORT2}"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if curl -fsS -m 2 "${ROUTER2}/v1/models" >/dev/null 2>&1; then break; fi
    sleep 0.2
done
curl -fsS -m 2 "${ROUTER2}/v1/models" >/dev/null || { echo "the second mock router never answered"; exit 1; }

# ---- helpers ----------------------------------------------------------------------------------
write_env() {  # $1 = xdg dir; the env body comes in on stdin (shell syntax)
    mkdir -p "$1/claude-lms"
    cat >"$1/claude-lms/env"
}

run_installer() {  # $1 = stage, $2 = user-data dir, $3 = xdg dir; remaining args go to the installer
    local stage="$1" ud="$2" xdg="$3"
    shift 3
    XDG_CONFIG_HOME="${xdg}" "${stage}/install-vscode.sh" \
        --no-app --no-extensions --no-wiki --user-data-dir="${ud}" "$@"
}

env_eq() {  # $1 = settings file, $2 = env name, $3 = expected value
    local got
    if [ ! -f "$1" ]; then fail "$2: no settings file"; return 0; fi
    got="$(sed -n "s/.*{\"name\": \"$2\", \"value\": \"\([^\"]*\)\"}.*/\1/p" "$1" | head -1)"
    if [ "${got}" = "$3" ]; then pass "$2 = $3"
    else fail "$2 = '$got', expected '$3'"; fi
}

has_env() {  # $1 = settings file, $2 = env name that must be present
    if [ ! -f "$1" ]; then fail "$2: no settings file"; return 0; fi
    if sed -n "s/.*{\"name\": \"$2\", \"value\": \"[^\"]*\"}.*/&/p" "$1" | grep -q .; then
        pass "$2 present"
    else
        fail "$2 missing"
    fi
}

no_env() {  # $1 = settings file, $2 = env name that must NOT be present
    if [ ! -f "$1" ]; then fail "$2: no settings file"; return 0; fi
    if sed -n "s/.*{\"name\": \"$2\", \"value\": \"[^\"]*\"}.*/&/p" "$1" | grep -q .; then
        fail "$2 must not be present"
    else
        pass "$2 absent"
    fi
}

expect_grep() {  # $1 = pattern, $2 = file, $3 = message when found, $4 = message when not
    if grep -q "$1" "$2"; then pass "$3"; else fail "$4"; fi
}

check() {  # $1 = message when the test succeeds, $2 = message when it fails, $3+ = the test command
    local ok="$1" bad="$2"
    shift 2
    if "$@"; then pass "${ok}"; else fail "${bad}"; fi
}

# ---- case a: no picks is byte-for-byte the original behaviour ---------------------------------
make_stage "${T}/stage-new" "${SRC}"
git -C "${REPO}" show HEAD:guardian/vscode-addon/install-vscode.sh >"${T}/orig.sh"
make_stage "${T}/stage-orig" "${T}/orig.sh"

write_env "${T}/xdg-a" <<EOF
CLAUDE_LMS_ROUTER='${ROUTER}'
CLAUDE_LMS_TOKEN='${SECRET}'
EOF
run_installer "${T}/stage-orig" "${T}/ud-a-orig" "${T}/xdg-a" </dev/null \
    >"${T}/out-a-orig.log" 2>&1
run_installer "${T}/stage-new" "${T}/ud-a" "${T}/xdg-a" </dev/null \
    >"${T}/out-a.log" 2>&1
if cmp -s "${T}/ud-a-orig/User/settings.json" "${T}/ud-a/User/settings.json"; then
    pass "a: no picks matches the original settings byte-for-byte"
else
    fail "a: settings differ from the original run"
fi
cp "${T}/ud-a/User/settings.json" "${T}/baseline.json"

# ---- case b: interactive pick 3 1 2 4 ---------------------------------------------------------
printf '3 1 2 4\n' | run_installer "${T}/stage-new" "${T}/ud-b" "${T}/xdg-a" \
    --pick-models >"${T}/out-b.log" 2>&1
s="${T}/ud-b/User/settings.json"
[ -f "${s}" ] || fail "b: no settings.json written"
env_eq "${s}" ANTHROPIC_DEFAULT_OPUS_MODEL qwen3-coder
env_eq "${s}" ANTHROPIC_DEFAULT_SONNET_MODEL spark-large
env_eq "${s}" ANTHROPIC_DEFAULT_HAIKU_MODEL local-fast
env_eq "${s}" ANTHROPIC_DEFAULT_FABLE_MODEL gpt-oss-120b
env_eq "${s}" ANTHROPIC_DEFAULT_FABLE_MODEL_NAME gpt-oss-120b
env_eq "${s}" ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION "Spark (not loaded)"
has_env "${s}" ANTHROPIC_DEFAULT_OPUS_MODEL_NAME
has_env "${s}" ANTHROPIC_DEFAULT_SONNET_MODEL_NAME
has_env "${s}" ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME
no_env "${s}" ANTHROPIC_CUSTOM_MODEL_OPTION
no_env "${s}" ANTHROPIC_CUSTOM_MODEL_OPTION_NAME
env_eq "${s}" CLAUDE_CODE_SUBAGENT_MODEL spark-large
env_eq "${s}" ANTHROPIC_SMALL_FAST_MODEL local-fast
expect_grep "picker: opus=qwen3-coder sonnet=spark-large haiku=local-fast fable=gpt-oss-120b" \
    "${T}/out-b.log" "b: picker note ends with fable=gpt-oss-120b" "b: picker note has no fable slot"
expect_grep "gpt-oss-120b is not loaded on the Spark" "${T}/out-b.log" \
    "b: not-loaded warning for gpt-oss-120b" "b: no not-loaded warning"
expect_grep "CLAUDE_LMS_PICKER='qwen3-coder spark-large local-fast gpt-oss-120b'" "${T}/out-b.log" \
    "b: CLAUDE_LMS_PICKER hint in the output" "b: no CLAUDE_LMS_PICKER hint"
if [ "$(stat -f '%Lp' "${s}")" = "600" ]; then
    pass "b: settings.json mode 600"
else
    fail "b: settings.json mode is $(stat -f '%Lp' "${s}"), expected 600"
fi

# ---- case c: three invalid answers give up ----------------------------------------------------
if printf '9\n1,1\nx\n' | run_installer "${T}/stage-new" "${T}/ud-c" "${T}/xdg-a" \
    --pick-models >"${T}/out-c.log" 2>&1; then
    fail "c: installer exited 0, expected non-zero"
else
    pass "c: gave up after 3 attempts (non-zero exit)"
fi
check "c: no settings.json written" "c: settings.json was written" \
    test ! -f "${T}/ud-c/User/settings.json"

# ---- case d: an empty answer keeps the defaults -----------------------------------------------
printf '\n' | run_installer "${T}/stage-new" "${T}/ud-d" "${T}/xdg-a" \
    --pick-models >"${T}/out-d.log" 2>&1
if cmp -s "${T}/baseline.json" "${T}/ud-d/User/settings.json"; then
    pass "d: empty pick keeps the default settings"
else
    fail "d: settings differ from the baseline"
fi

# ---- case e: CLAUDE_LMS_PICKER in the env file, no flag ----------------------------------------
write_env "${T}/xdg-e" <<EOF
CLAUDE_LMS_ROUTER='${ROUTER}'
CLAUDE_LMS_PICKER='qwen3-coder'
CLAUDE_LMS_TOKEN='${SECRET}'
EOF
run_installer "${T}/stage-new" "${T}/ud-e" "${T}/xdg-e" </dev/null >"${T}/out-e.log" 2>&1
s="${T}/ud-e/User/settings.json"
[ -f "${s}" ] || fail "e: no settings.json written"
env_eq "${s}" ANTHROPIC_DEFAULT_OPUS_MODEL qwen3-coder
has_env "${s}" ANTHROPIC_DEFAULT_OPUS_MODEL_NAME
env_eq "${s}" ANTHROPIC_DEFAULT_SONNET_MODEL spark-large
env_eq "${s}" ANTHROPIC_DEFAULT_HAIKU_MODEL local-fast
env_eq "${s}" ANTHROPIC_DEFAULT_FABLE_MODEL qwen3-coder
env_eq "${s}" ANTHROPIC_DEFAULT_FABLE_MODEL_NAME qwen3-coder
env_eq "${s}" ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION "Spark"
no_env "${s}" ANTHROPIC_DEFAULT_SONNET_MODEL_NAME
no_env "${s}" ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME
no_env "${s}" ANTHROPIC_CUSTOM_MODEL_OPTION
expect_grep "fable=qwen3-coder" "${T}/out-e.log" \
    "e: picker note ends with fable=qwen3-coder" "e: picker note has no fable slot"

# ---- case f: a CLAUDE_LMS_PICKER value with a bad id is ignored ---------------------------------
write_env "${T}/xdg-f" <<EOF
CLAUDE_LMS_ROUTER='${ROUTER}'
CLAUDE_LMS_PICKER='bad"id'
CLAUDE_LMS_TOKEN='${SECRET}'
EOF
run_installer "${T}/stage-new" "${T}/ud-f" "${T}/xdg-f" </dev/null >"${T}/out-f.log" 2>&1
if cmp -s "${T}/baseline.json" "${T}/ud-f/User/settings.json"; then
    pass "f: bad CLAUDE_LMS_PICKER ignored, settings match the baseline"
else
    fail "f: settings differ from the baseline"
fi
expect_grep "unsupported characters" "${T}/out-f.log" \
    "f: the bad id was warned about" "f: no warning for the bad id"

# ---- case g: --pick-models in direct mode is ignored -------------------------------------------
write_env "${T}/xdg-g" <<EOF
CLAUDE_LMS_MODEL='test-model'
CLAUDE_LMS_TOKEN='${SECRET}'
EOF
if run_installer "${T}/stage-new" "${T}/ud-g" "${T}/xdg-g" --pick-models \
    </dev/null >"${T}/out-g.log" 2>&1; then
    pass "g: exit 0"
else
    fail "g: installer exited non-zero"
fi
expect_grep "model picking needs router mode" "${T}/out-g.log" \
    "g: router-mode warning printed" "g: no router-mode warning"
no_env "${T}/ud-g/User/settings.json" ANTHROPIC_DEFAULT_OPUS_MODEL_NAME

# ---- case h: unreachable router with --pick-models is fatal ------------------------------------
write_env "${T}/xdg-h" <<EOF
CLAUDE_LMS_ROUTER='http://127.0.0.1:${CLOSED_PORT}'
CLAUDE_LMS_TOKEN='${SECRET}'
EOF
if run_installer "${T}/stage-new" "${T}/ud-h" "${T}/xdg-h" --pick-models \
    </dev/null >"${T}/out-h.log" 2>&1; then
    fail "h: installer exited 0, expected non-zero"
else
    pass "h: unreachable router failed the run"
fi
check "h: no settings.json written" "h: settings.json was written" \
    test ! -f "${T}/ud-h/User/settings.json"

# ---- case i: --dry-run --pick-models writes nothing --------------------------------------------
if printf '1\n' | run_installer "${T}/stage-new" "${T}/ud-i" "${T}/xdg-a" \
    --dry-run --pick-models >"${T}/out-i.log" 2>&1; then
    pass "i: dry run exited 0"
else
    fail "i: dry run exited non-zero"
fi
check "i: no user-data dir created" "i: user-data dir was created" test ! -d "${T}/ud-i"

# ---- case j: two picks keep the chosen sonnet; the fable slot repeats the first pick ------------
printf '4 3\n' | run_installer "${T}/stage-new" "${T}/ud-j" "${T}/xdg-a" \
    --pick-models >"${T}/out-j.log" 2>&1
s="${T}/ud-j/User/settings.json"
[ -f "${s}" ] || fail "j: no settings.json written"
env_eq "${s}" ANTHROPIC_DEFAULT_OPUS_MODEL gpt-oss-120b
env_eq "${s}" ANTHROPIC_DEFAULT_OPUS_MODEL_NAME gpt-oss-120b
env_eq "${s}" ANTHROPIC_DEFAULT_SONNET_MODEL qwen3-coder
env_eq "${s}" ANTHROPIC_DEFAULT_SONNET_MODEL_NAME qwen3-coder
env_eq "${s}" ANTHROPIC_DEFAULT_HAIKU_MODEL local-fast
env_eq "${s}" ANTHROPIC_DEFAULT_FABLE_MODEL gpt-oss-120b
env_eq "${s}" ANTHROPIC_DEFAULT_FABLE_MODEL_NAME gpt-oss-120b
no_env "${s}" ANTHROPIC_CUSTOM_MODEL_OPTION
expect_grep "sonnet=qwen3-coder haiku=local-fast (default) fable=gpt-oss-120b" "${T}/out-j.log" \
    "j: picker note ends with fable=gpt-oss-120b" "j: picker note has no fable slot"

# ---- case k: a glob character in CLAUDE_LMS_PICKER is ignored, never expanded --------------------
write_env "${T}/xdg-k" <<EOF
CLAUDE_LMS_ROUTER='${ROUTER}'
CLAUDE_LMS_PICKER='*'
CLAUDE_LMS_TOKEN='${SECRET}'
EOF
run_installer "${T}/stage-new" "${T}/ud-k" "${T}/xdg-k" </dev/null >"${T}/out-k.log" 2>&1
if cmp -s "${T}/baseline.json" "${T}/ud-k/User/settings.json"; then
    pass "k: '*' in CLAUDE_LMS_PICKER ignored, settings match the baseline"
else
    fail "k: '*' in CLAUDE_LMS_PICKER was expanded, settings differ from the baseline"
fi
expect_grep "unsupported characters" "${T}/out-k.log" \
    "k: the wildcard value was warned about" "k: no warning for the wildcard value"

# ---- case l: the client token never reaches any settings file ----------------------------------
if grep -rq "${SECRET}" "${T}"/ud*/User/settings* 2>/dev/null; then
    fail "l: the token leaked into a settings file"
else
    pass "l: the token appears in no settings file"
fi

# ---- case m: a hostile router id with shell metacharacters is skipped, never printed -----------
write_env "${T}/xdg-m" <<EOF
CLAUDE_LMS_ROUTER='${ROUTER2}'
CLAUDE_LMS_TOKEN='${SECRET}'
EOF
if printf '1\n' | run_installer "${T}/stage-new" "${T}/ud-m" "${T}/xdg-m" \
    --pick-models >"${T}/out-m.log" 2>&1; then
    pass "m: exit 0 with the hostile router"
else
    fail "m: installer exited non-zero"
fi
if grep -q 'PWNED' "${T}/out-m.log"; then
    fail "m: the hostile id reached the output (PWNED was printed)"
else
    pass "m: PWNED appears nowhere in the output"
fi
skipped="$(grep -c 'skipping model id with unsupported characters' "${T}/out-m.log" || true)"
if [ "${skipped}" = "2" ]; then
    pass "m: both bad router ids were skipped (never echoed)"
else
    fail "m: expected 2 skip warnings, got ${skipped}"
fi
s="${T}/ud-m/User/settings.json"
[ -f "${s}" ] || fail "m: no settings.json written"
env_eq "${s}" ANTHROPIC_DEFAULT_OPUS_MODEL good-model
hint="$(sed -n "s/.*: \(CLAUDE_LMS_PICKER='[^']*'\)\$/\1/p" "${T}/out-m.log" | head -1)"
if [ -n "${hint}" ]; then
    got="$(bash -c "${hint}" 2>&1 || true)"
    if [ -z "${got}" ]; then
        pass "m: the hint line is a clean assignment (bash -c prints nothing)"
    else
        fail "m: running the hint printed: ${got}"
    fi
else
    fail "m: no CLAUDE_LMS_PICKER hint in the output"
fi

# ---- case n: a router id with a JSON-escaped newline is skipped; settings stay valid JSON ------
if printf '2\n' | run_installer "${T}/stage-new" "${T}/ud-n" "${T}/xdg-m" \
    --pick-models >"${T}/out-n.log" 2>&1; then
    pass "n: exit 0"
else
    fail "n: installer exited non-zero"
fi
rows="$(grep -c '^  [0-9]) ' "${T}/out-n.log" || true)"
if [ "${rows}" = "2" ]; then
    pass "n: only the 2 usable ids are in the menu"
else
    fail "n: menu has ${rows} rows, expected 2 (the newline id is in it)"
fi
s="${T}/ud-n/User/settings.json"
[ -f "${s}" ] || fail "n: no settings.json written"
if python3 -m json.tool "${s}" >/dev/null 2>&1; then
    pass "n: settings.json is valid JSON"
else
    fail "n: settings.json is not valid JSON"
fi
env_eq "${s}" ANTHROPIC_DEFAULT_OPUS_MODEL spark-large

# ---- case o: EOF is not an empty answer --------------------------------------------------------
# o1: an invalid answer and then EOF must fail, not fall through to the defaults.
if printf '9\n' | run_installer "${T}/stage-new" "${T}/ud-o1" "${T}/xdg-a" \
    --pick-models >"${T}/out-o1.log" 2>&1; then
    fail "o1: invalid answer then EOF exited 0, expected non-zero"
else
    pass "o1: invalid answer then EOF failed the run"
fi
check "o1: no settings.json written" "o1: settings.json was written" \
    test ! -f "${T}/ud-o1/User/settings.json"
# o2: EOF with nothing typed at all must also fail.
if printf '' | run_installer "${T}/stage-new" "${T}/ud-o2" "${T}/xdg-a" \
    --pick-models >"${T}/out-o2.log" 2>&1; then
    fail "o2: immediate EOF exited 0, expected non-zero"
else
    pass "o2: immediate EOF failed the run"
fi
check "o2: no settings.json written" "o2: settings.json was written" \
    test ! -f "${T}/ud-o2/User/settings.json"
# o3: a partial last line without a trailing newline is still processed.
if printf '1' | run_installer "${T}/stage-new" "${T}/ud-o3" "${T}/xdg-a" \
    --pick-models >"${T}/out-o3.log" 2>&1; then
    pass "o3: a partial last line is processed"
else
    fail "o3: the partial last line failed the run"
fi
env_eq "${T}/ud-o3/User/settings.json" ANTHROPIC_DEFAULT_OPUS_MODEL spark-large

# ---- case p: a glob in the answer is rejected, never pathname-expanded -------------------------
# From a folder with a file named "1", the old splitter turned "[1]" into model 1.
mkdir -p "${T}/globcwd"
: >"${T}/globcwd/1"
if (cd "${T}/globcwd" && printf '[1]\n[1]\n[1]\n' | run_installer "${T}/stage-new" "${T}/ud-p" "${T}/xdg-a" \
    --pick-models >"${T}/out-p.log" 2>&1); then
    fail "p: '[1]' picked a model (exit 0), expected non-zero"
else
    pass "p: '[1]' is rejected (non-zero exit)"
fi
check "p: no settings.json written" "p: settings.json was written" \
    test ! -f "${T}/ud-p/User/settings.json"

# ---- case q: a dry-run pick never creates a file in TMPDIR -------------------------------------
mkdir -p "${T}/tmpdry"
if (export TMPDIR="${T}/tmpdry"; printf '1\n' | run_installer "${T}/stage-new" "${T}/ud-q" "${T}/xdg-a" \
    --dry-run --pick-models >"${T}/out-q.log" 2>&1); then
    pass "q: dry run exited 0"
else
    fail "q: dry run exited non-zero"
fi
leftover="$(ls -A "${T}/tmpdry")"
if [ -z "${leftover}" ]; then
    pass "q: no file appeared in the dry-run TMPDIR"
else
    fail "q: files appeared in the dry-run TMPDIR: ${leftover}"
fi

# ---- case r: a long digit string is rejected before the arithmetic can wrap it ------------------
if printf '18446744073709551617\n18446744073709551617\n18446744073709551617\n' | \
    run_installer "${T}/stage-new" "${T}/ud-r" "${T}/xdg-a" \
    --pick-models >"${T}/out-r.log" 2>&1; then
    fail "r: the wrapped number picked a model (exit 0), expected non-zero"
else
    pass "r: the long digit string is rejected (non-zero exit)"
fi
check "r: no settings.json written" "r: settings.json was written" \
    test ! -f "${T}/ud-r/User/settings.json"
expect_grep "18446744073709551617 is out of range 1-4" "${T}/out-r.log" \
    "r: the long number is reported as out of range" "r: no out-of-range message for the long number"
# The parser must not lean on here-strings/heredocs: bash 3.2 backs them with temp files, and a
# failed temp file inside the if-called parser would silently drop the user's answer.
check "r: parse_pick_line uses no here-string" "r: parse_pick_line uses a here-string" \
    sh -c "sed -n '/^parse_pick_line()/,/^}/p' \"\$1\" | grep -q '<<' && exit 1 || exit 0" _ \
    "${SRC}"

# ---- case s: tabs separate numbers; an empty slot between commas is a clear error -------------
if printf '1,,2\n,1\n3\t1\n' | \
    run_installer "${T}/stage-new" "${T}/ud-s" "${T}/xdg-a" \
    --pick-models >"${T}/out-s.log" 2>&1; then
    pass "s: the tab-separated answer was accepted (exit 0)"
else
    fail "s: the tab-separated answer was refused"
fi
expect_grep "an empty number between commas" "${T}/out-s.log" \
    "s: empty comma slots get a clear message" "s: no clear message for an empty comma slot"
env_eq "${T}/ud-s/User/settings.json" ANTHROPIC_DEFAULT_OPUS_MODEL qwen3-coder
env_eq "${T}/ud-s/User/settings.json" ANTHROPIC_DEFAULT_SONNET_MODEL spark-large

echo
if [ "${fails}" = 0 ]; then
    echo "PICKER TEST PASS"
else
    echo "PICKER TEST FAIL (${fails} failure(s))"
    exit 1
fi
