#!/bin/bash
# guardian/claude-vscode(VS Code 확장의 claudeProcessWrapper)와 claude-lms 의 CLAUDE_LMS_SYSTEM_PROMPT_FILE
# 인수 시험 — 가짜 claude(자기 argv 를 ARG<n>=값 으로 한 줄에 하나 찍는다)로 추가 인자를 본다. 진짜 Claude 는
# 건드리지 않고, claude-lms 사례의 LM Studio 는 127.0.0.1 의 스텁 http.server 와 가짜 lms 로 대신한다.
# 사용: guardian/tests/accept_claude_vscode.sh   (모두 통과하면 "ACCEPT PASS", 종료 0)
# 래퍼: conf 없음/거부 목록+프롬프트, 없는·읽을 수 없는 프롬프트(경고하고 확장 인자는 그대로), 첫 인자 없음
#       (로컬 claude 폴백), 추가 인자가 확장 인자보다 앞, 사용자 --system-prompt/--bare 승리, 제어문자(경고하고
#       제외), 환경값이 파일을 이긴다, 하위 명령(mcp)엔 붙이지 않음, CLAUDE_VSCODE_WRAPPER_LOG(인자만, 환경값 없음).
# claude-lms: --system-prompt-file 를 넘기고 사용자 --system-prompt/--system-prompt-file/--bare 면 생략하며,
#       없는 파일·제어문자는 거부하고, 하위 명령(mcp)엔 검사하지도 않는다.
set -u
G="$(cd "$(dirname "$0")/.." && pwd)"
W="$G/claude-vscode"
LMS="$G/claude-lms"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-cvs.XXXXXX")"
T="$(cd "$T" && pwd)"
trap '[ -n "${STUB_PID:-}" ] && { kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; }; rm -rf "$T"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }

[ -x "$W" ] || { echo "FAIL wrapper missing or not executable: $W"; exit 1; }
[ -x "$LMS" ] || { echo "FAIL claude-lms missing or not executable: $LMS"; exit 1; }
PY="${CLAUDE_LMS_PY:-$(command -v python3 || true)}"
[ -n "$PY" ] || { echo "FAIL no python3 for the stub LM Studio"; exit 1; }

# 가짜 claude: 받은 argv 를 그대로 되돌려 찍는다. 래퍼·claude-lms 는 HOME/.local/bin/claude 를 쓰므로
# 각 사례의 가짜 홈마다 하나씩 깐다.
mkclaude() {  # $1 = dir
    mkdir -p "$1"
    cat >"$1/claude" <<'EOF'
#!/bin/bash
i=1
for a in "$@"; do printf 'ARG%d=%s\n' "$i" "$a"; i=$((i + 1)); done
EOF
    chmod 755 "$1/claude"
}
# wrun <이름> <홈> <xdg> [환경값...] -- <래퍼 인자...>: $T/<이름>.out/.err/.rc 를 남긴다
wrun() {
    local n="$1" h="$2" x="$3"; shift 3
    local -a pre=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do pre+=("$1"); shift; done
    shift
    env HOME="$h" XDG_CONFIG_HOME="$x" ${pre[@]+"${pre[@]}"} "$W" "$@" >"$T/$n.out" 2>"$T/$n.err"
    echo $? >"$T/$n.rc"
}
rcat() { cat "$T/$1.rc"; }
nth() { sed -n "s/^ARG$2=//p" "$T/$1.out"; }          # nth <이름> <번호>: 그 자리의 인자 값
nargs() { wc -l <"$T/$1.out" | tr -d ' '; }            # 인자 개수

# ---- W1. conf 없음: 추가 인자 없이 확장 인자만 그대로 exec ------------------------------------------------------
H="$T/w1"; mkclaude "$H/.local/bin"; mkdir -p "$T/x1"
wrun w1 "$H" "$T/x1" -- "$H/.local/bin/claude" -p 안녕
[ "$(rcat w1)" = 0 ] && pass "W1 no conf exits 0" || bad "W1 no conf exits 0" "rc=$(rcat w1)"
[ "$(nargs w1)" = 2 ] && [ "$(nth w1 1)" = "-p" ] && [ "$(nth w1 2)" = "안녕" ] \
    && pass "W1 no conf passes argv unchanged" || bad "W1 no conf passes argv unchanged" "$(cat "$T/w1.out")"
