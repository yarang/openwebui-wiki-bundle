#!/bin/bash
# skill-guard(PreToolUse hook) 와 claude-lms 의 hook 주입 인수 시험.
# 사용: CLAUDE_LMS_PY=<python> tests/accept_skill_guard.sh   (모두 통과하면 "ACCEPT PASS", 종료 0)
# 작은 모델이 같은 Skill 을 되풀이해 부르는 루프(Skill 은 안내만 싣고 명령을 실행하지 않음)를 끊는다:
# 세션마다 같은 skill 의 첫 호출은 허용하고, 두 번째부터는 거부하며 Bash 로 실행할 명령을 알려 준다.
set -u
KIT="$(cd "$(dirname "$0")/.." && pwd)"
G="$KIT/skills/hwpx/scripts/skill-guard"
W="$KIT/../claude-lms"
INST="$KIT/../install-claude-code.sh"
PY="${CLAUDE_LMS_PY:-$HOME/.guardian-llm/venv/bin/python}"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-guard.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }

[ -x "$G" ] || { echo "FAIL guard missing or not executable: $G"; exit 1; }

# 가짜 HOME: hwpx 명령이 있는 설치 모양(scripts/hwpx 실행 파일)과 상태 폴더용 TMPDIR.
FH="$T/home"; mkdir -p "$FH/.claude/skills/hwpx/scripts" "$T/tmp"
printf '#!/bin/sh\nexit 0\n' > "$FH/.claude/skills/hwpx/scripts/hwpx"; chmod 755 "$FH/.claude/skills/hwpx/scripts/hwpx"
STATE="$T/tmp/claude-lms-skill-guard-$(id -u)"

# hook 입력 JSON 만들기: hin <session> <tool> <skill> <args>
hin() {
  "$PY" -I -c 'import json,sys; print(json.dumps({"session_id":sys.argv[1],"transcript_path":"/x.jsonl","cwd":"/x","hook_event_name":"PreToolUse","tool_name":sys.argv[2],"tool_input":{"skill":sys.argv[3],"args":sys.argv[4]}},ensure_ascii=False))' "$@"
}
# guard 실행: run <name> <stdin-file>  → $T/<name>.out, rc 는 $T/<name>.rc
run() {
  HOME="$FH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$PY" "$G" < "$2" > "$T/$1.out" 2> "$T/$1.err"; echo $? > "$T/$1.rc"
}
# deny JSON 검사: isdeny <out-file> → 0 이면 올바른 deny, 이유는 $T/reason.txt
isdeny() {
  "$PY" -I -c '
import json,sys
o=json.load(open(sys.argv[1],encoding="utf-8"))
h=o["hookSpecificOutput"]
assert h["hookEventName"]=="PreToolUse" and h["permissionDecision"]=="deny"
open(sys.argv[2],"w",encoding="utf-8").write(h["permissionDecisionReason"])
' "$1" "$T/reason.txt" 2>/dev/null
}
allowed() { [ "$(cat "$T/$1.rc")" = 0 ] && [ ! -s "$T/$1.out" ]; }

# 1. 첫 호출은 허용(출력 없음, 종료 0)
hin s1 Skill hwpx 'fields ./양식.hwpx' > "$T/in1.json"
run g1 "$T/in1.json"
allowed g1 && pass guard-first-call-allowed || bad guard-first-call-allowed "rc=$(cat "$T/g1.rc") out=$(head -c 200 "$T/g1.out")"

# 2. 같은 세션의 두 번째 호출은 거부 + 정확한 Bash 명령
run g2 "$T/in1.json"
if [ "$(cat "$T/g2.rc")" = 0 ] && isdeny "$T/g2.out" \
  && grep -qF 'Skill 을 다시 부르지 말고' "$T/reason.txt" && grep -qF 'Bash' "$T/reason.txt" \
  && grep -qF '~/.claude/skills/hwpx/scripts/hwpx fields ./양식.hwpx' "$T/reason.txt"; then
  pass guard-repeat-denied-with-command
else bad guard-repeat-denied-with-command "rc=$(cat "$T/g2.rc") out=$(head -c 300 "$T/g2.out")"; fi

# 2b. 세 번째도 거부(루프가 계속돼도 매번 같은 안내)
run g2b "$T/in1.json"
isdeny "$T/g2b.out" && grep -qF 'scripts/hwpx fields ./양식.hwpx' "$T/reason.txt" && pass guard-third-denied || bad guard-third-denied "$(head -c 200 "$T/g2b.out")"

# 3. 다른 세션은 독립
hin s2 Skill hwpx 'fields ./양식.hwpx' > "$T/in3.json"
run g3 "$T/in3.json"
allowed g3 && pass guard-other-session-independent || bad guard-other-session-independent "$(head -c 200 "$T/g3.out")"

# 4. 같은 세션의 다른 skill 은 독립, 그 skill 의 두 번째는 일반 안내(명령 파일 없음 → 경로를 지어내지 않음)
hin s1 Skill docx 'read ./a.docx' > "$T/in4.json"
run g4 "$T/in4.json"
allowed g4 && pass guard-other-skill-independent || bad guard-other-skill-independent "$(head -c 200 "$T/g4.out")"
run g4b "$T/in4.json"
if isdeny "$T/g4b.out" && grep -qF 'Skill 을 다시 부르지 말고' "$T/reason.txt" && ! grep -qF 'scripts/docx' "$T/reason.txt"; then
  pass guard-generic-reason-no-made-up-path
else bad guard-generic-reason-no-made-up-path "$(cat "$T/reason.txt" 2>/dev/null | head -c 300)"; fi

# 4c. 오피스 skill(설치 모양에 scripts/pptx 가 있음): 두 번째 호출은 그 명령으로 안내(from-md 처럼 - 가 든 명령도)
mkdir -p "$FH/.claude/skills/pptx/scripts"
printf '#!/bin/sh\nexit 0\n' > "$FH/.claude/skills/pptx/scripts/pptx"; chmod 755 "$FH/.claude/skills/pptx/scripts/pptx"
hin s4c Skill pptx 'from-md ./발표.md ./발표.pptx' > "$T/in4c.json"
run g4c "$T/in4c.json"; run g4c2 "$T/in4c.json"
if allowed g4c && isdeny "$T/g4c2.out" \
  && grep -qF '~/.claude/skills/pptx/scripts/pptx from-md ./발표.md ./발표.pptx' "$T/reason.txt"; then
  pass guard-office-skill-exact-command
else bad guard-office-skill-exact-command "$(cat "$T/reason.txt" 2>/dev/null | head -c 300)"; fi

# 5. args 가 명령어가 아닌 자연어면 명령 목록(--help) 안내, 자연어는 명령으로 옮기지 않음
hin s5 Skill hwpx '' > "$T/in5a.json"; run g5a "$T/in5a.json"
hin s5 Skill hwpx '양식을 채워줘' > "$T/in5.json"; run g5 "$T/in5.json"
if isdeny "$T/g5.out" && grep -qF '~/.claude/skills/hwpx/scripts/hwpx --help' "$T/reason.txt" && ! grep -qF 'hwpx 양식을 채워줘' "$T/reason.txt"; then
  pass guard-natural-language-args-help
else bad guard-natural-language-args-help "$(cat "$T/reason.txt" 2>/dev/null | head -c 300)"; fi

# 5b. 빈 args 의 두 번째 호출도 --help 안내
run g5b "$T/in5a.json"
isdeny "$T/g5b.out" && grep -qF 'scripts/hwpx --help' "$T/reason.txt" && pass guard-empty-args-help || bad guard-empty-args-help "$(head -c 200 "$T/g5b.out")"

# 6. Skill 이 아닌 도구는 손대지 않음(출력 없음, 상태 기록 없음)
hin s6 Bash hwpx 'fields x' > "$T/in6.json"; run g6 "$T/in6.json"; run g6b "$T/in6.json"
allowed g6 && allowed g6b && [ ! -e "$STATE/s6" ] && pass guard-ignores-other-tools || bad guard-ignores-other-tools "$(head -c 200 "$T/g6b.out")"

# 7. 잘못된 입력은 언제나 허용(fail-open): JSON 아님, session_id 없음, 위험한 session_id
printf 'not json' > "$T/in7a.json"; run g7a "$T/in7a.json"
"$PY" -I -c 'import json; print(json.dumps({"tool_name":"Skill","tool_input":{"skill":"hwpx","args":"x"}}))' > "$T/in7b.json"
run g7b "$T/in7b.json"; run g7b2 "$T/in7b.json"
hin '../escape' Skill hwpx 'x' > "$T/in7c.json"; run g7c "$T/in7c.json"; run g7c2 "$T/in7c.json"
if allowed g7a && allowed g7b && allowed g7b2 && allowed g7c && allowed g7c2 && [ ! -e "$T/tmp/escape" ] && [ ! -e "$T/escape" ]; then
  pass guard-fail-open-bad-input
else bad guard-fail-open-bad-input "7a=$(cat "$T/g7a.rc") 7b2=$(head -c 100 "$T/g7b2.out") 7c2=$(head -c 100 "$T/g7c2.out")"; fi

# 7b. 이상한 skill 이름(경로 문자·줄바꿈)은 허용만 하고 기록하지 않음
hin s7 Skill '../../x' 'y' > "$T/in7d.json"; run g7d "$T/in7d.json"; run g7d2 "$T/in7d.json"
allowed g7d && allowed g7d2 && pass guard-fail-open-bad-skill-name || bad guard-fail-open-bad-skill-name "$(head -c 200 "$T/g7d2.out")"

# 7c. plugin:skill 형태 이름은 정상 처리(두 번째 거부, 일반 안내)
hin s7 Skill 'moai:doc-hwp' '' > "$T/in7e.json"; run g7e "$T/in7e.json"; run g7e2 "$T/in7e.json"
allowed g7e && isdeny "$T/g7e2.out" && pass guard-plugin-skill-name || bad guard-plugin-skill-name "$(head -c 200 "$T/g7e2.out")"

# 7d. 앞의 '/' 는 같은 skill 로 본다(/hwpx 다음 hwpx → 거부)
hin s7f Skill '/hwpx' 'read ./a.hwpx' > "$T/in7f.json"; run g7f "$T/in7f.json"
hin s7f Skill 'hwpx' 'read ./a.hwpx' > "$T/in7g.json"; run g7g "$T/in7g.json"
allowed g7f && isdeny "$T/g7g.out" && grep -qF 'scripts/hwpx read ./a.hwpx' "$T/reason.txt" && pass guard-leading-slash-same-skill || bad guard-leading-slash-same-skill "$(head -c 200 "$T/g7g.out")"

# 8. 파이썬이 없으면 허용(출력 없음, 종료 0)
HOME="$FH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$T/nope/python" "$G" < "$T/in1.json" > "$T/g8.out" 2>&1; rc=$?
[ $rc -eq 0 ] && [ ! -s "$T/g8.out" ] && pass guard-no-python-fail-open || bad guard-no-python-fail-open "rc=$rc $(head -c 200 "$T/g8.out")"

# 9. args 의 제어 문자는 공백으로, 따옴표가 있어도 출력은 올바른 JSON
hin s9 Skill hwpx 'x' > "$T/in9a.json"; run g9a "$T/in9a.json"
hin s9 Skill hwpx "$(printf 'fill ./a.hwpx\n./"v".json\t./o.hwpx\033[31m')" > "$T/in9.json"; run g9 "$T/in9.json"
if isdeny "$T/g9.out" && grep -qF 'scripts/hwpx fill ./a.hwpx ./"v".json ./o.hwpx' "$T/reason.txt" \
  && ! LC_ALL=C grep -q "$(printf '[\001-\037]')" "$T/reason.txt"; then
  pass guard-args-sanitized
else bad guard-args-sanitized "$(head -c 300 "$T/g9.out")"; fi

# 9b. 너무 긴 args(300자 초과)는 옮기지 않고 --help 안내
LONG="fields $(printf 'a%.0s' $(seq 1 400))"
hin s9b Skill hwpx 'x' > "$T/in9b1.json"; run g9b1 "$T/in9b1.json"
hin s9b Skill hwpx "$LONG" > "$T/in9b.json"; run g9b "$T/in9b.json"
if isdeny "$T/g9b.out" && grep -qF 'scripts/hwpx --help' "$T/reason.txt" && [ "$(wc -c < "$T/reason.txt")" -lt 1200 ]; then
  pass guard-long-args-not-copied
else bad guard-long-args-not-copied "$(wc -c < "$T/reason.txt" 2>/dev/null)"; fi

# 9c. 셸 특수 문자(; & | $ ` < > ( ) \)가 든 args 는 명령으로 옮기지 않고 --help 안내
bad9c=""
for a in 'fields ./a.hwpx; touch ./pwn' 'fields ./a.hwpx && touch ./pwn' 'fields $(touch ./pwn)' 'fields `touch ./pwn`' \
         'fields ./a.hwpx | sh' 'fields ./a.hwpx > ./pwn' 'fields < ./pwn' 'fields (x)' 'fields a\b'; do
  sid="s9c$(printf '%s' "$a" | cksum | cut -d' ' -f1)"
  hin "$sid" Skill hwpx 'x' > "$T/in9c1.json"; run g9c1 "$T/in9c1.json"
  hin "$sid" Skill hwpx "$a" > "$T/in9c.json"; run g9c "$T/in9c.json"
  if ! { isdeny "$T/g9c.out" && grep -qF 'scripts/hwpx --help' "$T/reason.txt" && ! grep -qF 'pwn' "$T/reason.txt" && ! grep -qF 'a\b' "$T/reason.txt"; }; then
    bad9c="$bad9c [$a]"
  fi
done
[ -z "$bad9c" ] && pass guard-shell-metachar-not-copied || bad guard-shell-metachar-not-copied "$bad9c"

# 10. 상태 폴더는 본인만(700), 세션 파일은 그 안에만
mode=$(stat -f %Lp "$STATE" 2>/dev/null)
[ "$mode" = 700 ] && [ -f "$STATE/s1" ] && pass guard-state-dir-private || bad guard-state-dir-private "mode=$mode $(ls -la "$STATE" 2>&1 | head -3 | tr '\n' ' ')"

# 11. 상태 폴더 자리가 심볼릭 링크면(다른 사용자가 심어 둔 경우) 따라가지 않고 허용만
T2="$T/tmp2"; mkdir -p "$T2" "$T/victim"
ln -s "$T/victim" "$T2/claude-lms-skill-guard-$(id -u)"
HOME="$FH" TMPDIR="$T2" CLAUDE_LMS_PY="$PY" "$G" < "$T/in1.json" > "$T/g11.out" 2>&1; rc1=$?
HOME="$FH" TMPDIR="$T2" CLAUDE_LMS_PY="$PY" "$G" < "$T/in1.json" > "$T/g11b.out" 2>&1; rc2=$?
if [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ] && [ ! -s "$T/g11.out" ] && [ ! -s "$T/g11b.out" ] && [ -z "$(ls -A "$T/victim")" ]; then
  pass guard-state-symlink-refused
else bad guard-state-symlink-refused "rc=$rc1/$rc2 victim=$(ls -A "$T/victim" | tr '\n' ' ') out=$(head -c 100 "$T/g11b.out")"; fi

# 12. 빠르게 끝난다(한 번 2초 미만)
hin s12 Skill hwpx 'read ./a.hwpx' > "$T/in12.json"
s=$("$PY" -I -c 'import time; print(time.time())')
run g12 "$T/in12.json"
e=$("$PY" -I -c 'import time,sys; print(int(time.time()-float(sys.argv[1]) < 2))' "$s")
[ "$e" = 1 ] && pass guard-fast || bad guard-fast "took >= 2s"

# ---- 오피스 파일 Write 막기 · Stop 가드 (실전 시험에서 본 두 실패) ----
# (a) gemma 가 Markdown 을 Write 로 회의록.docx 에 써 놓고 성공이라 했다 → Write/Edit/MultiEdit 와 Bash 리다이렉트로
#     오피스 확장자 파일을 만드는 것을 거부하고 from-md 명령을 알려 준다.
# (b) Skill 안내를 읽고 "다음 작업을 지시해 주세요" 하고 멈췄다 → Skill 을 허용한 뒤 그 skill 명령(--help 말고)을
#     Bash 로 돌리지 않았으면 Stop 을 한 번 막는다(stop_hook_active 면 막지 않음).
for n in docx xlsx; do
  mkdir -p "$FH/.claude/skills/$n/scripts"
  printf '#!/bin/sh\nexit 0\n' > "$FH/.claude/skills/$n/scripts/$n"; chmod 755 "$FH/.claude/skills/$n/scripts/$n"
done
# pj <out-file> <python dict 식> : 아무 hook 입력 JSON
pj() { "$PY" -I -c 'import json,sys; print(json.dumps(eval(sys.argv[1]),ensure_ascii=False))' "$2" > "$1"; }
# wr <out-file> <session> <tool> <file_path> : Write/Edit 입력
wr() { pj "$1" "{'session_id':'$2','transcript_path':'/x.jsonl','cwd':'/x','hook_event_name':'PreToolUse','tool_name':'$3','tool_input':{'file_path':'''$4''','content':'# 제목'}}"; }
# bs <out-file> <session> <command> : Bash 입력(command 는 python 문자열 식)
bs() { pj "$1" "{'session_id':'$2','transcript_path':'/x.jsonl','cwd':'/x','hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':$3}}"; }
# st <out-file> <session> <True|False> : Stop 입력
st() { pj "$1" "{'session_id':'$2','transcript_path':'/x.jsonl','cwd':'/x','hook_event_name':'Stop','stop_hook_active':$3}"; }
# isblock <out-file> → 0 이면 올바른 Stop 차단 JSON(decision/reason 만), 이유는 $T/reason.txt
isblock() {
  "$PY" -I -c '
import json,sys
o=json.load(open(sys.argv[1],encoding="utf-8"))
assert sorted(o)==["decision","reason"] and o["decision"]=="block" and o["reason"].strip()
open(sys.argv[2],"w",encoding="utf-8").write(o["reason"])
' "$1" "$T/reason.txt" 2>/dev/null
}

# 6b. 다른 도구(Read)는 손대지 않음(출력 없음, 상태 기록 없음)
pj "$T/in6c.json" "{'session_id':'s6c','hook_event_name':'PreToolUse','tool_name':'Read','tool_input':{'file_path':'./a.docx'}}"
run g6c "$T/in6c.json"
allowed g6c && [ ! -e "$STATE/s6c" ] && [ ! -e "$STATE/s6c.pending" ] && pass guard-ignores-read || bad guard-ignores-read "$(head -c 200 "$T/g6c.out")"

# 21. Write 로 .docx 를 만들면 거부 + Skill docx 와 from-md 명령 안내(표지 [skill-guard])
wr "$T/in21.json" s21 Write './회의록.docx'; run g21 "$T/in21.json"
if [ "$(cat "$T/g21.rc")" = 0 ] && isdeny "$T/g21.out" && grep -qF '[skill-guard]' "$T/reason.txt" \
  && grep -qF 'Skill docx' "$T/reason.txt" && grep -qF '~/.claude/skills/docx/scripts/docx from-md' "$T/reason.txt" \
  && grep -qF 'Bash' "$T/reason.txt"; then
  pass write-office-denied
else bad write-office-denied "rc=$(cat "$T/g21.rc") $(head -c 300 "$T/g21.out")"; fi

# 21b. 절대 경로·대문자 확장자도 거부(.XLSX → xlsx 안내)
wr "$T/in21b.json" s21 Write '/Users/u/문서/예산.XLSX'; run g21b "$T/in21b.json"
isdeny "$T/g21b.out" && grep -qF 'scripts/xlsx from-md' "$T/reason.txt" && pass write-office-abs-upper-denied || bad write-office-abs-upper-denied "$(head -c 300 "$T/g21b.out")"

# 21c. Edit(.pptx)·MultiEdit(.hwpx)도 거부
wr "$T/in21c.json" s21 Edit './발표.pptx'; run g21c "$T/in21c.json"; isdeny "$T/g21c.out" && grep -qF 'scripts/pptx from-md' "$T/reason.txt"; r1=$?
wr "$T/in21d.json" s21 MultiEdit './보고.hwpx'; run g21d "$T/in21d.json"; isdeny "$T/g21d.out" && grep -qF 'scripts/hwpx from-md' "$T/reason.txt"; r2=$?
[ $r1 -eq 0 ] && [ $r2 -eq 0 ] && pass edit-office-denied || bad edit-office-denied "$(head -c 200 "$T/g21c.out") / $(head -c 200 "$T/g21d.out")"

# 21d. 옛 확장자(.doc .xls .ppt .hwp)도 거부하고 새 형식(docx xlsx pptx hwpx)으로 안내
bad21=""
for p in 'doc:docx' 'xls:xlsx' 'ppt:pptx' 'hwp:hwpx'; do
  wr "$T/in21e.json" s21e Write "./옛파일.${p%%:*}"; run g21e "$T/in21e.json"
  isdeny "$T/g21e.out" && grep -qF "scripts/${p#*:} from-md" "$T/reason.txt" || bad21="$bad21 [${p%%:*}]"
done
[ -z "$bad21" ] && pass write-legacy-office-denied || bad write-legacy-office-denied "$bad21"

# 21e. Markdown·다른 파일은 허용, file_path 가 없어도 허용, 상태 기록 없음
bad21=""
for f in './회의록.md' './a.docx.md' './docx' './보고서.txt' './x.docxx'; do
  wr "$T/in21f.json" s21f Write "$f"; run g21f "$T/in21f.json"; allowed g21f || bad21="$bad21 [$f]"
done
pj "$T/in21g.json" "{'session_id':'s21f','hook_event_name':'PreToolUse','tool_name':'Write','tool_input':{'content':'x'}}"
run g21g "$T/in21g.json"; allowed g21g || bad21="$bad21 [no-path]"
[ -z "$bad21" ] && [ ! -e "$STATE/s21f" ] && [ ! -e "$STATE/s21f.pending" ] && pass write-other-files-allowed || bad write-other-files-allowed "$bad21"

# 21f. 명령이 설치되지 않은 홈에서는 지어낸 경로 없이 거부만(Write 로는 열리는 파일을 못 만든다)
EH="$T/emptyhome"; mkdir -p "$EH/.claude"
HOME="$EH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$PY" "$G" < "$T/in21.json" > "$T/g21h.out" 2>/dev/null
isdeny "$T/g21h.out" && grep -qF '[skill-guard]' "$T/reason.txt" && ! grep -qF 'scripts/docx' "$T/reason.txt" \
  && pass write-office-denied-no-command || bad write-office-denied-no-command "$(head -c 300 "$T/g21h.out")"

# 21g. 같은 세션에서 Skill docx 를 이미 불렀으면 Skill 을 다시 부르라 하지 않고 바로 Bash from-md 안내
hin s21i Skill docx '' > "$T/in21i.json"; run g21i "$T/in21i.json"
wr "$T/in21j.json" s21i Write './회의록.docx'; run g21j "$T/in21j.json"
if allowed g21i && isdeny "$T/g21j.out" && grep -qF 'Skill 을 다시 부르지 말고' "$T/reason.txt" \
  && ! grep -qF 'Skill docx 를 부르' "$T/reason.txt" && grep -qF 'scripts/docx from-md' "$T/reason.txt"; then
  pass write-office-after-skill-straight-to-bash
else bad write-office-after-skill-straight-to-bash "$(cat "$T/reason.txt" 2>/dev/null | head -c 300)"; fi

# 22. Bash 리다이렉트로 오피스 파일을 만들면 같은 이유로 거부(cat > x.docx heredoc, >>, tee, 따옴표·공백 경로)
bad22=""
i=0
for c in "\"cat > ./회의록.docx <<'MD'\\n# 회의록\\nMD\"" "'echo x >> /a/b/예산.XLSX'" "'printf x | tee ./발표.pptx'" \
         "'printf x | tee -a ./a.hwpx'" "'cat <<MD > \"./보고 서.docx\"\\n본문\\nMD'" "'echo x >./옛.doc'" \
         "\"cat > ./a.md <<'MD'\\n본문\\nMD\\necho hi > ./b.docx\""; do
  i=$((i+1))
  bs "$T/in22.json" "s22x$i" "$c"; run g22 "$T/in22.json"
  isdeny "$T/g22.out" && grep -qF '[skill-guard]' "$T/reason.txt" && grep -qF 'from-md' "$T/reason.txt" || bad22="$bad22 [#$i $(head -c 120 "$T/g22.out")]"
done
[ -z "$bad22" ] && pass bash-redirect-office-denied || bad bash-redirect-office-denied "$bad22"

# 22b. 진짜 변환·읽기 명령, md 로 가는 heredoc(본문에 '> 첨부.docx' 인용 줄이 있어도), 2>&1 은 허용
bad22=""
i=0
for c in "'~/.claude/skills/docx/scripts/docx from-md ./a.md ./a.docx'" "'~/.claude/skills/xlsx/scripts/xlsx read ./예산.xlsx'" \
         "\"cat > ./a.md <<'MD'\\n> 첨부: 회의록.docx\\n본문\\nMD\\n~/.claude/skills/docx/scripts/docx from-md ./a.md ./b.docx 2>&1\"" \
         "'ls -l ./*.docx > ./목록.txt'" "'cp ./a.docx ./b.docx'"; do
  i=$((i+1))
  bs "$T/in22b.json" "s22y$i" "$c"; run g22b "$T/in22b.json"
  allowed g22b || bad22="$bad22 [#$i $(head -c 120 "$T/g22b.out")]"
done
[ -z "$bad22" ] && pass bash-real-commands-allowed || bad bash-real-commands-allowed "$bad22"

# 23. Skill xlsx(허용) 뒤 Bash 없이 Stop → 차단: 원래 요청대로 바로 Bash 로, from-md 형태, Skill 재호출 금지,
#     지어내지 않기, 표지 [skill-guard], 파일이 아직 없음·이번 답에서 Bash 도구, 이름 자리는 사용자가 말한 이름, '앞으로' 없음
hin s23 Skill xlsx '' > "$T/in23a.json"; run g23a "$T/in23a.json"
st "$T/in23s.json" s23 False; run g23s "$T/in23s.json"
if allowed g23a && [ "$(cat "$T/g23s.rc")" = 0 ] && isblock "$T/g23s.out" && grep -qF '[skill-guard]' "$T/reason.txt" \
  && grep -qF '원래 요청대로' "$T/reason.txt" && grep -qF 'Bash' "$T/reason.txt" \
  && grep -qF '~/.claude/skills/xlsx/scripts/xlsx from-md' "$T/reason.txt" \
  && grep -qF 'Skill 을 다시 부르지 말고' "$T/reason.txt" && grep -qF '지어내지' "$T/reason.txt" \
  && grep -qF '아직' "$T/reason.txt" && grep -qF '이번 답' "$T/reason.txt" && grep -qF 'Bash 도구' "$T/reason.txt" \
  && grep -qF '사용자가 말한' "$T/reason.txt" && ! grep -qF '앞으로' "$T/reason.txt"; then
  pass stop-blocked-after-skill-without-bash
else bad stop-blocked-after-skill-without-bash "rc=$(cat "$T/g23s.rc") $(head -c 300 "$T/g23s.out")"; fi

# 23b. 최대 두 번 막는다: 두 번째 Stop 도 막되 첫 번째와 다른(더 짧은) 문구, 세 번째는 허용하고 표시를 지움
cp "$T/reason.txt" "$T/reason23a.txt" 2>/dev/null
run g23t "$T/in23s.json"
if isblock "$T/g23t.out" && ! cmp -s "$T/reason.txt" "$T/reason23a.txt" && grep -qF '[skill-guard]' "$T/reason.txt" \
  && grep -qF 'Bash 도구' "$T/reason.txt" && grep -qF 'scripts/xlsx from-md' "$T/reason.txt" && ! grep -qF '앞으로' "$T/reason.txt"; then
  run g23u "$T/in23s.json"
  allowed g23u && [ ! -e "$STATE/s23.pending" ] && pass stop-blocked-at-most-twice || bad stop-blocked-at-most-twice "third: $(head -c 200 "$T/g23u.out")"
else bad stop-blocked-at-most-twice "second: $(head -c 300 "$T/g23t.out")"; fi

# 23c. stop_hook_active=true 여도 두 번까지는 막고 세 번째는 허용(횟수 상한으로 무한 루프 방지)
hin s23c Skill xlsx '' > "$T/in23c.json"; run g23c "$T/in23c.json"
st "$T/in23cs.json" s23c True; run g23cs1 "$T/in23cs.json"; run g23cs2 "$T/in23cs.json"; run g23cs3 "$T/in23cs.json"
allowed g23c && isblock "$T/g23cs1.out" && isblock "$T/g23cs2.out" && allowed g23cs3 && pass stop-hook-active-capped-at-two || bad stop-hook-active-capped-at-two "$(head -c 200 "$T/g23cs3.out")"

# 24. Skill xlsx 뒤 그 명령을 Bash 로 돌렸으면 Stop 허용(~ 경로·절대 경로 모두)
hin s24 Skill xlsx '' > "$T/in24.json"; run g24 "$T/in24.json"
bs "$T/in24b.json" s24 "\"cat > ./a.md <<'MD'\\n## 예산\\n| a |\\n| --- |\\n| 1 |\\nMD\\n~/.claude/skills/xlsx/scripts/xlsx from-md ./a.md ./a.xlsx\""
run g24b "$T/in24b.json"
st "$T/in24s.json" s24 False; run g24s "$T/in24s.json"
hin s24x Skill xlsx '' > "$T/in24x.json"; run g24x "$T/in24x.json"
bs "$T/in24y.json" s24x "'/Users/u/.claude/skills/xlsx/scripts/xlsx read ./a.xlsx'"; run g24y "$T/in24y.json"
st "$T/in24z.json" s24x False; run g24z "$T/in24z.json"
allowed g24b && allowed g24s && allowed g24y && allowed g24z && pass stop-allowed-after-command || bad stop-allowed-after-command "$(head -c 200 "$T/g24s.out") / $(head -c 200 "$T/g24z.out")"