[ ! -s "$T/w1.err" ] && pass "W1 no conf stays silent" || bad "W1 no conf stays silent" "$(cat "$T/w1.err")"

# ---- W2. 거부 목록 + 프롬프트 파일: 추가 인자가 정확한 순서로 확장 인자 앞에 온다 -------------------------------
H="$T/w2"; mkclaude "$H/.local/bin"; mkdir -p "$T/x2/claude-lms"
printf '# 가는 프롬프트\n' >"$T/w2prompt.md"
printf "CLAUDE_LMS_DISALLOWED_TOOLS='Workflow,Agent'\nCLAUDE_LMS_SYSTEM_PROMPT_FILE='%s'\n" "$T/w2prompt.md" >"$T/x2/claude-lms/env"
wrun w2 "$H" "$T/x2" -- "$H/.local/bin/claude" -p hi
[ "$(rcat w2)" = 0 ] && pass "W2 deny+prompt exits 0" || bad "W2 deny+prompt exits 0" "rc=$(rcat w2)"
[ "$(nargs w2)" = 6 ] && [ "$(nth w2 1)" = "--disallowedTools" ] && [ "$(nth w2 2)" = "Workflow,Agent" ] \
    && [ "$(nth w2 3)" = "--system-prompt-file" ] && [ "$(nth w2 4)" = "$T/w2prompt.md" ] \
    && [ "$(nth w2 5)" = "-p" ] && [ "$(nth w2 6)" = "hi" ] \
    && pass "W2 extras come before the extension args, in order" \
    || bad "W2 extras come before the extension args, in order" "$(cat "$T/w2.out")"
[ ! -s "$T/w2.err" ] && pass "W2 stays silent" || bad "W2 stays silent" "$(cat "$T/w2.err")"

# ---- W3. 없는 프롬프트 파일: 경고를 내고 --system-prompt-file 없이 계속 --------------------------------------------------
H="$T/w3"; mkclaude "$H/.local/bin"; mkdir -p "$T/x3/claude-lms"
printf "CLAUDE_LMS_DISALLOWED_TOOLS='Workflow'\nCLAUDE_LMS_SYSTEM_PROMPT_FILE='%s'\n" "$T/nope.md" >"$T/x3/claude-lms/env"
wrun w3 "$H" "$T/x3" -- "$H/.local/bin/claude" -p hi
[ "$(rcat w3)" = 0 ] && pass "W3 missing prompt still execs" || bad "W3 missing prompt still execs" "rc=$(rcat w3)"
grep -qF "CLAUDE_LMS_SYSTEM_PROMPT_FILE: $T/nope.md is missing or unreadable" "$T/w3.err" \
    && pass "W3 warns about the missing file" || bad "W3 warns about the missing file" "$(cat "$T/w3.err")"
[ "$(nargs w3)" = 4 ] && [ "$(nth w3 1)" = "--disallowedTools" ] && [ "$(nth w3 3)" = "-p" ] && [ "$(nth w3 4)" = "hi" ] \
    && pass "W3 keeps the deny list, drops the prompt" || bad "W3 keeps the deny list, drops the prompt" "$(cat "$T/w3.out")"

# ---- W4. 읽을 수 없는 프롬프트 파일: W3 와 같다(확장은 멈추지 않는다) ---------------------------------------------------
H="$T/w4"; mkclaude "$H/.local/bin"; mkdir -p "$T/x4/claude-lms"
printf 'x' >"$T/w4prompt.md"; chmod 000 "$T/w4prompt.md"
printf "CLAUDE_LMS_SYSTEM_PROMPT_FILE='%s'\n" "$T/w4prompt.md" >"$T/x4/claude-lms/env"
wrun w4 "$H" "$T/x4" -- "$H/.local/bin/claude" -p hi
chmod 600 "$T/w4prompt.md"
[ "$(rcat w4)" = 0 ] && grep -qF "is missing or unreadable" "$T/w4.err" && [ "$(nargs w4)" = 2 ] \
    && pass "W4 unreadable prompt: warn, exec without it" \
    || bad "W4 unreadable prompt: warn, exec without it" "rc=$(rcat w4) $(cat "$T/w4.err") $(cat "$T/w4.out")"