# 24b. 다른 Bash(ls), --help 만, 인자 없는 실행, 다른 skill 의 명령은 표시를 지우지 않음 → Stop 차단
bad24=""
i=0
for c in "'ls -la'" "'~/.claude/skills/xlsx/scripts/xlsx --help'" "'~/.claude/skills/xlsx/scripts/xlsx -h'" \
         "'~/.claude/skills/xlsx/scripts/xlsx'" "'~/.claude/skills/docx/scripts/docx from-md ./a.md ./a.docx'"; do
  i=$((i+1))
  hin "s24n$i" Skill xlsx '' > "$T/in24n.json"; run g24n "$T/in24n.json"
  bs "$T/in24nb.json" "s24n$i" "$c"; run g24nb "$T/in24nb.json"
  st "$T/in24ns.json" "s24n$i" False; run g24ns "$T/in24ns.json"
  allowed g24nb && isblock "$T/g24ns.out" && grep -qF 'scripts/xlsx' "$T/reason.txt" || bad24="$bad24 [#$i $(head -c 100 "$T/g24ns.out")]"
done
[ -z "$bad24" ] && pass stop-blocked-when-command-not-run || bad stop-blocked-when-command-not-run "$bad24"

# 25. Skill 을 안 부른 세션의 Stop 은 허용하고 상태 파일도 만들지 않음
st "$T/in25.json" s25 False; run g25 "$T/in25.json"
allowed g25 && [ ! -e "$STATE/s25" ] && [ ! -e "$STATE/s25.pending" ] && pass stop-allowed-without-skill || bad stop-allowed-without-skill "$(head -c 200 "$T/g25.out")"

# 25b. 명령 파일이 없는 skill(plugin skill)만 부른 세션의 Stop 은 허용
hin s25b Skill 'moai:doc-hwp' '' > "$T/in25b.json"; run g25b "$T/in25b.json"
st "$T/in25bs.json" s25b False; run g25bs "$T/in25bs.json"
allowed g25b && allowed g25bs && pass stop-allowed-skill-without-command || bad stop-allowed-skill-without-command "$(head -c 200 "$T/g25bs.out")"

# 25c. 거부된 Skill 재호출은 표시를 다시 세우지 않음: Skill → 명령 실행 → Skill(거부) → Stop 허용
hin s25c Skill xlsx 'read ./a.xlsx' > "$T/in25c.json"; run g25c "$T/in25c.json"
bs "$T/in25cb.json" s25c "'~/.claude/skills/xlsx/scripts/xlsx read ./a.xlsx'"; run g25cb "$T/in25cb.json"
run g25cc "$T/in25c.json"
st "$T/in25cs.json" s25c False; run g25cs "$T/in25cs.json"
allowed g25c && allowed g25cb && isdeny "$T/g25cc.out" && allowed g25cs && pass stop-denied-repeat-no-new-mark || bad stop-denied-repeat-no-new-mark "$(head -c 200 "$T/g25cs.out")"

# 25d. Stop 도 fail-open: JSON 아님, session_id 없음·위험, stop_hook_active 없음(표시 없을 때)
printf 'not json' > "$T/in25d.json"; run g25d "$T/in25d.json"
pj "$T/in25e.json" "{'hook_event_name':'Stop','stop_hook_active':False}"; run g25e "$T/in25e.json"
pj "$T/in25f.json" "{'session_id':'../x','hook_event_name':'Stop','stop_hook_active':False}"; run g25f "$T/in25f.json"
pj "$T/in25g.json" "{'session_id':'s25g','hook_event_name':'Stop'}"; run g25g "$T/in25g.json"
allowed g25d && allowed g25e && allowed g25f && allowed g25g && pass stop-fail-open || bad stop-fail-open "$(head -c 100 "$T/g25e.out") $(head -c 100 "$T/g25f.out")"

# 25e. 표시 파일 자리가 심볼릭 링크면 따라가지 않음(대상 파일을 지우거나 쓰지 않음)
hin s25h Skill xlsx '' > "$T/in25h0.json"
printf 'keep' > "$T/victim2"; ln -s "$T/victim2" "$STATE/s25h.pending"
run g25h "$T/in25h0.json"
st "$T/in25hs.json" s25h False; run g25hs "$T/in25hs.json"
[ "$(cat "$T/victim2")" = keep ] && [ "$(cat "$T/g25h.rc")" = 0 ] && [ "$(cat "$T/g25hs.rc")" = 0 ] && pass stop-pending-symlink-refused || bad stop-pending-symlink-refused "victim=$(cat "$T/victim2")"

# ---- codex 리뷰: 셸 모양 우회·오탐·표시 지우기 (따옴표·주석을 아는 검사) ----
# 26. 줄바꿈 뒤 명령, >|, tee 옵션·여러 대상, "<<EOF" 문자열·<<< here-string 뒤의 쓰기, md→오피스 이름 바꾸기(mv/cp)도 거부
bad26=""
i=0
for c in "'printf x > ./회의록.docx\\nprintf done'" "'printf x >| ./a.docx'" "'printf x | tee -- ./a.docx'" \
         "'printf x | tee ./a.md ./a.docx'" "'printf x | tee -i -a ./a.xlsx'" "'echo \"<<EOF\"\\nprintf x > ./a.docx'" \
         "'cat <<< \"hello\"\\nprintf x > ./a.docx'" "'mv ./회의록.md ./회의록.docx'" "'cp ./a.md ./a.docx'" \
         "'cp -f ./a.txt ./b.pptx'" "'mv ./a ./b.hwpx'" "'echo x &> ./a.docx'" "'cd ./x && echo x 1> ./a.docx'"; do
  i=$((i+1))
  bs "$T/in26.json" "s26x$i" "$c"; run g26 "$T/in26.json"
  isdeny "$T/g26.out" && grep -qF '[skill-guard]' "$T/reason.txt" || bad26="$bad26 [#$i $(head -c 120 "$T/g26.out")]"
done
[ -z "$bad26" ] && pass bash-office-bypass-forms-denied || bad bash-office-bypass-forms-denied "$bad26"

# 27. 따옴표 안의 '> a.docx' 글자, 주석, 오피스→오피스·폴더 복사, <<- 탭 heredoc 본문은 허용
bad27=""
i=0
for c in "'printf \"%s\" \"> a.docx\" > ./a.md'" "'cp ./a.docx ./b.docx # > example.docx'" \
         "'echo \"보고서는 > 회의록.docx 로\" > ./note.md'" "\"echo 'x > y.docx'\"" "'cp ./a.docx ./백업/'" \
         "'mv ./a.docx ./b.docx'" "'cp ./a.xlsx ./b.xlsx ./백업/'" "'ls ./*.docx 2>&1 | head'" \
         "\"cat > ./a.md <<'MD'\\nmv a.md a.docx\\nMD\"" "'cat <<-MD > ./a.md\\n\\t> b.docx\\n\\tMD'"; do
  i=$((i+1))
  bs "$T/in27.json" "s27y$i" "$c"; run g27 "$T/in27.json"
  allowed g27 || bad27="$bad27 [#$i $(head -c 120 "$T/g27.out")]"
done
[ -z "$bad27" ] && pass bash-quoted-comment-allowed || bad bash-quoted-comment-allowed "$bad27"

# 28. 실제로 돌리지 않는 글(echo 인자·주석·따옴표 친 "--help"·인자 없이 줄바꿈)은 표시를 지우지 않음 → Stop 차단
bad28=""
i=0
for c in "'echo ~/.claude/skills/xlsx/scripts/xlsx from-md ./a.md ./a.xlsx'" \
         "'# ~/.claude/skills/xlsx/scripts/xlsx from-md ./a.md ./a.xlsx'" \
         "'~/.claude/skills/xlsx/scripts/xlsx \"--help\"'" "'~/.claude/skills/xlsx/scripts/xlsx\\necho done'"; do
  i=$((i+1))
  hin "s28n$i" Skill xlsx '' > "$T/in28n.json"; run g28n "$T/in28n.json"
  bs "$T/in28nb.json" "s28n$i" "$c"; run g28nb "$T/in28nb.json"
  st "$T/in28ns.json" "s28n$i" False; run g28ns "$T/in28ns.json"
  allowed g28nb && isblock "$T/g28ns.out" || bad28="$bad28 [#$i $(head -c 100 "$T/g28ns.out")]"
done
[ -z "$bad28" ] && pass marker-not-cleared-by-non-run || bad marker-not-cleared-by-non-run "$bad28"

# 29. 따옴표 친 "$HOME/…" 실행 경로, && · ; 뒤 명령 자리, VAR=값 앞붙이, 파이프 앞 실행은 표시를 지움 → Stop 허용
bad29=""
i=0
for c in "'\"\$HOME/.claude/skills/xlsx/scripts/xlsx\" from-md ./a.md ./a.xlsx'" \
         "'cd ./x && ~/.claude/skills/xlsx/scripts/xlsx read ./a.xlsx'" \
         "'ls; /Users/u/.claude/skills/xlsx/scripts/xlsx read ./a.xlsx | head'" \
         "'LANG=C ~/.claude/skills/xlsx/scripts/xlsx read ./a.xlsx'"; do
  i=$((i+1))
  hin "s29n$i" Skill xlsx '' > "$T/in29n.json"; run g29n "$T/in29n.json"
  bs "$T/in29nb.json" "s29n$i" "$c"; run g29nb "$T/in29nb.json"
  st "$T/in29ns.json" "s29n$i" False; run g29ns "$T/in29ns.json"
  allowed g29nb && allowed g29ns || bad29="$bad29 [#$i $(head -c 100 "$T/g29ns.out")]"
done
[ -z "$bad29" ] && pass marker-cleared-by-real-run-forms || bad marker-cleared-by-real-run-forms "$bad29"

# 30. codex 2차: '>& 파일'(대상이 숫자·- 가 아니면 파일 쓰기)과 절대 경로 명령(/bin/cp, /usr/bin/tee)도 거부
bad30=""
i=0
for c in "'printf x >& ./a.docx'" "'printf x >&./a.docx'" "'/bin/cp ./a.md ./a.docx'" "'/bin/mv ./a.md ./a.xlsx'" \
         "'printf x | /usr/bin/tee ./a.pptx'"; do
  i=$((i+1))
  bs "$T/in30.json" "s30x$i" "$c"; run g30 "$T/in30.json"
  isdeny "$T/g30.out" && grep -qF '[skill-guard]' "$T/reason.txt" || bad30="$bad30 [#$i $(head -c 120 "$T/g30.out")]"
done
[ -z "$bad30" ] && pass bash-office-fd-redirect-abs-path-denied || bad bash-office-fd-redirect-abs-path-denied "$bad30"

# 31. fd 중복(>&2 · >& 2 · >&- · 1>&2)과 절대 경로 오피스→오피스 복사는 허용
bad31=""
i=0
for c in "'echo x >&2'" "'echo x >& 2'" "'echo x >&-'" "'echo x 1>&2 > ./a.md'" "'/bin/cp ./a.docx ./b.docx'"; do
  i=$((i+1))
  bs "$T/in31.json" "s31y$i" "$c"; run g31 "$T/in31.json"
  allowed g31 || bad31="$bad31 [#$i $(head -c 120 "$T/g31.out")]"
done
[ -z "$bad31" ] && pass bash-fd-dup-abs-copy-allowed || bad bash-fd-dup-abs-copy-allowed "$bad31"

# ---- 3차 실전 개선: 끝나지 않은 heredoc · 쓰기 거부 때 표시 · Stop 두 번 · 사용자 파일 이름 ----
# one <from-md 줄>: 안내에 그 한 인자 from-md 줄이 있고, 바로 뒤에 출력 경로(' ./')를 붙인 두 인자 형태는 없음(4차)
one() { grep -qF -- "$1" "$T/reason.txt" && ! grep -qF -- "$1 ./" "$T/reason.txt"; }
# 32. 오피스 쓰기 거부 안내는 거부된 파일 이름으로 정확한 from-md 명령을 준다(이름이 위험하면 ./이름 + 사용자 이름 안내)
bad32=""
wr "$T/in32.json" s32a Write './회의록.docx'; run g32 "$T/in32.json"
isdeny "$T/g32.out" && one '~/.claude/skills/docx/scripts/docx from-md ./회의록.md' || bad32="$bad32 [write $(head -c 160 "$T/reason.txt")]"
wr "$T/in32.json" s32b Write '/Users/u/문서/예산.XLSX'; run g32 "$T/in32.json"
isdeny "$T/g32.out" && one 'scripts/xlsx from-md ./예산.md' || bad32="$bad32 [abs $(head -c 160 "$T/reason.txt")]"
bs "$T/in32.json" s32c "\"cat > ./회의록.docx <<'MD'\\n# 회의록\\nMD\""; run g32 "$T/in32.json"
isdeny "$T/g32.out" && one 'scripts/docx from-md ./회의록.md' || bad32="$bad32 [redir $(head -c 160 "$T/reason.txt")]"
bs "$T/in32.json" s32d "'mv ./a.md ./발표자료.pptx'"; run g32 "$T/in32.json"
isdeny "$T/g32.out" && one 'scripts/pptx from-md ./발표자료.md' || bad32="$bad32 [mv $(head -c 160 "$T/reason.txt")]"
for f in './보고 서.docx' './-x.docx' "./a\$(id).docx"; do
  wr "$T/in32.json" s32e Write "$f"; run g32 "$T/in32.json"
  isdeny "$T/g32.out" && one 'from-md ./이름.md' && grep -qF '사용자가 말한' "$T/reason.txt" \
    && ! grep -qF '$(id)' "$T/reason.txt" || bad32="$bad32 [unsafe:$f $(head -c 160 "$T/reason.txt")]"
done
[ -z "$bad32" ] && pass office-deny-uses-file-name || bad office-deny-uses-file-name "$bad32"

# 33. Skill 없이 오피스 쓰기가 거부되면 표시를 남김 → Stop 차단, 안내에 '이미 읽었' 없음, 그 이름으로 from-md
wr "$T/in33.json" s33 Write './회의록.docx'; run g33 "$T/in33.json"
st "$T/in33s.json" s33 False; run g33s "$T/in33s.json"
if isdeny "$T/g33.out" && isblock "$T/g33s.out" && grep -qF '[skill-guard]' "$T/reason.txt" \
  && ! grep -qF '이미 읽었' "$T/reason.txt" && one '~/.claude/skills/docx/scripts/docx from-md ./회의록.md' \
  && grep -qF 'Bash 도구' "$T/reason.txt" && ! grep -qF '앞으로' "$T/reason.txt"; then
  pass stop-blocked-after-office-write-denied
else bad stop-blocked-after-office-write-denied "$(head -c 300 "$T/g33s.out")"; fi

# 33b. Bash 리다이렉트 거부도 표시를 남김 → Stop 차단(그 이름)
bs "$T/in33b.json" s33b "'printf x > ./예산안.xlsx'"; run g33b "$T/in33b.json"
st "$T/in33bs.json" s33b False; run g33bs "$T/in33bs.json"
isdeny "$T/g33b.out" && isblock "$T/g33bs.out" && one 'scripts/xlsx from-md ./예산안.md' \
  && pass stop-blocked-after-bash-office-denied || bad stop-blocked-after-bash-office-denied "$(head -c 300 "$T/g33bs.out")"

# 33c. 명령이 설치되지 않은 홈에서는 거부만 하고 표시를 남기지 않음 → Stop 허용
pj "$T/in33cs.json" "{'session_id':'s33c','transcript_path':'/x.jsonl','cwd':'/x','hook_event_name':'Stop','stop_hook_active':False}"
wr "$T/in33c.json" s33c Write './회의록.docx'
HOME="$EH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$PY" "$G" < "$T/in33c.json" > "$T/g33c.out" 2>/dev/null
HOME="$EH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$PY" "$G" < "$T/in33cs.json" > "$T/g33cs.out" 2>/dev/null; echo $? > "$T/g33cs.rc"
isdeny "$T/g33c.out" && allowed g33cs && [ ! -e "$STATE/s33c.pending" ] && pass office-deny-no-command-no-mark || bad office-deny-no-command-no-mark "$(head -c 200 "$T/g33cs.out")"

# 33d. 거부는 차단 횟수를 되돌리지 않음: Skill → Stop(차단1) → Write .xlsx 거부 → Stop(차단2, 새 이름) → Stop 허용
hin s33d Skill xlsx '' > "$T/in33d.json"; run g33d "$T/in33d.json"
st "$T/in33ds.json" s33d False; run g33d1 "$T/in33ds.json"
wr "$T/in33dw.json" s33d Write './예산.xlsx'; run g33dw "$T/in33dw.json"
st "$T/in33dt.json" s33d True; run g33d2 "$T/in33dt.json"
isblock "$T/g33d2.out"; r2=$?; one 'scripts/xlsx from-md ./예산.md'; r3=$?
run g33d3 "$T/in33dt.json"
allowed g33d && isblock "$T/g33d1.out" && isdeny "$T/g33dw.out" && [ $r2 -eq 0 ] && [ $r3 -eq 0 ] && allowed g33d3 \
  && pass office-deny-keeps-stop-count || bad office-deny-keeps-stop-count "r2=$r2 r3=$r3 $(head -c 200 "$T/g33d3.out")"

# 33e. 표시 파일 형식: 옛 형식(이름 한 줄)은 0번으로 보고 차단, 횟수 줄을 읽을 수 없으면 허용하고 표시를 지움
printf 'xlsx\n' > "$STATE/s33e.pending"; chmod 600 "$STATE/s33e.pending"
st "$T/in33e.json" s33e False; run g33e "$T/in33e.json"
printf 'xlsx\nzz\n' > "$STATE/s33f.pending"; chmod 600 "$STATE/s33f.pending"
st "$T/in33f.json" s33f False; run g33f "$T/in33f.json"
isblock "$T/g33e.out" && allowed g33f && [ ! -e "$STATE/s33f.pending" ] && pass stop-marker-format || bad stop-marker-format "$(head -c 200 "$T/g33e.out") / $(head -c 200 "$T/g33f.out")"

# 33f. 첫 차단 뒤 명령을 실제로 돌렸으면 다음 Stop(stop_hook_active=true)은 허용
hin s33g Skill xlsx '' > "$T/in33g.json"; run g33g "$T/in33g.json"
st "$T/in33gs.json" s33g False; run g33g1 "$T/in33gs.json"
bs "$T/in33gb.json" s33g "'~/.claude/skills/xlsx/scripts/xlsx from-md ./a.md ./a.xlsx'"; run g33gb "$T/in33gb.json"
st "$T/in33gt.json" s33g True; run g33g2 "$T/in33gt.json"
isblock "$T/g33g1.out" && allowed g33gb && allowed g33g2 && pass stop-allowed-after-run-following-block || bad stop-allowed-after-run-following-block "$(head -c 200 "$T/g33g2.out")"

# 34. 끝나지 않은 heredoc(끝 줄에 명령을 붙임·뒤 공백·끝 줄 없음·<<- 인데 공백 들여쓰기)은 거부:
#     [skill-guard], 구분자 이름, '혼자', '다음 줄'
bad34=""
i=0
for p in "MD|\"cat > ./a.md <<'MD'\\n# 제목\\nMD && ~/.claude/skills/xlsx/scripts/xlsx from-md ./a.md ./a.xlsx\"" \
         "MD|'cat > ./a.md <<MD\\n본문\\nMD '" "EOF|\"cat <<'EOF' > ./a.md\\n본문\"" \
         "MD|'cat > ./a.md <<-MD\\n\\t본문\\n  MD'" "MD|\"cat > ./a.md <<'MD'\\n본문\\nMD;\""; do
  i=$((i+1))
  bs "$T/in34.json" "s34x$i" "${p#*|}"; run g34 "$T/in34.json"
  isdeny "$T/g34.out" && grep -qF '[skill-guard]' "$T/reason.txt" && grep -qF "${p%%|*}" "$T/reason.txt" \
    && grep -qF '혼자' "$T/reason.txt" && grep -qF '다음 줄' "$T/reason.txt" && [ ! -e "$STATE/s34x$i.pending" ] \
    || bad34="$bad34 [#$i $(head -c 160 "$T/g34.out")]"
done
[ -z "$bad34" ] && pass bash-unclosed-heredoc-denied || bad bash-unclosed-heredoc-denied "$bad34"

# 34b. 닫힌 heredoc·산술 <<·here-string·따옴표 속 <<·여러 heredoc·$( ) 안 heredoc·python 표준 입력·끝나지 않은 따옴표는 허용
bad34=""
i=0
for c in "\"cat > ./a.md <<'MD'\\n본문\\nMD\\n\"" "'echo \$((1<<2))'" "'cat <<< \"MD\"'" "'echo \"<<MD\"'" \
         "'cat > ./a.md <<A\\nx\\nA\\ncat > ./b.md <<B\\ny\\nB'" "'cat <<A > ./a.md; cat <<B > ./b.md\\na\\nA\\nb\\nB'" \
         "\"x=\$(cat <<'EOF'\\n본문\\nEOF\\n)\"" "\"python3 - <<'PY'\\nprint(1)\\nPY\"" "'echo \"abc'" \
         "'cat <<\"MD\" > ./a.md\\nx\\nMD'"; do
  i=$((i+1))
  bs "$T/in34b.json" "s34y$i" "$c"; run g34b "$T/in34b.json"
  allowed g34b || bad34="$bad34 [#$i $(head -c 160 "$T/g34b.out")]"
done
[ -z "$bad34" ] && pass bash-closed-heredoc-forms-allowed || bad bash-closed-heredoc-forms-allowed "$bad34"

# 34c. 끝나지 않은 heredoc 안의 명령은 돌지 않으므로 표시를 지우지 않음 → Stop 차단
hin s34c Skill xlsx '' > "$T/in34c.json"; run g34c "$T/in34c.json"
bs "$T/in34cb.json" s34c "\"cat > ./a.md <<'MD'\\n# 제목\\nMD && ~/.claude/skills/xlsx/scripts/xlsx from-md ./a.md ./a.xlsx\""; run g34cb "$T/in34cb.json"
st "$T/in34cs.json" s34c False; run g34cs "$T/in34cs.json"
allowed g34c && isdeny "$T/g34cb.out" && isblock "$T/g34cs.out" && pass unclosed-heredoc-keeps-mark || bad unclosed-heredoc-keeps-mark "$(head -c 200 "$T/g34cs.out")"

# 35. 오피스 SKILL.md: 사용자가 말한 파일 이름을 쓰라는 규칙, 끝 MD 는 혼자 한 줄·명령은 다음 줄
bad35=""
for n in docx xlsx pptx; do
  f="$KIT/skills/$n/SKILL.md"
  grep -qF '사용자가 말한 파일 이름' "$f" && grep -qF 'MD 는 혼자 한 줄' "$f" && grep -qF '다음 줄' "$f" || bad35="$bad35 [$n]"
done
[ -z "$bad35" ] && pass office-skill-md-name-and-heredoc-rules || bad office-skill-md-name-and-heredoc-rules "$bad35"

# 36. 서브셸 ( )·명령 치환 $( )·{ } 안의 heredoc 도 heredoc 이다(본문을 명령으로 읽지 않음). 산술 (( )) 의 << 만 아님
bad36=""
i=0
for c in "\"(cat > ./a.md <<'MD'\\n> 회의록.docx\\nMD\\n)\"" "\"x=\$(cat <<'EOF'\\n> 회의록.docx\\nEOF\\n)\"" \
         "\"{ cat > ./a.md <<'MD'\\n> 회의록.docx\\nMD\\n}\"" "'echo \$(( 1 << 2 )); (( y = 1 << 3 ))'" \
         "\"(cd ./d && cat > ./a.md <<'MD'\\n본문\\nMD\\n) && echo \$((2<<1))\""; do
  i=$((i+1))
  bs "$T/in36.json" "s36y$i" "$c"; run g36 "$T/in36.json"
  allowed g36 || bad36="$bad36 [#$i $(head -c 160 "$T/g36.out")]"
done
[ -z "$bad36" ] && pass subshell-heredoc-body-not-commands || bad subshell-heredoc-body-not-commands "$bad36"

# 36b. 서브셸 안에서 끝나지 않은 heredoc 도 거부하고, 그 안의(돌지 않는) skill 명령은 표시를 지우지 않음 → Stop 차단
hin s36b Skill xlsx '' > "$T/in36b.json"; run g36b "$T/in36b.json"
bs "$T/in36bb.json" s36b "\"(cat > ./a.md <<'MD'\\n# 제목\\nMD && ~/.claude/skills/xlsx/scripts/xlsx from-md ./a.md ./a.xlsx)\""; run g36bb "$T/in36bb.json"
rm -f "$T/reason.txt"; isdeny "$T/g36bb.out" && grep -qF '혼자' "$T/reason.txt"; r36=$?
st "$T/in36bs.json" s36b False; run g36bs "$T/in36bs.json"
allowed g36b && [ "$r36" = 0 ] && isblock "$T/g36bs.out" && pass subshell-unclosed-heredoc-denied-keeps-mark || bad subshell-unclosed-heredoc-denied-keeps-mark "$(head -c 200 "$T/g36bb.out") / $(head -c 120 "$T/g36bs.out")"

# 37. 오피스 거부 뒤 첫 Skill 호출은 표시의 차단 횟수와(같은 skill 이면) 이름을 지우지 않음
wr "$T/in37w.json" s37 Write './회의록.docx'; run g37w "$T/in37w.json"
st "$T/in37s.json" s37 False; run g37s1 "$T/in37s.json"
hin s37 Skill docx '' > "$T/in37k.json"; run g37k "$T/in37k.json"
m37=$(cat "$STATE/s37.pending" 2>/dev/null)
st "$T/in37t.json" s37 True; run g37s2 "$T/in37t.json"
isblock "$T/g37s2.out"; r2=$?; one 'scripts/docx from-md ./회의록.md'; r3=$?
run g37s3 "$T/in37t.json"
isdeny "$T/g37w.out" && isblock "$T/g37s1.out" && allowed g37k && [ "$m37" = "$(printf 'docx\n1\n회의록')" ] \
  && [ $r2 -eq 0 ] && [ $r3 -eq 0 ] && allowed g37s3 \
  && pass skill-after-office-deny-keeps-marker || bad skill-after-office-deny-keeps-marker "m=[$m37] r2=$r2 r3=$r3 $(head -c 160 "$T/g37s3.out")"

# 38. ANSI-C 따옴표 끝 표시 <<$'EOF' 는 bash 처럼 EOF 로 닫힘(거부하지 않음)
bs "$T/in38.json" s38 "\"cat > ./a.md <<\$'EOF'\\n# 제목\\nEOF\\n\""; run g38 "$T/in38.json"
allowed g38 && pass ansi-c-heredoc-delimiter || bad ansi-c-heredoc-delimiter "$(head -c 200 "$T/g38.out")"

# 39. 깨진 횟수 줄: 여러 줄 기록에서 빈 횟수 줄, 아주 긴 숫자 → Stop 허용 + 표시 지움
printf 'docx\n\nreport\n' > "$STATE/s39a.pending"; chmod 600 "$STATE/s39a.pending"
st "$T/in39a.json" s39a False; run g39a "$T/in39a.json"
{ printf 'docx\n'; head -c 5000 /dev/zero | tr '\0' '7'; printf '\nreport\n'; } > "$STATE/s39b.pending"; chmod 600 "$STATE/s39b.pending"
st "$T/in39b.json" s39b False; run g39b "$T/in39b.json"
allowed g39a && [ ! -e "$STATE/s39a.pending" ] && allowed g39b && [ ! -e "$STATE/s39b.pending" ] \
  && pass stop-marker-bad-count-cleared || bad stop-marker-bad-count-cleared "$(head -c 120 "$T/g39a.out") / $(head -c 120 "$T/g39b.out") / $(ls "$STATE" | grep s39)"

# 40. 따옴표 없는 heredoc 본문의 \<줄바꿈> 은 bash 처럼 이어 붙임
#   a) EO\<줄바꿈>F 는 EOF 끝 표시 → 거부하지 않음
#   b) x\<줄바꿈>EOF 는 xEOF(끝 표시 아님) → 다음 줄의 skill 명령은 본문이라 표시를 지우지 않음 → Stop 차단
bs "$T/in40a.json" s40a '"cat > ./a.md <<EOF\n# 제목\nEO\\\nF\n"'; run g40a "$T/in40a.json"
hin s40b Skill xlsx '' > "$T/in40b.json"; run g40b "$T/in40b.json"
bs "$T/in40bb.json" s40b '"cat > ./a.md <<EOF\n# 제목 x\\\nEOF\n~/.claude/skills/xlsx/scripts/xlsx from-md ./a.md ./a.xlsx\n"'; run g40bb "$T/in40bb.json"
st "$T/in40bs.json" s40b False; run g40bs "$T/in40bs.json"
allowed g40a && allowed g40b && isblock "$T/g40bs.out" \
  && pass heredoc-backslash-newline-fold || bad heredoc-backslash-newline-fold "$(head -c 160 "$T/g40a.out") / $(head -c 160 "$T/g40bs.out")"