# ---- W5. 첫 인자 없음(확장이 번들 binary 를 못 찾은 호출): ~/.local/bin/claude 로 폴백 -----------------------------------
H="$T/w5"; mkclaude "$H/.local/bin"
wrun w5 "$H" "$T/x2" CLAUDE_VSCODE_WRAPPER_LOG="$T/w5.log" -- -p hi
[ "$(rcat w5)" = 0 ] && pass "W5 missing first arg exits 0" || bad "W5 missing first arg exits 0" "rc=$(rcat w5)"
logbin="$(sed -n '$p' "$T/w5.log" | cut -d' ' -f2)"
[ "${logbin:-}" = "$H/.local/bin/claude" ] && pass "W5 falls back to ~/.local/bin/claude" \
    || bad "W5 falls back to ~/.local/bin/claude" "log starts with '${logbin:-nothing}'"
[ "$(nth w5 5)" = "-p" ] && [ "$(nth w5 6)" = "hi" ] && pass "W5 keeps extras+args after the fallback" \
    || bad "W5 keeps extras+args after the fallback" "$(cat "$T/w5.out")"

# ---- W6. 확장 인자에 이미 --system-prompt/--system-prompt-file/--bare 가 있으면: 프롬프트만 생략한다 ----------------------
# (거부 목록은 여전히 붙는다 — 이기는 것은 프롬프트 파일뿐이다)
H="$T/w6"; mkclaude "$H/.local/bin"
wrun w6a "$H" "$T/x2" -- "$H/.local/bin/claude" --system-prompt mine -p hi
[ "$(rcat w6a)" = 0 ] && [ "$(nth w6a 3)" = "--system-prompt" ] && [ "$(nth w6a 4)" = "mine" ] && [ "$(nargs w6a)" = 6 ] \
    && pass "W6a user --system-prompt wins" || bad "W6a user --system-prompt wins" "$(cat "$T/w6a.out")"
! grep -qxF 'ARG3=--system-prompt-file' "$T/w6a.out" && pass "W6a adds no --system-prompt-file of its own" \
    || bad "W6a adds no --system-prompt-file of its own" "$(cat "$T/w6a.out")"
grep -qF "CLAUDE_LMS_SYSTEM_PROMPT_FILE is not applied" "$T/w6a.err" && pass "W6a notes the skip" \
    || bad "W6a notes the skip" "$(cat "$T/w6a.err")"
wrun w6b "$H" "$T/x2" -- "$H/.local/bin/claude" --system-prompt-file=/other.md -p hi
[ "$(rcat w6b)" = 0 ] && [ "$(nth w6b 3)" = "--system-prompt-file=/other.md" ] && [ "$(nargs w6b)" = 5 ] \
    && pass "W6b user --system-prompt-file= wins" || bad "W6b user --system-prompt-file= wins" "$(cat "$T/w6b.out")"
wrun w6c "$H" "$T/x2" -- "$H/.local/bin/claude" --bare -p hi
[ "$(rcat w6c)" = 0 ] && [ "$(nth w6c 3)" = "--bare" ] && [ "$(nargs w6c)" = 5 ] \
    && pass "W6c user --bare wins" || bad "W6c user --bare wins" "$(cat "$T/w6c.out")"

# ---- W7. 제어문자 든 값: 경고만 내고 제외(확장은 멈추지 않는다) ---------------------------------------------------------
H="$T/w7"; mkclaude "$H/.local/bin"; mkdir -p "$T/x7"
wrun w7 "$H" "$T/x7" CLAUDE_LMS_DISALLOWED_TOOLS=$'A\nB' CLAUDE_LMS_SYSTEM_PROMPT_FILE=$'x\ny' -- -p hi
[ "$(rcat w7)" = 0 ] && pass "W7 control chars still exec" || bad "W7 control chars still exec" "rc=$(rcat w7)"
grep -qF "CLAUDE_LMS_DISALLOWED_TOOLS has a control character" "$T/w7.err" \
    && pass "W7 warns about the deny list" || bad "W7 warns about the deny list" "$(cat "$T/w7.err")"
grep -qF "CLAUDE_LMS_SYSTEM_PROMPT_FILE has a control character" "$T/w7.err" \
    && pass "W7 warns about the prompt file" || bad "W7 warns about the prompt file" "$(cat "$T/w7.err")"