# ---- 4차 실전 개선: 한 인자 from-md · 끝 답의 '만들었다' 주장 검사 · 사용자 요청에서 이름 · SKILL 첫 줄 ----
# sx <out-file> <session> <cwd|NONE> <last_assistant_message|NONE> [transcript_path] : 끝 답이 든 Stop 입력
sx() {
  "$PY" -I -c '
import json,sys
o={"session_id":sys.argv[2],"transcript_path":sys.argv[5] if len(sys.argv)>5 else "/x.jsonl","hook_event_name":"Stop","stop_hook_active":False}
if sys.argv[3]!="NONE": o["cwd"]=sys.argv[3]
if sys.argv[4]!="NONE": o["last_assistant_message"]=sys.argv[4]
open(sys.argv[1],"w",encoding="utf-8").write(json.dumps(o,ensure_ascii=False))' "$@"
}
C41="$T/c41"; mkdir -p "$C41"
printf 'PK\003\004진짜 zip 머리' > "$C41/예산.xlsx"
printf '# 그냥 글\n' > "$C41/보고.pptx"

# 41. 도구를 안 부르고 '회의록.docx 를 만들었다'고 끝내면(표시 없음) 한 번 막는다: 파일이 없다·이번 답에서 Bash 도구로
#     한 인자 from-md 를 돌리거나, 아니면 만들지 못했다고 사실대로 말하라. 두 번째 Stop 은 허용(세션당 한 번).
sx "$T/in41a.json" s41a "$C41" '회의록.docx 파일을 생성했습니다. 확인해 보세요.'; run g41a "$T/in41a.json"
if [ "$(cat "$T/g41a.rc")" = 0 ] && isblock "$T/g41a.out" && grep -qF '[skill-guard]' "$T/reason.txt" && grep -qF '회의록.docx' "$T/reason.txt" \
  && grep -qF '없' "$T/reason.txt" && grep -qF 'Bash 도구' "$T/reason.txt" && one '~/.claude/skills/docx/scripts/docx from-md ./회의록.md' \
  && grep -qF '사실대로' "$T/reason.txt" && ! grep -qF '앞으로' "$T/reason.txt"; then
  run g41a2 "$T/in41a.json"
  allowed g41a2 && pass stop-claim-missing-file-blocked-once || bad stop-claim-missing-file-blocked-once "second: $(head -c 200 "$T/g41a2.out")"
else bad stop-claim-missing-file-blocked-once "rc=$(cat "$T/g41a.rc") $(head -c 300 "$T/g41a.out")"; fi

# 41b. 주장한 파일이 cwd 에 실제로 있고 zip(PK\3\4) 머리면 허용
sx "$T/in41b.json" s41b "$C41" '예산.xlsx 를 만들었습니다.'; run g41b "$T/in41b.json"
allowed g41b && pass stop-claim-real-file-allowed || bad stop-claim-real-file-allowed "$(head -c 200 "$T/g41b.out")"

# 41c. 같은 이름의 파일이 있어도 zip 이 아니면(Write 로 쓴 글) 막는다. 백틱으로 감싼 이름도 찾는다.
sx "$T/in41c.json" s41c "$C41" '`보고.pptx` 저장을 완료했습니다.'; run g41c "$T/in41c.json"
isblock "$T/g41c.out" && one 'scripts/pptx from-md ./보고.md' && pass stop-claim-non-zip-blocked || bad stop-claim-non-zip-blocked "$(head -c 300 "$T/g41c.out")"

# 41d. 꾸밈·경로 형태: **`절대경로`**, 작은따옴표, ~/ (HOME 기준), 영어 문장 모두 찾아 막는다(각 이름으로 한 인자 from-md)
bad41=""
i=0
for m in "**\`$C41/없는폴더/결과.docx\`** 를 생성했습니다." "'예산안.xlsx' 파일이 생성되었습니다." \
         "~/보고서.hwpx 에 저장했습니다." "Created report.docx successfully."; do
  i=$((i+1))
  sx "$T/in41d.json" "s41d$i" "$C41" "$m"; run g41d "$T/in41d.json"
  case $i in 1) w='scripts/docx from-md ./결과.md';; 2) w='scripts/xlsx from-md ./예산안.md';; 3) w='scripts/hwpx from-md ./보고서.md';; 4) w='scripts/docx from-md ./report.md';; esac
  isblock "$T/g41d.out" && one "$w" || bad41="$bad41 [#$i $(head -c 160 "$T/g41d.out")]"
done
[ -z "$bad41" ] && pass stop-claim-name-forms || bad stop-claim-name-forms "$bad41"

# 41e. 막지 않음: 부정 문장(못/않/실패/could not), 만들었다는 말이 없는 문장, cwd 없음·없는 폴더, 끝 답 없음·문자열 아님,
#      명령이 설치되지 않은 홈
bad41=""
i=0
for m in '회의록.docx 파일을 만들지 못했습니다.' '회의록.docx 생성에 실패했습니다.' '회의록.docx 는 저장하지 않았습니다.' \
         'I could not create report.docx.' '회의록.docx 라는 이름이 괜찮을까요?'; do
  i=$((i+1))
  sx "$T/in41e.json" "s41e$i" "$C41" "$m"; run g41e "$T/in41e.json"
  allowed g41e || bad41="$bad41 [neg#$i $(head -c 120 "$T/g41e.out")]"
done
sx "$T/in41f.json" s41f NONE '회의록.docx 파일을 생성했습니다.'; run g41f "$T/in41f.json"; allowed g41f || bad41="$bad41 [no-cwd]"
sx "$T/in41g.json" s41g "$T/없는폴더" '회의록.docx 파일을 생성했습니다.'; run g41g "$T/in41g.json"; allowed g41g || bad41="$bad41 [bad-cwd]"
sx "$T/in41h.json" s41h "$C41" NONE; run g41h "$T/in41h.json"; allowed g41h || bad41="$bad41 [no-msg]"
pj "$T/in41i.json" "{'session_id':'s41i','cwd':'$C41','hook_event_name':'Stop','stop_hook_active':False,'last_assistant_message':['회의록.docx 생성']}"
run g41i "$T/in41i.json"; allowed g41i || bad41="$bad41 [msg-not-str]"
sx "$T/in41j.json" s41j "$C41" '회의록.docx 파일을 생성했습니다.'
HOME="$EH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$PY" "$G" < "$T/in41j.json" > "$T/g41j.out" 2>/dev/null; echo $? > "$T/g41j.rc"
allowed g41j || bad41="$bad41 [no-command]"
[ -z "$bad41" ] && pass stop-claim-not-blocked-cases || bad stop-claim-not-blocked-cases "$bad41"

# 41f. 여러 이름 중 없는 것만 이유에 든다(있는 진짜 파일 이름은 들지 않음)
sx "$T/in41k.json" s41k "$C41" '예산.xlsx 와 요약.docx 를 모두 만들었습니다.'; run g41k "$T/in41k.json"
isblock "$T/g41k.out" && grep -qF '요약.docx' "$T/reason.txt" && ! grep -qF '예산.xlsx' "$T/reason.txt" \
  && pass stop-claim-only-missing-named || bad stop-claim-only-missing-named "$(head -c 300 "$T/g41k.out")"

# 41g. Skill 표시가 있으면 표시 쪽 차단이 먼저(원래 요청대로 안내)
hin s41l Skill xlsx '' > "$T/in41l.json"; run g41l "$T/in41l.json"
sx "$T/in41ls.json" s41l "$C41" '예산표.xlsx 를 만들었습니다.'; run g41ls "$T/in41ls.json"
allowed g41l && isblock "$T/g41ls.out" && grep -qF '원래 요청대로' "$T/reason.txt" && pass stop-marker-before-claim || bad stop-marker-before-claim "$(head -c 300 "$T/g41ls.out")"

# 42. Skill 만 부르고 멈춘 세션: 대화 기록(transcript)의 마지막 사용자 요청(last-prompt)에서 그 종류의 파일 이름을 꺼내
#     Stop 안내에 그 이름으로 한 인자 from-md 를 준다. 옛 요청·다른 종류 이름·깨진 줄은 무시.
"$PY" -I - "$T/t42.jsonl" "$T/t42b.jsonl" <<'EOF'
import json,sys
def w(p, rows):
    with open(p,"w",encoding="utf-8") as f:
        for r in rows: f.write((r if isinstance(r,str) else json.dumps(r,ensure_ascii=False))+"\n")
base=[{"type":"queue-operation","operation":"enqueue"},
      {"type":"last-prompt","lastPrompt":"옛보고.xlsx 파일을 열어 줘"},
      {"type":"user","message":{"role":"user","content":"옛보고.xlsx 파일을 열어 줘"}},
      {"type":"api-request-blob","blob":"x"*(3<<20)},
      {"type":"last-prompt","lastPrompt":"'예산.xlsx 엑셀 파일을 만들어 줘. 시트 이름은 예산, 머리 행은 항목과 금액(천원). 회의록.docx 는 나중에.'"},
      "{깨진 줄",
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"알겠습니다"}]}}]
w(sys.argv[1], base)
w(sys.argv[2], [{"type":"last-prompt","lastPrompt":"회의록.docx 를 만들어 줘"}])
EOF
pj "$T/in42a.json" "{'session_id':'s42','transcript_path':'$T/t42.jsonl','cwd':'$C41','hook_event_name':'PreToolUse','tool_name':'Skill','tool_input':{'skill':'xlsx','args':''}}"
run g42a "$T/in42a.json"
sx "$T/in42s.json" s42 "$C41" '엑셀 작업 방법을 이해했습니다.' "$T/t42.jsonl"
t0=$(date +%s); run g42s "$T/in42s.json"; t1=$(date +%s)
allowed g42a && isblock "$T/g42s.out" && one '~/.claude/skills/xlsx/scripts/xlsx from-md ./예산.md' && ! grep -qF '옛보고' "$T/reason.txt" \
  && ! grep -qF './이름.md' "$T/reason.txt" && [ $((t1-t0)) -lt 3 ] \
  && pass stop-stem-from-last-prompt || bad stop-stem-from-last-prompt "$((t1-t0))s $(head -c 300 "$T/g42s.out")"

# 42b. 요청에 그 종류 이름이 없으면(docx 이름뿐인데 Skill xlsx), 기록이 없거나 폴더면 지어내지 않고 ./이름 + 사용자 이름 안내
bad42=""
for tp in "$T/t42b.jsonl" "$T/없음.jsonl" "$T"; do
  sid="s42b$(printf %s "$tp" | cksum | cut -d' ' -f1)"
  pj "$T/in42b.json" "{'session_id':'$sid','transcript_path':'''$tp''','cwd':'$C41','hook_event_name':'PreToolUse','tool_name':'Skill','tool_input':{'skill':'xlsx','args':''}}"
  run g42b "$T/in42b.json"
  sx "$T/in42bs.json" "$sid" "$C41" NONE "$tp"; run g42bs "$T/in42bs.json"
  allowed g42b && isblock "$T/g42bs.out" && one 'scripts/xlsx from-md ./이름.md' && grep -qF '사용자가 말한' "$T/reason.txt" \
    && ! grep -qF '회의록' "$T/reason.txt" || bad42="$bad42 [$tp $(head -c 120 "$T/g42bs.out")]"
done
[ -z "$bad42" ] && pass stop-stem-fallback || bad stop-stem-fallback "$bad42"

# 43. 한 인자 from-md 로 실행해도 표시를 지움 → Stop 허용
hin s43 Skill xlsx '' > "$T/in43.json"; run g43 "$T/in43.json"
bs "$T/in43b.json" s43 "\"cat > ./예산.md <<'MD'\\n## 예산\\n| 항목 | 금액 |\\n| --- | --- |\\n| 인건비 | 1 |\\nMD\\n~/.claude/skills/xlsx/scripts/xlsx from-md ./예산.md\""; run g43b "$T/in43b.json"
st "$T/in43s.json" s43 False; run g43s "$T/in43s.json"
allowed g43 && allowed g43b && allowed g43s && [ ! -e "$STATE/s43.pending" ] && pass one-arg-run-clears-marker || bad one-arg-run-clears-marker "$(head -c 200 "$T/g43b.out") / $(head -c 200 "$T/g43s.out")"

# 44. 오피스 SKILL.md(docx xlsx pptx hwpx): 두 인자 from-md 예시·'두 경로를 꼭' 없음, 한 인자 예시 있음,
#     본문 앞 3줄 안에 '지금 바로' Bash 실행과 '이해했습니다' 같은 글 답으로 끝내지 말라는 말
bad44=""
for n in docx xlsx pptx hwpx; do
  f="$KIT/skills/$n/SKILL.md"
  head3="$(awk 'c>=2 && n<3 {print; n++} /^---$/ {c++}' "$f")"
  ! grep -qE "from-md +[^ ]+\.md +\./[^ ]+\.$n" "$f" && ! grep -qF '두 경로를 꼭' "$f" \
    && grep -qE "skills/$n/scripts/$n from-md \./[^ ]+\.md *\$" "$f" \
    && printf %s "$head3" | grep -qF '지금 바로' && printf %s "$head3" | grep -qF 'Bash' && printf %s "$head3" | grep -qF '이해했습니다' \
    || bad44="$bad44 [$n]"
done
[ -z "$bad44" ] && pass office-skill-md-one-arg-imperative || bad office-skill-md-one-arg-imperative "$bad44"


# 45. 끝 답 주장 검사 보강(codex 리뷰): 멈춤 없음 · 이름 뽑기 · 물음/영어 부정 · 옛 형식 제외
# runt <name> <in> : 5초 제한으로 실행(멈추면 rc 142)
runt() {
  HOME="$FH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$PY" perl -e 'alarm shift; exec @ARGV' 5 "$G" < "$2" > "$T/$1.out" 2> "$T/$1.err"; echo $? > "$T/$1.rc"
}
C45="$T/c45"; mkdir -p "$C45/sub"
mkfifo "$C45/파이프.docx"
ln -s "$C41/예산.xlsx" "$C45/링크.xlsx"
printf 'PK\003\004a' > "$C45/quarterly report.docx"
printf 'PK\003\004a' > "$C45/주간 보고.docx"
printf 'PK\003\004a' > "$C45/sub/결과.pptx"
printf '\320\317\021\340\241\261\032\341old' > "$C45/옛문서.doc"
printf '\320\317\021\340\241\261\032\341old' > "$C45/옛보고.hwp"

# 45a. FIFO(쓰는 쪽 없음)를 주장해도 멈추지 않고 일반 파일이 아니므로 막는다. 두 번째 Stop 도 멈추지 않고 허용.
sx "$T/in45a.json" s45a "$C45" '파이프.docx 를 생성했습니다.'; runt g45a "$T/in45a.json"; runt g45a2 "$T/in45a.json"
[ "$(cat "$T/g45a.rc")" = 0 ] && isblock "$T/g45a.out" && one 'scripts/docx from-md ./파이프.md' && allowed g45a2 \
  && pass stop-claim-fifo-no-hang || bad stop-claim-fifo-no-hang "rc=$(cat "$T/g45a.rc")/$(cat "$T/g45a2.rc") $(head -c 200 "$T/g45a.out")"

# 45b. 허용: 진짜 zip 을 가리키는 심볼릭 링크, 백틱 안 띄어쓰기 이름(영어·한글), 확장자 뒤에 더 붙은 이름(.docx.md),
#      Markdown 링크(대상 경로 기준), 물음 문장, 영어 부정(not / n't / never), 옛 형식(.doc .hwp, 있든 없든)
bad45=""
i=0
for m in '링크.xlsx 를 만들었습니다.' 'Created `quarterly report.docx`.' '`주간 보고.docx` 를 저장했습니다.' \
         'Created report.docx.md as the source.' '회의록.docx.md 를 저장했습니다.' \
         "[결과.pptx]($C45/sub/결과.pptx) 를 생성했습니다." \
         'Have you created report.docx?' '회의록.docx 를 생성할까요?' 'I have not created report.docx.' \
         'report.docx was not saved.' "I didn't create report.docx." 'I never saved report.docx.' \
         '옛문서.doc 와 옛보고.hwp 를 저장했습니다.' '없는문서.doc 를 저장했습니다.'; do
  i=$((i+1))
  sx "$T/in45b.json" "s45b$i" "$C45" "$m"; runt g45b "$T/in45b.json"
  allowed g45b || bad45="$bad45 [#$i $(head -c 140 "$T/g45b.out")]"
done
[ -z "$bad45" ] && pass stop-claim-allowed-forms || bad stop-claim-allowed-forms "$bad45"

# 45c. 끝 답 맨 끝의 마침표(뒤에 공백 없음)는 이름의 일부가 아니다 → 막고 그 이름으로 안내
sx "$T/in45c.json" s45c "$C45" 'Created summary.xlsx.'; runt g45c "$T/in45c.json"
isblock "$T/g45c.out" && one 'scripts/xlsx from-md ./summary.md' && pass stop-claim-trailing-dot || bad stop-claim-trailing-dot "$(head -c 200 "$T/g45c.out")"

# 46. 한국어 조사가 바로 붙은 이름(회의록.docx를 / 보고서.xlsx로 / "발표.pptx"라는)도 이름으로 찾는다.
#     확장자 바로 뒤가 영문·숫자·_ 이거나 .영문 이면 이름이 아니다(report.docx.md를 은 여전히 이름 아님).
bad46=""
i=0
for m in '회의록.docx를 생성했습니다.' '보고서.xlsx로 저장했습니다.' '"발표.pptx"라는 파일을 만들었습니다.' '`기안.hwpx`를 작성 완료했습니다.'; do
  i=$((i+1))
  sx "$T/in46a.json" "s46a$i" "$C41" "$m"; runt g46a "$T/in46a.json"
  case $i in 1) w='scripts/docx from-md ./회의록.md';; 2) w='scripts/xlsx from-md ./보고서.md';; 3) w='scripts/pptx from-md ./발표.md';; 4) w='scripts/hwpx from-md ./기안.md';; esac
  [ "$(cat "$T/g46a.rc")" = 0 ] && isblock "$T/g46a.out" && one "$w" || bad46="$bad46 [block#$i $(head -c 160 "$T/g46a.out")]"
done
i=0
for m in 'report.docx.md를 저장했습니다.' '회의록.docx.md로 저장했습니다.' '예산.xlsx를 만들었습니다.' '회의록.docx를 만들지 못했습니다.' \
         'report.docx2 를 저장했습니다.' 'report.docx_old 를 저장했습니다.'; do
  i=$((i+1))
  sx "$T/in46b.json" "s46b$i" "$C41" "$m"; runt g46b "$T/in46b.json"
  allowed g46b || bad46="$bad46 [allow#$i $(head -c 160 "$T/g46b.out")]"
done
[ -z "$bad46" ] && pass stop-claim-korean-particle || bad stop-claim-korean-particle "$bad46"

# 46b. 마지막 사용자 요청의 이름에 조사·따옴표가 붙어도 stem 을 찾는다. .docx.md 꼴은 이름이 아니다(./이름.md 안내).
"$PY" -I - "$T/t46a.jsonl" "$T/t46b.jsonl" "$T/t46c.jsonl" <<'EOF'
import json,sys
for p, text in zip(sys.argv[1:], ["주간회의록.docx로 만들어줘", "\"분기보고.docx\"라는 이름으로 저장해 줘", "report.docx.md로 만들어줘"]):
    with open(p, "w", encoding="utf-8") as f:
        f.write(json.dumps({"type":"last-prompt","lastPrompt":text}, ensure_ascii=False) + "\n")
EOF
bad46=""
i=0
for tp in "$T/t46a.jsonl" "$T/t46b.jsonl" "$T/t46c.jsonl"; do
  i=$((i+1))
  hin "s46c$i" Skill docx '' > "$T/in46c.json"; run g46c "$T/in46c.json"
  sx "$T/in46cs.json" "s46c$i" "$C41" '문서 작성 방법을 이해했습니다.' "$tp"; runt g46cs "$T/in46cs.json"
  case $i in 1) w='scripts/docx from-md ./주간회의록.md';; 2) w='scripts/docx from-md ./분기보고.md';; 3) w='scripts/docx from-md ./이름.md';; esac
  allowed g46c && isblock "$T/g46cs.out" && one "$w" || bad46="$bad46 [#$i $(head -c 200 "$T/g46cs.out")]"
done
[ -z "$bad46" ] && pass stop-stem-korean-particle || bad stop-stem-korean-particle "$bad46"

# 47. 끝 답 주장 검사 보강 2(codex 재검토): 긴 글에서 제곱 시간 없음 · +·괄호 이름 · Markdown 링크 대상 해석 ·
#     파일 이름만으로 주장 말이 되지 않음 · 만드는 방법 안내(…하려면 …하세요 / To create …)는 주장이 아님
C47="$T/c47"; mkdir -p "$C47"
printf 'PK\003\004a' > "$C47/report+final.docx"
printf 'PK\003\004a' > "$C47/my report.docx"
printf 'PK\003\004a' > "$C47/보고서 (최종).docx"
# 47a. 20만 자 끝 답(이름 없는 긴 낱말, 닫히지 않은 [ 반복, 경로 모양 반복)도 5초 안에 끝나고 허용한다.
#      긴 글 맨 끝의 진짜 주장은 여전히 찾아 막는다. 긴 사용자 요청(30만 자)에서도 stem 을 5초 안에 찾는다.
"$PY" -I - "$T" "$C47" <<'EOF'
import json,sys
t,c=sys.argv[1],sys.argv[2]
msgs=["Created "+"a"*200000, "["*200000+" 를 저장했습니다", "Created "+"a/"*100000, "저장 "+"[a]("*50000,
      "x"*200000+"\n회의록.docx를 생성했습니다."]
for i,m in enumerate(msgs,1):
    o={"session_id":"s47a%d"%i,"transcript_path":"/x.jsonl","hook_event_name":"Stop","stop_hook_active":False,"cwd":c,"last_assistant_message":m}
    open("%s/in47a%d.json"%(t,i),"w",encoding="utf-8").write(json.dumps(o,ensure_ascii=False))
open("%s/t47.jsonl"%t,"w",encoding="utf-8").write(json.dumps({"type":"last-prompt","lastPrompt":"a"*300000+" 주간.docx로 만들어줘"},ensure_ascii=False)+"\n")
EOF
bad47=""
for i in 1 2 3 4; do
  runt g47a "$T/in47a$i.json"; allowed g47a || bad47="$bad47 [long#$i rc=$(cat "$T/g47a.rc") $(head -c 120 "$T/g47a.out")]"
done
runt g47a5 "$T/in47a5.json"
[ "$(cat "$T/g47a5.rc")" = 0 ] && isblock "$T/g47a5.out" && one 'scripts/docx from-md ./회의록.md' || bad47="$bad47 [long-claim rc=$(cat "$T/g47a5.rc") $(head -c 120 "$T/g47a5.out")]"
hin s47t Skill docx '' > "$T/in47t.json"; run g47t "$T/in47t.json"
sx "$T/in47ts.json" s47t "$C47" '문서 작성 방법을 이해했습니다.' "$T/t47.jsonl"; runt g47ts "$T/in47ts.json"
[ "$(cat "$T/g47ts.rc")" = 0 ] && isblock "$T/g47ts.out" && one 'scripts/docx from-md ./주간.md' || bad47="$bad47 [long-prompt rc=$(cat "$T/g47ts.rc") $(head -c 120 "$T/g47ts.out")]"
[ -z "$bad47" ] && pass stop-claim-long-input-linear || bad stop-claim-long-input-linear "$bad47"

# 47b. 허용: 있는 + · 괄호 이름(백틱 안팎), %20 이 든 Markdown 링크 대상(풀어서 확인), 웹 주소(링크 대상·맨 글 모두 로컬
#      파일 주장 아님), 이름에만 주장 말이 든 문장(created.docx / saved.xlsx), 만드는 방법 안내(…하려면 …하세요 / To create …)
bad47=""
i=0
for m in 'Created `report+final.docx`.' 'report+final.docx를 만들었습니다.' '`보고서 (최종).docx`를 저장했습니다.' \
         'Created [report](my%20report.docx).' '[보고서](https://example.com/report.docx)를 저장했습니다.' \
         'https://example.com/report.docx 에 저장했습니다.' 'The filename is `created.docx`.' 'saved.xlsx 파일입니다.' \
         '보고서.docx를 생성하려면 아래 명령을 실행하세요.' 'To create report.docx, run the command below.'; do
  i=$((i+1))
  sx "$T/in47b.json" "s47b$i" "$C47" "$m"; runt g47b "$T/in47b.json"
  allowed g47b || bad47="$bad47 [allow#$i $(head -c 160 "$T/g47b.out")]"
done
[ -z "$bad47" ] && pass stop-claim-allowed-forms-2 || bad stop-claim-allowed-forms-2 "$bad47"

# 47c. 여전히 막음: 없는 파일을 가리키는 로컬 Markdown 링크, 이름 밖에도 주장 말이 있는 문장(saved.xlsx를 저장했습니다),
#      주장 다음 문장의 권유(…생성했습니다. 열어 보세요.), 없는 + 이름
bad47=""
i=0
for m in '[회의록](회의록.docx)을 저장했습니다.' 'saved.xlsx를 저장했습니다.' '보고서.docx를 생성했습니다. 열어 보세요.' 'Created plan+v2.docx.'; do
  i=$((i+1))
  sx "$T/in47c.json" "s47c$i" "$C47" "$m"; runt g47c "$T/in47c.json"
  case $i in 1) w='scripts/docx from-md ./회의록.md';; 2) w='scripts/xlsx from-md ./saved.md';; 3) w='scripts/docx from-md ./보고서.md';; 4) w='';; esac
  [ "$(cat "$T/g47c.rc")" = 0 ] && isblock "$T/g47c.out" && { [ -z "$w" ] || one "$w"; } || bad47="$bad47 [block#$i $(head -c 160 "$T/g47c.out")]"
done
[ -z "$bad47" ] && pass stop-claim-still-blocks || bad stop-claim-still-blocks "$bad47"

# ---- 5차 실전 개선: from-md 결과 이름을 마지막 사용자 요청의 파일 이름과 맞춘다 · SKILL 예시 이름 중립 ----
# 실전 4차: 요청은 회의록.docx 인데 제목에서 '주간회의록', 요청은 계획.pptx 인데 SKILL 예시 '발표' 로 만들었다.
# Bash 로 <k> from-md 를 돌리기 전에(파일이 생기기 전에) 결과 이름(두 인자면 둘째, 한 인자면 md 이름)을
# 마지막 last-prompt 의 같은 종류 파일 이름들과 견주고, 어느 것과도 다르면 거부하며 바른 명령을 알려 준다.
# bt <out-file> <session> <cwd|NONE> <transcript> <command 파이썬 문자열 식> : cwd·대화 기록이 있는 Bash 입력
bt() {
  if [ "$3" = NONE ]; then
    pj "$1" "{'session_id':'$2','transcript_path':'''$4''','hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':$5}}"
  else
    pj "$1" "{'session_id':'$2','transcript_path':'''$4''','cwd':'''$3''','hook_event_name':'PreToolUse','tool_name':'Bash','tool_input':{'command':$5}}"
  fi
}
# tpr <file> <마지막 요청 글> : 옛 요청(발표.pptx·재고.xlsx·초안.docx)이 앞에 있고 마지막 last-prompt 가 주어진 글인 기록
tpr() {
  "$PY" -I -c '
import json,sys
rows=[{"type":"last-prompt","lastPrompt":"발표.pptx 와 재고.xlsx 와 초안.docx 를 열어 줘"},
      {"type":"user","message":{"role":"user","content":"발표.pptx 와 재고.xlsx 와 초안.docx 를 열어 줘"}},
      {"type":"last-prompt","lastPrompt":sys.argv[2]},
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"네"}]}}]
with open(sys.argv[1],"w",encoding="utf-8") as f:
    for r in rows: f.write(json.dumps(r,ensure_ascii=False)+"\n")' "$1" "$2"
}
PP='계획.pptx 발표 자료를 3장으로 만들어 줘. 1장 제목 2026 하반기 계획, 2장 목표(매출 10% 증가, 신규 고객 50곳), 3장 일정(12월 준비, 1월 시작).'
tpr "$T/t48pp.jsonl" "$PP"
tpr "$T/t48nfd.jsonl" "$("$PY" -I -c 'import sys,unicodedata; print(unicodedata.normalize("NFD", sys.argv[1]))' "$PP")"
tpr "$T/t48memo.jsonl" '메모.md 내용을 보고서.docx 워드 파일로 만들어 줘'
tpr "$T/t48two.jsonl" '계획.pptx 와 요약.pptx 두 개를 만들어 줘. 예산.xlsx 도 만들어 줘.'
tpr "$T/t48docx.jsonl" '회의록.docx 워드 파일을 만들어 줘'
printf '%s\n' '{"type":"user","message":{"role":"user","content":"계획.pptx 를 만들어 줘"}}' > "$T/t48nolp.jsonl"
C48="$T/c48"; mkdir -p "$C48"
printf '# 2026 하반기 계획\n' > "$C48/발표.md"; printf '# 메모\n' > "$C48/메모.md"
C48b="$T/c48b"; mkdir -p "$C48b"
printf '# 2026 하반기 계획\n' > "$C48b/발표.md"; printf 'PK\003\004a' > "$C48b/계획.pptx"
P48='~/.claude/skills/pptx/scripts/pptx'