[ "$(nargs w7)" = 2 ] && [ "$(nth w7 1)" = "-p" ] && pass "W7 passes neither extra" \
    || bad "W7 passes neither extra" "$(cat "$T/w7.out")"

# ---- W8. 환경값이 파일을 이긴다(다른 CLAUDE_LMS_* 키와 같은 규칙: 비었으면 파일로 넘어간다) ------------------------------
H="$T/w8"; mkclaude "$H/.local/bin"; mkdir -p "$T/x8/claude-lms"
printf '# 파일 쪽\n' >"$T/w8prompt.md"
printf "CLAUDE_LMS_DISALLOWED_TOOLS='FromConf'\nCLAUDE_LMS_SYSTEM_PROMPT_FILE='%s'\n" "$T/w8prompt.md" >"$T/x8/claude-lms/env"
wrun w8 "$H" "$T/x8" CLAUDE_LMS_DISALLOWED_TOOLS=FromEnv -- -p hi
[ "$(rcat w8)" = 0 ] && [ "$(nth w8 2)" = "FromEnv" ] && [ "$(nth w8 4)" = "$T/w8prompt.md" ] && [ "$(nargs w8)" = 6 ] \
    && pass "W8 env deny wins, the conf's prompt still applies" \
    || bad "W8 env deny wins, the conf's prompt still applies" "$(cat "$T/w8.out")"

# ---- W9. 하위 명령(mcp)엔 추가 인자를 붙이지 않는다 ----------------------------------------------------------------------
H="$T/w9"; mkclaude "$H/.local/bin"
wrun w9 "$H" "$T/x2" -- "$H/.local/bin/claude" mcp list
[ "$(rcat w9)" = 0 ] && [ "$(nth w9 1)" = "mcp" ] && [ "$(nth w9 2)" = "list" ] && [ "$(nargs w9)" = 2 ] \
    && pass "W9 subcommand takes no extras" || bad "W9 subcommand takes no extras" "$(cat "$T/w9.out")"

# ---- W10. CLAUDE_VSCODE_WRAPPER_LOG: 실행마다 한 줄, 인자만(환경값은 절대 없다) ------------------------------------------
H="$T/w10"; mkclaude "$H/.local/bin"; mkdir -p "$T/x10/claude-lms"
printf "CLAUDE_LMS_MODEL='LOGSENTINEL'\nCLAUDE_LMS_DISALLOWED_TOOLS='Workflow'\n" >"$T/x10/claude-lms/env"
wrun w10a "$H" "$T/x10" CLAUDE_VSCODE_WRAPPER_LOG="$T/w10.log" -- "$H/.local/bin/claude" -p one
wrun w10b "$H" "$T/x10" CLAUDE_VSCODE_WRAPPER_LOG="$T/w10.log" -- "$H/.local/bin/claude" -p two
[ "$(wc -l <"$T/w10.log" | tr -d ' ')" = 2 ] && pass "W10 one line per run" || bad "W10 one line per run" "$(cat "$T/w10.log")"
grep -qF -- "-p two" "$T/w10.log" && pass "W10 log holds the argv" || bad "W10 log holds the argv" "$(sed -n '$p' "$T/w10.log")"
if grep -qF "LOGSENTINEL" "$T/w10.log" "$T/w10a.out" "$T/w10a.err" "$T/w10b.out" "$T/w10b.err"; then
    bad "W10 never logs env values" "sentinel leaked"
else
    pass "W10 never logs env values"
fi

# ---- W11. 달릴 claude 가 없으면: 확장 대신 오류로 끝난다 -----------------------------------------------------------------
H="$T/w11"; mkdir -p "$T/x11"
wrun w11 "$H" "$T/x11" -- -p hi
[ "$(rcat w11)" != 0 ] && grep -qF "no claude to run" "$T/w11.err" && pass "W11 no binary anywhere dies" \
    || bad "W11 no binary anywhere dies" "rc=$(rcat w11) $(cat "$T/w11.err")"