# 48. 따로 부른 한 인자 from-md 의 이름이 요청과 다르면 거부하고, md 가 있으니 두 인자 명령을 그대로 준다.
#     거부는 Skill 표시(.pending)를 건드리지 않고, 바른 두 인자 명령은 허용되며 표시를 지운다.
hin s48 Skill pptx '' > "$T/in48.json"; run g48 "$T/in48.json"
m48a="$(cat "$STATE/s48.pending" 2>/dev/null)"
bt "$T/in48b.json" s48 "$C48" "$T/t48pp.jsonl" "'$P48 from-md ./발표.md'"; run g48b "$T/in48b.json"
m48b="$(cat "$STATE/s48.pending" 2>/dev/null)"
isdeny "$T/g48b.out" && cp "$T/reason.txt" "$T/r48b.txt"
bt "$T/in48c.json" s48 "$C48" "$T/t48pp.jsonl" "'$P48 from-md ./발표.md ./계획.pptx'"; run g48c "$T/in48c.json"
allowed g48 && [ -n "$m48a" ] && [ "$m48a" = "$m48b" ] && [ -s "$T/r48b.txt" ] \
  && grep -qF '[skill-guard]' "$T/r48b.txt" && grep -qF '계획.pptx' "$T/r48b.txt" \
  && grep -qF '~/.claude/skills/pptx/scripts/pptx from-md ./발표.md ./계획.pptx' "$T/r48b.txt" \
  && allowed g48c && [ ! -e "$STATE/s48.pending" ] \
  && pass from-md-name-mismatch-denied-two-arg-hint || bad from-md-name-mismatch-denied-two-arg-hint "m='$m48a'/'$m48b' $(head -c 300 "$T/g48b.out") / $(head -c 200 "$T/g48c.out")"

# 48b. 같은 Bash 에서 heredoc 로 md 를 쓰고 바로 from-md 하면(md 가 cwd 에 있어도) 두 군데 이름을 바꿔 다시 보내라고 한다.
bt "$T/in48d.json" s48d "$C48" "$T/t48pp.jsonl" "\"cat > ./발표.md <<'MD'\\n# 2026 하반기 계획\\nMD\\n$P48 from-md ./발표.md\""; run g48d "$T/in48d.json"
isdeny "$T/g48d.out" && grep -qF 'cat > ./계획.md' "$T/reason.txt" && one 'scripts/pptx from-md ./계획.md' \
  && grep -qF '계획.pptx' "$T/reason.txt" \
  && pass from-md-name-mismatch-same-call-resend || bad from-md-name-mismatch-same-call-resend "$(head -c 300 "$T/g48d.out")"

# 48c. 허용: 요청 이름 그대로(heredoc+한 인자), NFD 로 적힌 요청, 두 인자에서 결과만 요청 이름(md 이름은 달라도),
#      다른 종류·옛 요청 이름은 무시(마지막 요청의 계획만 본다 — 옛 요청의 발표는 허용 근거가 아니다는 48 에서 확인)
bad48=""
bt "$T/in48e.json" s48e "$C48" "$T/t48pp.jsonl" "\"cat > ./계획.md <<'MD'\\n# 2026 하반기 계획\\nMD\\n$P48 from-md ./계획.md\""; run g48e "$T/in48e.json"
allowed g48e || bad48="$bad48 [same $(head -c 160 "$T/g48e.out")]"
bt "$T/in48e.json" s48f "$C48" "$T/t48nfd.jsonl" "\"cat > ./계획.md <<'MD'\\n# x\\nMD\\n$P48 from-md ./계획.md\""; run g48f "$T/in48e.json"
allowed g48f || bad48="$bad48 [nfd $(head -c 160 "$T/g48f.out")]"
bt "$T/in48e.json" s48g "$C48" "$T/t48pp.jsonl" "'$P48 from-md ./발표.md \"./계획.pptx\"'"; run g48g "$T/in48e.json"
allowed g48g || bad48="$bad48 [two-arg $(head -c 160 "$T/g48g.out")]"
[ -z "$bad48" ] && pass from-md-name-match-allowed || bad from-md-name-match-allowed "$bad48"

# 48d. 요청에 입력 md 와 결과 docx 이름이 함께 있으면: 메모.md 로 한 인자 → 거부·두 인자 안내, 두 인자 → 허용
D48='~/.claude/skills/docx/scripts/docx'
bt "$T/in48h.json" s48h "$C48" "$T/t48memo.jsonl" "'$D48 from-md ./메모.md'"; run g48h "$T/in48h.json"
isdeny "$T/g48h.out" && cp "$T/reason.txt" "$T/r48h.txt"
bt "$T/in48i.json" s48h "$C48" "$T/t48memo.jsonl" "'$D48 from-md ./메모.md ./보고서.docx'"; run g48i "$T/in48i.json"
[ -s "$T/r48h.txt" ] && grep -qF '~/.claude/skills/docx/scripts/docx from-md ./메모.md ./보고서.docx' "$T/r48h.txt" && allowed g48i \
  && pass from-md-input-and-output-names || bad from-md-input-and-output-names "$(head -c 300 "$T/g48h.out") / $(head -c 200 "$T/g48i.out")"

# 48e. 같은 종류 이름이 여럿이면 어느 하나와 같으면 허용, 다 다르면 거부하고 후보를 모두 든다.
#      요청한 결과가 이미 cwd 에 있으면(from-md 가 기존 출력을 거부하므로 맞추라 하면 막다른 길) 허용하되,
#      요청 이름 중 없는 것이 하나라도 있으면 여전히 거부한다.
bad48=""
bt "$T/in48j.json" s48j "$C48" "$T/t48two.jsonl" "'$P48 from-md ./발표.md'"; run g48j "$T/in48j.json"
isdeny "$T/g48j.out" && grep -qF './계획.pptx' "$T/reason.txt" && grep -qF './요약.pptx' "$T/reason.txt" || bad48="$bad48 [multi $(head -c 200 "$T/g48j.out")]"
bt "$T/in48j.json" s48k "$C48" "$T/t48two.jsonl" "\"cat > ./요약.md <<'MD'\\n# 요약\\nMD\\n$P48 from-md ./요약.md\""; run g48k "$T/in48j.json"
allowed g48k || bad48="$bad48 [second-name $(head -c 160 "$T/g48k.out")]"
bt "$T/in48j.json" s48l "$C48b" "$T/t48pp.jsonl" "'$P48 from-md ./발표.md'"; run g48l "$T/in48j.json"
allowed g48l || bad48="$bad48 [exists $(head -c 160 "$T/g48l.out")]"
bt "$T/in48j.json" s48m "$C48b" "$T/t48two.jsonl" "'$P48 from-md ./발표.md'"; run g48m "$T/in48j.json"
isdeny "$T/g48m.out" && grep -qF '요약.pptx' "$T/reason.txt" || bad48="$bad48 [partly-exists $(head -c 200 "$T/g48m.out")]"
[ -z "$bad48" ] && pass from-md-name-candidates-and-existing || bad from-md-name-candidates-and-existing "$bad48"

# 48f. 거부는 세션·종류마다 두 번까지: 세 번째 같은 실수는 허용. 다른 종류(xlsx)는 따로 센다.
X48='~/.claude/skills/xlsx/scripts/xlsx'
for i in 1 2 3; do bt "$T/in48n.json" s48n "$C48" "$T/t48two.jsonl" "'$P48 from-md ./발표.md'"; run "g48n$i" "$T/in48n.json"; done
bt "$T/in48o.json" s48n "$C48" "$T/t48two.jsonl" "'$X48 from-md ./재고.md'"; run g48o "$T/in48o.json"
isdeny "$T/g48n1.out" && isdeny "$T/g48n2.out" && allowed g48n3 && isdeny "$T/g48o.out" && one 'scripts/xlsx from-md ./재고.md ./예산.xlsx' \
  && pass from-md-name-deny-capped-per-kind || bad from-md-name-deny-capped-per-kind "$(head -c 120 "$T/g48n3.out") / $(head -c 200 "$T/g48o.out")"

# 48g. 막지 않음(fail open): 기록 파일 없음·폴더·last-prompt 없음·요청에 그 종류 이름 없음(docx 만)·cwd 없음,
#      결과 이름에 $ 확장, 오피스 skill 명령이 아닌 from-md, from-md 가 아닌 하위 명령, 기록이 FIFO(멈추지 않음)
bad48=""
i=0
for case in "$T/없음.jsonl|'$P48 from-md ./발표.md'|$C48" "$T|'$P48 from-md ./발표.md'|$C48" \
            "$T/t48nolp.jsonl|'$P48 from-md ./발표.md'|$C48" "$T/t48docx.jsonl|'$P48 from-md ./발표.md'|$C48" \
            "$T/t48pp.jsonl|'$P48 from-md ./발표.md'|NONE" "$T/t48pp.jsonl|'$P48 from-md \"./\$N.md\"'|$C48" \
            "$T/t48pp.jsonl|'/usr/local/bin/pptx from-md ./발표.md'|$C48" "$T/t48pp.jsonl|'$P48 read ./발표.pptx'|$C48"; do
  i=$((i+1))
  tp48="${case%%|*}"; rest48="${case#*|}"; cmd48="${rest48%|*}"; cwd48="${rest48##*|}"
  bt "$T/in48p.json" "s48p$i" "$cwd48" "$tp48" "$cmd48"; runt g48p "$T/in48p.json"
  allowed g48p || bad48="$bad48 [#$i $(head -c 160 "$T/g48p.out")]"
done
mkfifo "$T/t48fifo.jsonl"
bt "$T/in48q.json" s48q "$C48" "$T/t48fifo.jsonl" "'$P48 from-md ./발표.md'"; runt g48q "$T/in48q.json"
allowed g48q || bad48="$bad48 [fifo rc=$(cat "$T/g48q.rc") $(head -c 160 "$T/g48q.out")]"
[ -z "$bad48" ] && pass from-md-name-fail-open || bad from-md-name-fail-open "$bad48"

# 48h. 끝나지 않은 heredoc 은 이름보다 먼저 그 거부를 받는다(이름 안내를 섞지 않는다). 이름 거부는 Stop 표시도 지우지 않는다.
bt "$T/in48r.json" s48r "$C48" "$T/t48pp.jsonl" "\"cat > ./발표.md <<'MD'\\n# x\\nMD && $P48 from-md ./발표.md\""; run g48r "$T/in48r.json"
hin s48s Skill pptx '' > "$T/in48s.json"; run g48s "$T/in48s.json"
bt "$T/in48s2.json" s48s "$C48" "$T/t48pp.jsonl" "'$P48 from-md ./발표.md'"; run g48s2 "$T/in48s2.json"
st "$T/in48ss.json" s48s False; run g48ss "$T/in48ss.json"
isdeny "$T/g48r.out" && grep -qF '닫히지 않아' "$T/reason.txt" && ! grep -qF '계획' "$T/reason.txt" \
  && allowed g48s && isdeny "$T/g48s2.out" && isblock "$T/g48ss.out" \
  && pass from-md-name-after-heredoc-keeps-mark || bad from-md-name-after-heredoc-keeps-mark "$(head -c 200 "$T/g48r.out") / $(head -c 160 "$T/g48ss.out")"

# 48i. (리뷰 지적) 두 인자에서 입력 md 이름에 빈칸이 있으면 안내 명령도 셸 단어가 그대로 나뉘게 따옴표로 감싼다:
#      안내 명령을 셸 단어로 나누면 [명령, from-md, ./my draft.md, ./보고서.docx] 네 개이고, 그대로 보내면 허용된다.
printf '# 메모\n' > "$C48/my draft.md"
bt "$T/in48t.json" s48t "$C48" "$T/t48memo.jsonl" "'$D48 from-md \"./my draft.md\" ./wrong.docx'"; run g48t "$T/in48t.json"
isdeny "$T/g48t.out" && cp "$T/reason.txt" "$T/r48t.txt"
hint48="$(sed -n 's/.*만드세요: //p' "$T/r48t.txt" 2>/dev/null | head -1)"
split48="$("$PY" -I -c 'import shlex,sys; print("|".join(shlex.split(sys.argv[1])))' "$hint48" 2>/dev/null)"
"$PY" -I -c 'import json,sys; print(json.dumps({"session_id":"s48t","transcript_path":sys.argv[1],"cwd":sys.argv[2],"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[3]}},ensure_ascii=False))' \
  "$T/t48memo.jsonl" "$C48" "$hint48" > "$T/in48t2.json"; run g48t2 "$T/in48t2.json"
[ -s "$T/r48t.txt" ] && [ "$split48" = "$D48|from-md|./my draft.md|./보고서.docx" ] && allowed g48t2 \
  && pass from-md-name-hint-quotes-spaced-input || bad from-md-name-hint-quotes-spaced-input "hint=[$hint48] split=[$split48] $(head -c 200 "$T/g48t.out") / $(head -c 160 "$T/g48t2.out")"

# 48j. (리뷰 지적) 두 인자에서 입력 md 자리에 셸 확장($·`·*·? 등)이 있으면 안내에 그대로 옮길 수 없으니 막지 않는다.
bad48=""
i=0
for in48 in '"$INPUT"' '"./$N.md"' './*.md' "\"./a\\\\b.md\""; do
  i=$((i+1))
  bt "$T/in48u.json" "s48u$i" "$C48" "$T/t48memo.jsonl" "'''$D48 from-md $in48 ./wrong.docx'''"; run g48u "$T/in48u.json"
  allowed g48u || bad48="$bad48 [#$i $in48 $(head -c 200 "$T/g48u.out")]"
done
[ -z "$bad48" ] && pass from-md-name-expanding-input-fail-open || bad from-md-name-expanding-input-fail-open "$bad48"

# 48k. (리뷰 지적) 같은 Bash 에서 md 를 쓰고 바로 from-md 하는데 요청 이름이 여럿이면, 다시 보낼 두 줄 틀에 없는
#      './계획.pptx 자리' 를 말하지 않는다(모델이 ./요약.pptx.md 처럼 쓰게 된다). 다른 후보(요약)는 여전히 알린다.
bt "$T/in48w.json" s48w "$C48" "$T/t48two.jsonl" "\"cat > ./발표.md <<'MD'\\n# 2026 하반기 계획\\nMD\\n$P48 from-md ./발표.md\""; run g48w "$T/in48w.json"
isdeny "$T/g48w.out" && ! grep -qF './계획.pptx 자리' "$T/reason.txt" && grep -qF '요약' "$T/reason.txt" \
  && grep -qF 'cat > ./계획.md' "$T/reason.txt" && one 'scripts/pptx from-md ./계획.md' \
  && pass from-md-name-same-call-multi-wording || bad from-md-name-same-call-multi-wording "$(head -c 400 "$T/g48w.out")"

# 49. 오피스 SKILL.md 예시 이름: cat > · from-md · (→) 세 군데가 같은 이름이고, 실전 시험 요청 이름(회의록·예산·계획)·
#     옛 예시(발표)·제목에서 나오기 쉬운 '주간' 과 겹치지 않는다.
bad49=""
for n in docx xlsx pptx hwpx; do
  f="$KIT/skills/$n/SKILL.md"
  s1="$(sed -n "s|^cat > \./\([^ ]*\)\.md <<.*|\1|p" "$f" | head -1)"
  s2="$(sed -n "s|^~/\.claude/skills/$n/scripts/$n from-md \./\([^ ]*\)\.md *\$|\1|p" "$f" | head -1)"
  s3="$(sed -n "s|.*(\./\([^ ]*\)\.md → \./\([^ ]*\)\.$n).*|\1 \2|p" "$f" | head -1)"
  [ -n "$s1" ] && [ "$s1" = "$s2" ] && [ "$s3" = "$s1 $s1" ] && ! printf %s "$s1" | grep -qE '회의|예산|계획|발표|주간' \
    || bad49="$bad49 [$n '$s1' '$s2' '$s3']"
done
[ -z "$bad49" ] && pass office-skill-md-neutral-example-name || bad office-skill-md-neutral-example-name "$bad49"

# 50. (5차 실전 오탐) 끝 답이 cwd 의 파일을 '`/계획.pptx`' 처럼 / 바로 아래 이름 하나로 적으면 cwd 기준으로도 본다.
#     / 바로 아래(이름 하나)에만 해당한다: 더 깊은 절대 경로는 cwd 에 같은 이름이 있어도 그대로 막는다.
C50="$T/c50"; mkdir -p "$C50"
printf 'PK\003\004a' > "$C50/계획.pptx"
printf 'PK\003\004a' > "$C50/x.docx"
printf '# 그냥 글\n' > "$C50/메모.docx"
# 50a. 허용: /계획.pptx (cwd/계획.pptx 가 zip) — 백틱·꾸밈·맨 이름 모두
bad50=""
i=0
for m in '`/계획.pptx` 파일로 성공적으로 생성되었습니다.' '**`/계획.pptx`** 를 만들었습니다.' '/계획.pptx 를 저장했습니다.'; do
  i=$((i+1))
  sx "$T/in50a.json" "s50a$i" "$C50" "$m"; run g50a "$T/in50a.json"
  allowed g50a || bad50="$bad50 [#$i $(head -c 160 "$T/g50a.out")]"
done
[ -z "$bad50" ] && pass stop-claim-root-name-uses-cwd || bad stop-claim-root-name-uses-cwd "$bad50"
# 50b. 막음: / 바로 아래 이름이어도 cwd 에 없거나(요약) zip 이 아니면(메모) 막고 그 이름으로 안내
bad50=""
sx "$T/in50b.json" s50b1 "$C50" '`/요약.pptx` 파일로 성공적으로 생성되었습니다.'; run g50b "$T/in50b.json"
isblock "$T/g50b.out" && one 'scripts/pptx from-md ./요약.md' || bad50="$bad50 [요약 $(head -c 160 "$T/g50b.out")]"
sx "$T/in50b.json" s50b2 "$C50" '`/메모.docx` 를 생성했습니다.'; run g50b "$T/in50b.json"
isblock "$T/g50b.out" && one 'scripts/docx from-md ./메모.md' || bad50="$bad50 [메모 $(head -c 160 "$T/g50b.out")]"
[ -z "$bad50" ] && pass stop-claim-root-name-missing-blocked || bad stop-claim-root-name-missing-blocked "$bad50"
# 50c. 막음: 더 깊은 없는 절대 경로는 cwd 에 같은 이름(x.docx)이 있어도 cwd 로 바꿔 보지 않는다
sx "$T/in50c.json" s50c "$C50" '`/Users/nobody/x.docx` 를 생성했습니다.'; run g50c "$T/in50c.json"
isblock "$T/g50c.out" && one 'scripts/docx from-md ./x.md' && pass stop-claim-deep-abs-not-cwd || bad stop-claim-deep-abs-not-cwd "$(head -c 200 "$T/g50c.out")"
# 50d. (agy 리뷰) 허용: Markdown 링크 대상 /계획.pptx, 백틱 안 띄어쓰기 이름 /계획 2026.pptx
printf 'PK\003\004a' > "$C50/계획 2026.pptx"
bad50=""
i=0
for m in '[계획](/계획.pptx) 를 생성했습니다.' '`/계획 2026.pptx` 를 저장했습니다.'; do
  i=$((i+1))
  sx "$T/in50d.json" "s50d$i" "$C50" "$m"; run g50d "$T/in50d.json"
  allowed g50d || bad50="$bad50 [#$i $(head -c 160 "$T/g50d.out")]"
done
[ -z "$bad50" ] && pass stop-claim-root-name-link-space || bad stop-claim-root-name-link-space "$bad50"
# 50e. (agy 리뷰) 한 답에 있는 /계획.pptx 와 없는 /요약.pptx 를 함께 주장하면 막고, 없는 요약만 말한다
sx "$T/in50e.json" s50e "$C50" '`/계획.pptx` 와 `/요약.pptx` 를 생성했습니다.'; run g50e "$T/in50e.json"
isblock "$T/g50e.out" && one 'scripts/pptx from-md ./요약.md' && ! grep -qF '/계획.pptx' "$T/reason.txt" \
  && pass stop-claim-root-name-mixed || bad stop-claim-root-name-mixed "$(head -c 300 "$T/g50e.out")"

# ---- claude-lms 가 hook 을 주입하는지(가짜 lms·claude·LM Studio) ----
[ -f "$W" ] || { echo "FAIL claude-lms missing: $W"; exit 1; }
# mkfake <home>: lms(ps 는 불러진 모델 하나), claude(받은 인자를 한 줄에 하나씩 args.txt 로)
mkfake() {
  local h="$1"
  mkdir -p "$h/.lmstudio/bin" "$h/.local/bin" "$h/.claude/skills/hwpx/scripts" "$h/.config/claude-lms"
  printf '#!/bin/sh\n[ "$1" = ps ] && printf %s\nexit 0\n' "'[{\"identifier\":\"m\",\"contextLength\":65536}]'" > "$h/.lmstudio/bin/lms"
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > "$HOME/args.txt"\n' > "$h/.local/bin/claude"
  chmod 755 "$h/.lmstudio/bin/lms" "$h/.local/bin/claude"
  cp "$G" "$h/.claude/skills/hwpx/scripts/skill-guard"; chmod 755 "$h/.claude/skills/hwpx/scripts/skill-guard"
  cp "$KIT/skills/hwpx/scripts/skill_guard.py" "$h/.claude/skills/hwpx/scripts/" 2>/dev/null || true
}
mkdir -p "$T/srv/v1"; printf '{"data":[]}' > "$T/srv/v1/models"
WH="$T/wh"; mkfake "$WH"
# wl <home> [env...] -- args : claude-lms 실행
wl() {
  local h="$1"; shift
  env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$h" TMPDIR="$T/tmp" CLAUDE_LMS_MODEL=m CLAUDE_LMS_URL="file://$T/srv" "$@"
}
# settings 인자 검사: settings_ok <args.txt> <guard-path>
settings_ok() {
  "$PY" -I -c '
import json,shlex,sys
a=open(sys.argv[1],encoding="utf-8").read().split("\n")
i=a.index("--settings"); s=json.loads(a[i+1])
assert list(s)==["hooks"] and list(s["hooks"])==["PreToolUse","Stop"]
e=s["hooks"]["PreToolUse"]; assert len(e)==1
assert sorted(e[0]["matcher"].split("|"))==sorted(["Skill","Write","Edit","MultiEdit","Bash"]), e[0]["matcher"]
st=s["hooks"]["Stop"]; assert len(st)==1 and "matcher" not in st[0]
for h in (e[0]["hooks"], st[0]["hooks"]):
    assert len(h)==1 and h[0]["type"]=="command" and h[0]["timeout"]==10
    assert shlex.split(h[0]["command"])==[sys.argv[2]], h[0]["command"]
print(i)
' "$1" "$2" 2>/dev/null
}

# 13. 주입: --settings 가 사용자 인자 앞에, 사용자 인자는 순서 그대로
wl "$WH" bash "$W" -p '안녕 "따옴표"' --allowedTools 'Bash,Skill' > "$T/w13.txt" 2>&1; rc=$?
if [ $rc -eq 0 ] && [ "$(settings_ok "$WH/args.txt" "$WH/.claude/skills/hwpx/scripts/skill-guard")" = 0 ] \
  && [ "$(sed -n '3,6p' "$WH/args.txt" | tr '\n' '|')" = '-p|안녕 "따옴표"|--allowedTools|Bash,Skill|' ]; then
  pass lms-injects-guard-settings
else bad lms-injects-guard-settings "rc=$rc $(head -c 300 "$WH/args.txt" 2>/dev/null) $(head -c 200 "$T/w13.txt")"; fi

# 13b. 주입된 command 를 셸로 그대로 실행해도 guard 가 동작(두 번째 거부)
CMD="$("$PY" -I -c 'import json,sys; a=open(sys.argv[1],encoding="utf-8").read().split("\n"); print(json.loads(a[a.index("--settings")+1])["hooks"]["PreToolUse"][0]["hooks"][0]["command"])' "$WH/args.txt" 2>/dev/null)"
hin s13 Skill hwpx 'fields ./f.hwpx' > "$T/in13.json"
HOME="$WH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$PY" sh -c "$CMD" < "$T/in13.json" > "$T/w13a.out" 2>&1
HOME="$WH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$PY" sh -c "$CMD" < "$T/in13.json" > "$T/w13b.out" 2>&1
[ -n "$CMD" ] && [ ! -s "$T/w13a.out" ] && isdeny "$T/w13b.out" && pass lms-injected-command-runs || bad lms-injected-command-runs "cmd=[$CMD] $(head -c 200 "$T/w13b.out")"

# 13c. 주입된 Stop command 도 셸로 그대로 실행하면 동작(xlsx Skill 뒤 Bash 없이 Stop → 차단)
SCMD="$("$PY" -I -c 'import json,sys; a=open(sys.argv[1],encoding="utf-8").read().split("\n"); print(json.loads(a[a.index("--settings")+1])["hooks"]["Stop"][0]["hooks"][0]["command"])' "$WH/args.txt" 2>/dev/null)"
mkdir -p "$WH/.claude/skills/xlsx/scripts"; printf '#!/bin/sh\nexit 0\n' > "$WH/.claude/skills/xlsx/scripts/xlsx"; chmod 755 "$WH/.claude/skills/xlsx/scripts/xlsx"
hin s13c Skill xlsx '' > "$T/in13c.json"
"$PY" -I -c 'import json; print(json.dumps({"session_id":"s13c","hook_event_name":"Stop","stop_hook_active":False}))' > "$T/in13cs.json"
HOME="$WH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$PY" sh -c "$CMD" < "$T/in13c.json" > "$T/w13c.out" 2>&1
HOME="$WH" TMPDIR="$T/tmp" CLAUDE_LMS_PY="$PY" sh -c "$SCMD" < "$T/in13cs.json" > "$T/w13cs.out" 2>&1
[ -n "$SCMD" ] && [ ! -s "$T/w13c.out" ] && isblock "$T/w13cs.out" && pass lms-injected-stop-runs || bad lms-injected-stop-runs "cmd=[$SCMD] $(head -c 200 "$T/w13cs.out")"

# 14. guard 가 없으면 주입하지 않음
WN="$T/wn"; mkfake "$WN"; rm -f "$WN/.claude/skills/hwpx/scripts/skill-guard"
wl "$WN" bash "$W" -p hi > "$T/w14.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && ! grep -qx -- '--settings' "$WN/args.txt" && [ "$(tr '\n' '|' < "$WN/args.txt")" = '-p|hi|' ] && pass lms-no-guard-no-settings || bad lms-no-guard-no-settings "rc=$rc $(tr '\n' '|' < "$WN/args.txt" 2>/dev/null)"

# 15. CLAUDE_LMS_SKILL_GUARD=0 이면 주입하지 않음
wl "$WH" CLAUDE_LMS_SKILL_GUARD=0 bash "$W" -p hi > "$T/w15.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(tr '\n' '|' < "$WH/args.txt")" = '-p|hi|' ] && pass lms-guard-off-env || bad lms-guard-off-env "rc=$rc $(tr '\n' '|' < "$WH/args.txt")"

# 16. 하위 명령(mcp, update 등)에는 주입하지 않음
wl "$WH" bash "$W" mcp list > "$T/w16.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(tr '\n' '|' < "$WH/args.txt")" = 'mcp|list|' ] && pass lms-subcommand-no-settings || bad lms-subcommand-no-settings "rc=$rc $(tr '\n' '|' < "$WH/args.txt")"

# 17. 사용자가 --settings 를 직접 주면 주입하지 않음(두 형태 모두)
wl "$WH" bash "$W" --settings /x.json -p hi > "$T/w17.txt" 2>&1
a1="$(tr '\n' '|' < "$WH/args.txt")"
wl "$WH" bash "$W" -p hi --settings=/x.json > "$T/w17b.txt" 2>&1
a2="$(tr '\n' '|' < "$WH/args.txt")"
[ "$a1" = '--settings|/x.json|-p|hi|' ] && [ "$a2" = '-p|hi|--settings=/x.json|' ] && pass lms-user-settings-wins || bad lms-user-settings-wins "$a1 / $a2"

# 18. HOME 경로에 공백이 있어도 command 가 한 낱말로 인용됨
WS="$T/w s"; mkfake "$WS"
wl "$WS" bash "$W" -p hi > "$T/w18.txt" 2>&1
[ "$(settings_ok "$WS/args.txt" "$WS/.claude/skills/hwpx/scripts/skill-guard")" = 0 ] && pass lms-home-with-space || bad lms-home-with-space "$(head -c 300 "$WS/args.txt")"

# 19. HOME 경로에 따옴표·역슬래시가 있으면 JSON 을 손으로 만들지 않고 주입을 건너뜀
WQ="$T/w\"q"; mkfake "$WQ"
wl "$WQ" bash "$W" -p hi > "$T/w19.txt" 2>&1; rc=$?
[ $rc -eq 0 ] && [ "$(tr '\n' '|' < "$WQ/args.txt")" = '-p|hi|' ] && pass lms-unsafe-home-skips || bad lms-unsafe-home-skips "rc=$rc $(tr '\n' '|' < "$WQ/args.txt" 2>/dev/null)"

# 19b. HOME 경로에 $ · 작은따옴표가 있어도 주입을 건너뜀(셸 확장·인용 깨짐 방지)
WD="$T/w\$d"; mkfake "$WD"
wl "$WD" bash "$W" -p hi > "$T/w19b.txt" 2>&1; rc=$?
WA="$T/w'a"; mkfake "$WA"
wl "$WA" bash "$W" -p hi > "$T/w19c.txt" 2>&1; rc2=$?
[ $rc -eq 0 ] && [ $rc2 -eq 0 ] && [ "$(tr '\n' '|' < "$WD/args.txt")" = '-p|hi|' ] && [ "$(tr '\n' '|' < "$WA/args.txt")" = '-p|hi|' ] \
  && pass lms-unsafe-home-dollar-quote-skips || bad lms-unsafe-home-dollar-quote-skips "rc=$rc/$rc2 $(tr '\n' '|' < "$WD/args.txt" 2>/dev/null) / $(tr '\n' '|' < "$WA/args.txt" 2>/dev/null)"

# 20. 설치: skill-guard 가 실행 권한으로 설치되도록 install 이 chmod 한다
grep -qF 'chmod 755 "${STAGE}/scripts/skill-guard"' "$INST" && pass install-chmods-guard || bad install-chmods-guard "no chmod line in install-claude-code.sh"

[ $fail -eq 0 ] && echo "ACCEPT PASS" || { echo "ACCEPT FAIL"; exit 1; }