# ---- 스텁 LM Studio + 가짜 lms: claude-lms 사례의 바탕 ---------------------------------------------------------------
LH="$T/lh"
mkclaude "$LH/.local/bin"
mkdir -p "$LH/.lmstudio/bin" "$T/lx/claude-lms" "$T/stubroot/v1"
cat >"$LH/.lmstudio/bin/lms" <<'EOF'
#!/bin/bash
# claude-lms 는 ps --json 만 부른다: 모델이 이미 컨텍스트 131072 로 로드돼 있다고 답한다(load 없이 넘어간다).
printf '[{"identifier":"test-model","contextLength":131072}]'
EOF
chmod 755 "$LH/.lmstudio/bin/lms"
printf '{"data":[{"id":"test-model"}]}' >"$T/stubroot/v1/models"
STUB_PID=""
STUB_PORT_FILE="$T/stub.port"
STUB_PORT=""
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
' "$STUB_PORT_FILE" "$T/stubroot" >/dev/null 2>&1 &
STUB_PID=$!
stub_ok=0
for i in $(seq 1 50); do
    [ -s "$STUB_PORT_FILE" ] && STUB_PORT="$(cat "$STUB_PORT_FILE")"
    if [ -n "${STUB_PORT}" ] && curl -fsS -m 1 "http://127.0.0.1:${STUB_PORT}/v1/models" >/dev/null 2>&1; then
        stub_ok=1; break
    fi
    sleep 0.1
done
[ "${stub_ok}" = 1 ] || { echo "FAIL stub LM Studio did not come up"; exit 1; }
lmconf() {  # 나머지 인자: conf 에 덧붙일 한 줄씩
    printf "CLAUDE_LMS_MODEL='test-model'\nCLAUDE_LMS_URL='http://127.0.0.1:%s'\n" "${STUB_PORT}" >"$T/lx/claude-lms/env"
    local line
    for line in "$@"; do printf '%s\n' "$line" >>"$T/lx/claude-lms/env"; done
}
# lrun <이름> [환경값...] -- <claude-lms 인자...>
lrun() {
    local n="$1"; shift
    local -a pre=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do pre+=("$1"); shift; done
    shift
    env HOME="$LH" XDG_CONFIG_HOME="$T/lx" ${pre[@]+"${pre[@]}"} "$LMS" "$@" >"$T/$n.out" 2>"$T/$n.err"
    echo $? >"$T/$n.rc"
}

# ---- L1. claude-lms: --system-prompt-file 를 넘긴다(거부 목록과 같은 자리, 같은 순서) ------------------------------------
printf '# 키트 프롬프트\n' >"$T/l1prompt.md"
lmconf "CLAUDE_LMS_DISALLOWED_TOOLS='ScheduleWakeup'" "CLAUDE_LMS_SYSTEM_PROMPT_FILE='$T/l1prompt.md'"
lrun l1 -- -p hi
[ "$(rcat l1)" = 0 ] && pass "L1 exits 0" || bad "L1 exits 0" "rc=$(rcat l1) $(cat "$T/l1.err")"
[ "$(nargs l1)" = 6 ] && [ "$(nth l1 1)" = "--disallowedTools" ] && [ "$(nth l1 2)" = "ScheduleWakeup" ] \
    && [ "$(nth l1 3)" = "--system-prompt-file" ] && [ "$(nth l1 4)" = "$T/l1prompt.md" ] \
    && [ "$(nth l1 5)" = "-p" ] && [ "$(nth l1 6)" = "hi" ] \
    && pass "L1 passes --system-prompt-file before the user args" || bad "L1 passes --system-prompt-file before the user args" "$(cat "$T/l1.out")"

# ---- L2/L3. 사용자의 --system-prompt·--bare 가 이긴다(프롬프트만 생략, 거부 목록은 유지) ---------------------------------
lrun l2 -- --system-prompt mine -p hi
[ "$(rcat l2)" = 0 ] && [ "$(nth l2 3)" = "--system-prompt" ] && [ "$(nth l2 4)" = "mine" ] && [ "$(nargs l2)" = 6 ] \
    && pass "L2 user --system-prompt wins" || bad "L2 user --system-prompt wins" "$(cat "$T/l2.out")"
! grep -qxF 'ARG3=--system-prompt-file' "$T/l2.out" && pass "L2 adds no --system-prompt-file of its own" \
    || bad "L2 adds no --system-prompt-file of its own" "$(cat "$T/l2.out")"
grep -qF "CLAUDE_LMS_SYSTEM_PROMPT_FILE is not applied" "$T/l2.err" && pass "L2 notes the skip" \
    || bad "L2 notes the skip" "$(cat "$T/l2.err")"
lrun l3 -- --bare -p hi
[ "$(rcat l3)" = 0 ] && [ "$(nth l3 3)" = "--bare" ] && [ "$(nargs l3)" = 5 ] \
    && pass "L3 user --bare wins" || bad "L3 user --bare wins" "$(cat "$T/l3.out")"

# ---- L4. 없는 파일: 실행 전에 오류로 중단(가짜 claude 는 불리지도 않는다) ------------------------------------------------
lmconf "CLAUDE_LMS_SYSTEM_PROMPT_FILE='$T/l-nope.md'"
lrun l4 -- -p hi
[ "$(rcat l4)" != 0 ] && pass "L4 missing prompt file fails" || bad "L4 missing prompt file fails" "rc=0"
grep -qF "CLAUDE_LMS_SYSTEM_PROMPT_FILE: $T/l-nope.md does not exist" "$T/l4.err" && pass "L4 names the missing file" \
    || bad "L4 names the missing file" "$(cat "$T/l4.err")"
[ ! -s "$T/l4.out" ] && pass "L4 never runs claude" || bad "L4 never runs claude" "$(cat "$T/l4.out")"

# ---- L5. 제어문자: 값은 찍지 않고 키만 짚어 거부 ------------------------------------------------------------------------
# conf 의 작은따옴표 값 안에 실제 줄바꿈을 넣는다(손으로 편집한 파일이 만들 수 있는 모양).
lmconf $'CLAUDE_LMS_SYSTEM_PROMPT_FILE=\'l\n5\''
lrun l5 -- -p hi
[ "$(rcat l5)" != 0 ] && grep -qF "CLAUDE_LMS_SYSTEM_PROMPT_FILE must be a file path" "$T/l5.err" && pass "L5 control char refused" \
    || bad "L5 control char refused" "rc=$(rcat l5) $(cat "$T/l5.err")"
case "$(cat "$T/l5.err")" in *$'l\n5'*) bad "L5 never prints the value" "value leaked" ;; *) pass "L5 never prints the value" ;; esac
[ ! -s "$T/l5.out" ] && pass "L5 never runs claude" || bad "L5 never runs claude" "$(cat "$T/l5.out")"

# ---- L6. 설정 없음: 오늘과 같은 argv -----------------------------------------------------------------------------------
lmconf ""
lrun l6 -- -p hi
[ "$(rcat l6)" = 0 ] && [ "$(nargs l6)" = 2 ] && [ "$(nth l6 1)" = "-p" ] && pass "L6 no settings, argv unchanged" \
    || bad "L6 no settings, argv unchanged" "$(cat "$T/l6.out")"

# ---- L7. 하위 명령(mcp): 검사하지도, 붙이지도 않는다 -------------------------------------------------------------------
lmconf "CLAUDE_LMS_SYSTEM_PROMPT_FILE='$T/l-nope.md'"
lrun l7 -- mcp list
[ "$(rcat l7)" = 0 ] && [ "$(nth l7 1)" = "mcp" ] && [ "$(nth l7 2)" = "list" ] && [ "$(nargs l7)" = 2 ] \
    && pass "L7 subcommand skips the prompt entirely" || bad "L7 subcommand skips the prompt entirely" "rc=$(rcat l7) $(cat "$T/l7.err") $(cat "$T/l7.out")"

# ---- L8. 환경값이 파일을 이긴다 ----------------------------------------------------------------------------------------
printf '# 환경 쪽\n' >"$T/l8prompt.md"
lmconf "CLAUDE_LMS_SYSTEM_PROMPT_FILE='$T/l1prompt.md'"
lrun l8 CLAUDE_LMS_SYSTEM_PROMPT_FILE="$T/l8prompt.md" -- -p hi
[ "$(rcat l8)" = 0 ] && [ "$(nth l8 2)" = "$T/l8prompt.md" ] && pass "L8 env path wins over the conf's" \
    || bad "L8 env path wins over the conf's" "$(cat "$T/l8.out")"

echo
if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi
