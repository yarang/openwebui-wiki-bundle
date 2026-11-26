#!/bin/bash
# guardian/install-claude-code.sh §3(skills) 인수 시험 — 가짜 HOME 에 설치해 본다 (빌드 Mac 전용: 진짜 서명된 claude 가 필요).
# 사용: CLAUDE_LMS_PY=<lxml·python-docx·openpyxl·python-pptx·fastapi·httpx·uvicorn 이 있는 python>
#       guardian/tests/accept_install_claude_code.sh [CLAUDE_BIN]
#       (모두 통과하면 "ACCEPT PASS", 종료 0; fastapi·httpx·uvicorn 은 --with-router 사례의 사전 점검이 본다)
# 네 skill(hwpx·docx·xlsx·pptx) 이 ~/.claude/skills/<이름> 에 설치되고, 다시 돌리면 그대로 두고, 바뀐 것만 백업 후 교체하고,
# 모듈이 없는 skill 만 건너뛰고, 하나라도 시험(smoke)에 실패하면 skills 를 하나도 건드리지 않는지 본다.
# 사전 점검(P*)도 본다: 잘못된 --context·모르는 --model·모델 없음·인용부호/제어문자 든 model·URL(P8–P10)이
# 무엇이든 쓰기 전에 죽고 가짜 홈이 비어 있으며, 스텁 LM Studio(127.0.0.1 의 http.server) 상대로 첫 LLM 선택
# (빈 id 줄 건너뛰기 포함, P11)을, conf 의 export/들여쓰기 값의 재설치를 확인한다.
set -u
G="$(cd "$(dirname "$0")/.." && pwd)"
CB="${1:-$HOME/.local/bin/claude}"
PY="${CLAUDE_LMS_PY:-$HOME/.guardian-llm/venv/bin/python}"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-inst.XXXXXX")"
T="$(cd "$T" && pwd)"
trap '[ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; find "$T" -type d -exec chmod -a "owner deny add_file,add_subdirectory" {} + 2>/dev/null; rm -rf "$T"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }
SKS="hwpx docx xlsx pptx"
OFFICE="docx xlsx pptx"

[ -x "$CB" ] || { echo "FAIL claude binary missing: $CB"; exit 1; }
"$PY" -I -c 'import lxml.etree, docx, openpyxl, pptx, fastapi, httpx, uvicorn' 2>/dev/null \
    || { echo "FAIL $PY cannot import lxml/docx/openpyxl/pptx/fastapi/httpx/uvicorn"; exit 1; }
BINREAL="$(readlink -f "$CB")"
VER="$("$BINREAL" --version | awk '{print $1}')"

# 설치 폴더 모양(pack-claude-code.sh 가 만드는 것): 스크립트 셋 + 바이너리 + VERSION + claude-kit(tests 제외)
mkkit() {
    local k="$1"; mkdir -p "$k"
    cp "$G/install-claude-code.sh" "$G/claude-lms" "$G/claude-vscode" "$k/"
    chmod 755 "$k/install-claude-code.sh" "$k/claude-lms" "$k/claude-vscode"
    if [ -f "$T/kit/claude" ]; then cp -c "$T/kit/claude" "$k/claude"; else cp "$BINREAL" "$k/claude"; fi
    echo "$VER" > "$k/VERSION"
    rsync -a --exclude tests --exclude __pycache__ --exclude .DS_Store "$G/claude-kit" "$k/"
    chmod 755 "$k/claude-kit/skills/hwpx/scripts/hwpx" "$k/claude-kit/skills/hwpx/scripts/skill-guard"
    for s in $OFFICE; do chmod 755 "$k/claude-kit/skills/$s/scripts/$s" 2>/dev/null; done
    # pack-claude-code.sh 가 kit 에 넣는 llm-router 폴더: 정확히 다섯 파일(tests/·spark/ 없음).
    mkdir -p "$k/llm-router"
    for f in router.py spark-model install-llm-router.sh env.example README.md; do cp "$G/llm-router/$f" "$k/llm-router/"; done
    chmod 755 "$k/llm-router/spark-model" "$k/llm-router/install-llm-router.sh"
}
# 가짜 HOME: 같은 버전의 claude 가 이미 설치된 모양(§1 이 바이너리를 다시 복사하지 않음; APFS clone)
mkhome() {
    local h="$1"; mkdir -p "$h/.local/share/claude/versions" "$h/.local/bin"
    cp -c "$T/kit/claude" "$h/.local/share/claude/versions/$VER"
    ln -s "$h/.local/share/claude/versions/$VER" "$h/.local/bin/claude"
}
# inst <name> <home> <kit> <python> [opts...] → $T/<name>.out (stdout+stderr), $T/<name>.rc
inst() {
    local n="$1" h="$2" k="$3" py="$4"; shift 4
    HOME="$h" CLAUDE_LMS_PY="$py" XDG_CONFIG_HOME="$h/.config" TMPDIR="$T/tmp" \
        "$k/install-claude-code.sh" --model=test-model --lmstudio-url=http://127.0.0.1:9 --no-path "$@" \
        > "$T/$n.out" 2>&1
    echo $? > "$T/$n.rc"
}
rc() { cat "$T/$1.rc"; }
show() { sed 's/^/    /' "$T/$1.out" | tail -15; }
mkdir -p "$T/tmp"
mkkit "$T/kit"

# ---- I1. 새로 설치: 네 skill, 원본과 같은 내용, 래퍼 755, 남은 partial·__pycache__ 없음, 다른 skill 은 그대로 ----------
H="$T/h1"; mkhome "$H"
mkdir -p "$H/.claude/skills/mine"; echo '내 skill' > "$H/.claude/skills/mine/SKILL.md"
inst i1 "$H" "$T/kit" "$PY"
[ "$(rc i1)" = 0 ] && pass "I1 install exits 0" || { bad "I1 install exits 0" "rc=$(rc i1)"; show i1; }
for s in $SKS; do
    D="$H/.claude/skills/$s"
    [ "$(stat -f %Lp "$D/scripts/$s" 2>/dev/null)" = 755 ] && pass "I1 $s wrapper 755" || bad "I1 $s wrapper 755" "$(ls -l "$D/scripts/$s" 2>&1)"
    if [ "$s" = hwpx ]; then
        diff -rq -x lib -x __pycache__ -x .DS_Store "$G/claude-kit/skills/hwpx" "$D" >/dev/null 2>&1 \
            && pass "I1 hwpx same as source" || bad "I1 hwpx same as source" "$(diff -rq -x lib "$G/claude-kit/skills/hwpx" "$D" 2>&1 | head -3)"
    else
        diff -rq -x __pycache__ -x .DS_Store "$G/claude-kit/skills/$s" "$D" >/dev/null 2>&1 \
            && pass "I1 $s same as source" || bad "I1 $s same as source" "$(diff -rq "$G/claude-kit/skills/$s" "$D" 2>&1 | head -3)"
    fi
done
[ -d "$H/.claude/skills/hwpx/lib/hwpx" ] && pass "I1 hwpx lib vendored" || bad "I1 hwpx lib vendored" "no lib/hwpx"
[ -z "$(find "$H/.claude" -name '*.partial' -o -name '.claude-lms-*' 2>/dev/null)" ] && pass "I1 no partial left" \
    || bad "I1 no partial left" "$(find "$H/.claude" -name '*.partial' -o -name '.claude-lms-*')"
[ -z "$(find "$H/.claude/skills" -name __pycache__ 2>/dev/null)" ] && pass "I1 no __pycache__ in skills" \
    || bad "I1 no __pycache__ in skills" "$(find "$H/.claude/skills" -name __pycache__ | head -3)"
[ "$(cat "$H/.claude/skills/mine/SKILL.md" 2>/dev/null)" = '내 skill' ] && pass "I1 other skill untouched" || bad "I1 other skill untouched" "changed"
[ ! -d "$H/.claude/skills-backup" ] && pass "I1 fresh install makes no backup" || bad "I1 fresh install makes no backup" "$(ls "$H/.claude/skills-backup")"

# ---- I2. 설치된 오피스 도구가 그 python 으로 실제로 돈다 --------------------------------------------------------
printf '# 시험\n\n## 표\n\n| 항목 | 값 |\n| --- | --- |\n| 가 | 1 |\n' > "$T/a.md"
for s in $OFFICE; do
    out="$(CLAUDE_LMS_PY="$PY" "$H/.claude/skills/$s/scripts/$s" from-md "$T/a.md" "$T/a.$s" 2>&1 | head -1)"
    case "$out" in "OK $T/a.$s") pass "I2 installed $s from-md" ;; *) bad "I2 installed $s from-md" "$out" ;; esac
done

# ---- I3. 다시 돌리면 네 skill 모두 그대로 (백업 없음) ------------------------------------------------------------
inst i3 "$H" "$T/kit" "$PY"
[ "$(rc i3)" = 0 ] && pass "I3 rerun exits 0" || { bad "I3 rerun exits 0" "rc=$(rc i3)"; show i3; }
for s in $SKS; do
    grep -qF "$H/.claude/skills/$s already up to date" "$T/i3.out" && pass "I3 $s already up to date" \
        || bad "I3 $s already up to date" "$(grep -F "skills/$s" "$T/i3.out" | head -2)"
done
[ ! -d "$H/.claude/skills-backup" ] && pass "I3 rerun makes no backup" || bad "I3 rerun makes no backup" "$(ls "$H/.claude/skills-backup")"

# ---- I4. 손댄 skill 만 백업 후 교체, 나머지는 그대로 ------------------------------------------------------------
echo '덧붙임' >> "$H/.claude/skills/xlsx/SKILL.md"
inst i4 "$H" "$T/kit" "$PY"
[ "$(rc i4)" = 0 ] && pass "I4 exits 0" || { bad "I4 exits 0" "rc=$(rc i4)"; show i4; }
cmp -s "$G/claude-kit/skills/xlsx/SKILL.md" "$H/.claude/skills/xlsx/SKILL.md" && pass "I4 xlsx replaced from kit" || bad "I4 xlsx replaced from kit" "still modified"
bk="$(ls -d "$H/.claude/skills-backup"/xlsx.* 2>/dev/null | head -1)"
[ -n "$bk" ] && grep -qF '덧붙임' "$bk/SKILL.md" && pass "I4 modified copy backed up" || bad "I4 modified copy backed up" "backup '${bk:-none}'"
n="$(ls "$H/.claude/skills-backup" 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" = 1 ] && pass "I4 only xlsx backed up" || bad "I4 only xlsx backed up" "$(ls "$H/.claude/skills-backup")"
for s in hwpx docx pptx; do
    grep -qF "$H/.claude/skills/$s already up to date" "$T/i4.out" && pass "I4 $s untouched" || bad "I4 $s untouched" "not reported up to date"
done

# ---- I5. --no-skills: skills 폴더를 만들지 않는다 ---------------------------------------------------------------
H="$T/h5"; mkhome "$H"
inst i5 "$H" "$T/kit" "$PY" --no-skills
[ "$(rc i5)" = 0 ] && [ ! -e "$H/.claude/skills" ] && pass "I5 --no-skills writes no skill" || { bad "I5 --no-skills writes no skill" "rc=$(rc i5)"; show i5; }

# ---- I6. lxml 만 있고 docx/openpyxl/pptx 가 없는 python: hwpx 만 설치, 오피스 skill 은 이름을 대며 건너뜀(종료 0) ----
SP="$("$PY" -I -c 'import lxml,os;print(os.path.dirname(os.path.dirname(lxml.__file__)))')"
"$PY" -m venv "$T/vlx" >/dev/null 2>&1
VSP="$("$T/vlx/bin/python" -I -c 'import sysconfig;print(sysconfig.get_paths()["purelib"])')"
cp -R "$SP"/lxml "$SP"/lxml-*.dist-info "$VSP/" 2>/dev/null
if "$T/vlx/bin/python" -I -c 'import lxml.etree' 2>/dev/null && ! "$T/vlx/bin/python" -I -c 'import docx' 2>/dev/null; then
    H="$T/h6"; mkhome "$H"
    inst i6 "$H" "$T/kit" "$T/vlx/bin/python"
    [ "$(rc i6)" = 0 ] && pass "I6 exits 0" || { bad "I6 exits 0" "rc=$(rc i6)"; show i6; }
    [ -x "$H/.claude/skills/hwpx/scripts/hwpx" ] && pass "I6 hwpx installed" || bad "I6 hwpx installed" "missing"
    for s in $OFFICE; do
        [ ! -e "$H/.claude/skills/$s" ] && pass "I6 $s not installed" || bad "I6 $s not installed" "present"
        grep -i "$s" "$T/i6.out" | grep -qi 'skipped' && pass "I6 says $s skipped" || bad "I6 says $s skipped" "no line naming $s with 'skipped'"
    done
else
    bad "I6 lxml-only venv" "could not build it from $SP"
fi

# ---- I7. 오피스 skill 하나가 smoke 에 실패하면: 종료 ≠0, 이유를 말하고, skills 는 하나도 바뀌지 않는다 -----------------
mkkit "$T/kit7"
printf 'import sys\nprint("ERROR 일부러 망가뜨린 도구")\nsys.exit(1)\n' > "$T/kit7/claude-kit/skills/pptx/scripts/pptx_tool.py"
H="$T/h7"; mkhome "$H"
inst i7 "$H" "$T/kit7" "$PY"
[ "$(rc i7)" != 0 ] && pass "I7 broken pptx fails the install" || { bad "I7 broken pptx fails the install" "rc=0"; show i7; }
grep -qF 'the pptx skill does not run' "$T/i7.out" && grep -qF 'nothing was changed' "$T/i7.out" \
    && pass "I7 names pptx" || bad "I7 names pptx" "$(tail -3 "$T/i7.out")"
[ -z "$(ls -A "$H/.claude/skills" 2>/dev/null)" ] && pass "I7 no skill installed (not even hwpx)" || bad "I7 no skill installed (not even hwpx)" "$(ls "$H/.claude/skills")"
[ -z "$(find "$H/.claude" -name '*.partial' -o -name '.claude-lms-*' 2>/dev/null)" ] && pass "I7 no partial left" || bad "I7 no partial left" "found"
[ -z "$(find "$T/tmp" -maxdepth 1 -name 'claude-lms-*' 2>/dev/null)" ] && pass "I7 staging cleaned" || bad "I7 staging cleaned" "$(ls "$T/tmp")"

# ---- I8. --dry-run: 네 skill 을 모두 말하고 ~/.claude 에 아무것도 쓰지 않는다 -------------------------------------
H="$T/h8"; mkhome "$H"
inst i8 "$H" "$T/kit" "$PY" --dry-run
[ "$(rc i8)" = 0 ] && pass "I8 dry-run exits 0" || { bad "I8 dry-run exits 0" "rc=$(rc i8)"; show i8; }
for s in $SKS; do grep -F '[dry-run]' "$T/i8.out" | grep -q "skills/$s" && pass "I8 dry-run names $s" || bad "I8 dry-run names $s" "missing"; done
[ ! -e "$H/.claude" ] && pass "I8 dry-run writes nothing in ~/.claude" || bad "I8 dry-run writes nothing in ~/.claude" "$(find "$H/.claude" | head -3)"

# ---- I9. 도움말이 오피스 skill 을 말한다 ------------------------------------------------------------------------
"$G/install-claude-code.sh" --help > "$T/help.out" 2>&1
grep -- '--no-skills' "$T/help.out" | grep -q 'docx' && pass "I9 --no-skills help names office skills" || bad "I9 --no-skills help names office skills" "$(grep -- '--no-skills' "$T/help.out")"

# ---- R1. --with-router 없이: 라우터는 설치되지 않고, skipped 라인을 찍는다 --------------------------------------
H="$T/r1"; mkhome "$H"
inst r1 "$H" "$T/kit" "$PY"
[ "$(rc r1)" = 0 ] && pass "R1 exits 0" || { bad "R1 exits 0" "rc=$(rc r1)"; show r1; }
[ ! -e "$H/.guardian-llm" ] && pass "R1 no ~/.guardian-llm" || bad "R1 no ~/.guardian-llm" "$(find "$H/.guardian-llm" | head -3)"
[ ! -e "$H/Library/LaunchAgents/dev.guardian.llm-router.plist" ] && pass "R1 no LaunchAgent plist" || bad "R1 no LaunchAgent plist" "exists"
[ ! -e "$H/.local/bin/spark-model" ] && pass "R1 no spark-model" || bad "R1 no spark-model" "exists"
grep -i 'llm-router' "$T/r1.out" | grep -qi 'skipped' && pass "R1 says router skipped" \
    || bad "R1 says router skipped" "no llm-router skipped line"

# ---- R2. fastapi 없는 python 으로 --with-router: 쓰기 전에 실패하고 홈은 그대로 --------------------------------
H="$T/r2"; mkhome "$H"
inst r2 "$H" "$T/kit" /usr/bin/python3 --with-router
[ "$(rc r2)" != 0 ] && pass "R2 bad python fails" || { bad "R2 bad python fails" "rc=0"; show r2; }
grep -q 'fastapi' "$T/r2.out" && pass "R2 names fastapi" || bad "R2 names fastapi" "$(tail -3 "$T/r2.out")"
[ ! -e "$H/.local/bin/claude-lms" ] && pass "R2 no claude-lms" || bad "R2 no claude-lms" "exists"
[ ! -e "$H/.config" ] && pass "R2 no claude-lms env" || bad "R2 no claude-lms env" "$(find "$H/.config" | head -3)"
[ ! -e "$H/.claude" ] && pass "R2 no skills" || bad "R2 no skills" "$(find "$H/.claude" | head -3)"
[ ! -e "$H/.guardian-llm" ] && pass "R2 no router" || bad "R2 no router" "$(find "$H/.guardian-llm" | head -3)"

# ---- R3. --with-router --no-skills: 라우터 설치물 + env 600 + plist + CLAUDE_LMS_ROUTER=1240 -------------------
H="$T/r3"; mkhome "$H"
inst r3 "$H" "$T/kit" "$PY" --with-router --no-skills
[ "$(rc r3)" = 0 ] && pass "R3 exits 0" || { bad "R3 exits 0" "rc=$(rc r3)"; show r3; }
[ -f "$H/.guardian-llm/llm-router/router.py" ] && pass "R3 router.py installed" || bad "R3 router.py installed" "missing"
[ "$(stat -f %Lp "$H/.local/bin/spark-model" 2>/dev/null)" = 755 ] && pass "R3 spark-model 755" \
    || bad "R3 spark-model 755" "$(ls -l "$H/.local/bin/spark-model" 2>&1)"
[ "$(stat -f %Lp "$H/.config/llm-router/env" 2>/dev/null)" = 600 ] && pass "R3 router env mode 600" \
    || bad "R3 router env mode 600" "$(stat -f %Lp "$H/.config/llm-router/env" 2>/dev/null)"
[ -f "$H/Library/LaunchAgents/dev.guardian.llm-router.plist" ] && pass "R3 LaunchAgent plist" || bad "R3 LaunchAgent plist" "missing"
grep -q "^CLAUDE_LMS_ROUTER='http://127.0.0.1:1240'\$" "$H/.config/claude-lms/env" && pass "R3 CLAUDE_LMS_ROUTER 1240" \
    || bad "R3 CLAUDE_LMS_ROUTER 1240" "$(grep ROUTER "$H/.config/claude-lms/env")"

# ---- R4. --with-router --dry-run: 종료 0, 가짜 홈에 아무것도 안 쓴다 -------------------------------------------
H="$T/r4"; mkhome "$H"
inst r4 "$H" "$T/kit" "$PY" --with-router --dry-run
[ "$(rc r4)" = 0 ] && pass "R4 dry-run exits 0" || { bad "R4 dry-run exits 0" "rc=$(rc r4)"; show r4; }
[ ! -e "$H/.claude" ] && [ ! -e "$H/.config" ] && [ ! -e "$H/.guardian-llm" ] && [ ! -e "$H/Library" ] \
    && pass "R4 dry-run writes nothing" || bad "R4 dry-run writes nothing" "$(find "$H" -not -path "$H/.local*" -not -path "$H" | head -5)"
grep -F "CLAUDE_LMS_ROUTER" "$T/r4.out" | grep -q 1240 && pass "R4 dry-run names the router line" \
    || bad "R4 dry-run names the router line" "$(grep -F CLAUDE_LMS_ROUTER "$T/r4.out" | head -2)"

# ---- R5. 재설치: 다른 CLAUDE_LMS_* 키와 ROUTER 값은 그대로 -----------------------------------------------------
H="$T/r5"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
printf "CLAUDE_LMS_ROUTER='http://127.0.0.1:1299'\nCLAUDE_LMS_FAST=x\n" > "$H/.config/claude-lms/env"
inst r5a "$H" "$T/kit" "$PY"
[ "$(rc r5a)" = 0 ] && pass "R5a reinstall exits 0" || { bad "R5a reinstall exits 0" "rc=$(rc r5a)"; show r5a; }
grep -q "^CLAUDE_LMS_ROUTER='http://127.0.0.1:1299'\$" "$H/.config/claude-lms/env" && pass "R5a keeps ROUTER" \
    || bad "R5a keeps ROUTER" "$(grep ROUTER "$H/.config/claude-lms/env")"
grep -q '^CLAUDE_LMS_FAST=x$' "$H/.config/claude-lms/env" && pass "R5a keeps FAST" || bad "R5a keeps FAST" "missing"
inst r5b "$H" "$T/kit" "$PY" --with-router
[ "$(rc r5b)" = 0 ] && pass "R5b exits 0" || { bad "R5b exits 0" "rc=$(rc r5b)"; show r5b; }
grep -q "^CLAUDE_LMS_ROUTER='http://127.0.0.1:1299'\$" "$H/.config/claude-lms/env" && pass "R5b keeps ROUTER 1299" \
    || bad "R5b keeps ROUTER 1299" "$(grep ROUTER "$H/.config/claude-lms/env")"
grep -q '^CLAUDE_LMS_FAST=x$' "$H/.config/claude-lms/env" && pass "R5b keeps FAST" || bad "R5b keeps FAST" "missing"

# ---- S1. dry-run 은 토큰 값을 절대 찍지 않는다: 키 이름만 말하고 파일은 그대로 ---------------------------------
# (출력은 변수에 담아 case 로 본다 — 센티널 값 자체는 어디에도 출력하지 않는다)
H="$T/s1"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
printf "CLAUDE_LMS_TOKEN='SENTINEL_TOKEN_9f3a'\nCLAUDE_LMS_FAST='x'\n" > "$H/.config/claude-lms/env"
chmod 600 "$H/.config/claude-lms/env"
cp "$H/.config/claude-lms/env" "$T/s1.orig"
inst s1 "$H" "$T/kit" "$PY" --dry-run
[ "$(rc s1)" = 0 ] && pass "S1 dry-run exits 0" || { bad "S1 dry-run exits 0" "rc=$(rc s1)"; show s1; }
s1out="$(cat "$T/s1.out")"
case "$s1out" in *SENTINEL_TOKEN_9f3a*) bad "S1 dry-run never prints the token" "sentinel leaked" ;;
    *) pass "S1 dry-run never prints the token" ;; esac
case "$s1out" in *CLAUDE_LMS_TOKEN*) pass "S1 dry-run names the key" ;; *) bad "S1 dry-run names the key" "no key name" ;; esac
cmp -s "$T/s1.orig" "$H/.config/claude-lms/env" && pass "S1 dry-run leaves the file" || bad "S1 dry-run leaves the file" "changed"

# ---- S1b/S1c. 실제 설치가 conf 를 600 으로 다시 쓴다(호출자 umask 와 무관), 토큰 줄은 살아있다 --------------------
inst s1b "$H" "$T/kit" "$PY"
[ "$(rc s1b)" = 0 ] && pass "S1b exits 0" || { bad "S1b exits 0" "rc=$(rc s1b)"; show s1b; }
[ "$(stat -f %Lp "$H/.config/claude-lms/env")" = 600 ] && pass "S1b conf mode 600" \
    || bad "S1b conf mode 600" "$(stat -f %Lp "$H/.config/claude-lms/env")"
[ "$(grep -c "^CLAUDE_LMS_TOKEN='SENTINEL_TOKEN_9f3a'\$" "$H/.config/claude-lms/env")" = 1 ] && pass "S1b keeps TOKEN line" \
    || bad "S1b keeps TOKEN line" "missing"
[ "$(grep -c "^CLAUDE_LMS_FAST='x'\$" "$H/.config/claude-lms/env")" = 1 ] && pass "S1b keeps FAST line" \
    || bad "S1b keeps FAST line" "missing"
s1bout="$(cat "$T/s1b.out")"
case "$s1bout" in *SENTINEL_TOKEN_9f3a*) bad "S1b never prints the token" "sentinel leaked" ;;
    *) pass "S1b never prints the token" ;; esac
H="$T/s1c"; mkhome "$H"
( umask 022; inst s1c "$H" "$T/kit" "$PY" )
[ "$(rc s1c)" = 0 ] && [ "$(stat -f %Lp "$H/.config/claude-lms/env")" = 600 ] && pass "S1c conf 600 under umask 022" \
    || bad "S1c conf 600 under umask 022" "rc=$(rc s1c) mode=$(stat -f %Lp "$H/.config/claude-lms/env" 2>/dev/null)"

# ---- S2/S3. 데이터→코드: 여러 줄 인용값이나 확장이 든 값은 쓰기 전에 거부된다 ---------------------------------
H="$T/s2"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
{ printf "CLAUDE_LMS_FAST='literal\n"; printf 'CLAUDE_LMS_FAST=$(touch %s/pwned)\n' "$T"; printf "'\n"; } > "$H/.config/claude-lms/env"
chmod 600 "$H/.config/claude-lms/env"
cp "$H/.config/claude-lms/env" "$T/s2.orig"
inst s2 "$H" "$T/kit" "$PY"
[ "$(rc s2)" != 0 ] && pass "S2 refuses a multi-line value" || { bad "S2 refuses a multi-line value" "rc=0"; show s2; }
grep -Eq 'line [0-9]+' "$T/s2.out" && pass "S2 names a line number" || bad "S2 names a line number" "$(tail -2 "$T/s2.out")"
cmp -s "$T/s2.orig" "$H/.config/claude-lms/env" && pass "S2 leaves the file byte-identical" \
    || bad "S2 leaves the file byte-identical" "changed"
[ ! -e "$H/.local/bin/claude-lms" ] && [ ! -e "$H/.claude" ] && pass "S2 writes nothing else" \
    || bad "S2 writes nothing else" "$(ls "$H/.local/bin/claude-lms" "$H/.claude" 2>&1 | head -2)"
[ ! -e "$T/pwned" ] && pass "S2 runs no carried code" || bad "S2 runs no carried code" "marker exists"
H="$T/s3"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
printf 'CLAUDE_LMS_FAST="a$HOME"\n' > "$H/.config/claude-lms/env"
chmod 600 "$H/.config/claude-lms/env"
inst s3 "$H" "$T/kit" "$PY"
[ "$(rc s3)" != 0 ] && grep -Eq 'line [0-9]+' "$T/s3.out" && pass "S3 refuses a \$-holding value" \
    || { bad "S3 refuses a \$-holding value" "rc=$(rc s3)"; show s3; }

# ---- S4. 숫자가 든 키(CLAUDE_LMS_TIER2)도 살아남아 재설치를 이긴다 ----------------------------------------------
H="$T/s4"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
printf "CLAUDE_LMS_TIER2='a'\n" > "$H/.config/claude-lms/env"
inst s4a "$H" "$T/kit" "$PY"
grep -q "^CLAUDE_LMS_TIER2='a'\$" "$H/.config/claude-lms/env" && pass "S4 digit key carried" || bad "S4 digit key carried" "missing"
inst s4b "$H" "$T/kit" "$PY"
grep -q "^CLAUDE_LMS_TIER2='a'\$" "$H/.config/claude-lms/env" && pass "S4 digit key survives reinstall" \
    || bad "S4 digit key survives reinstall" "missing"

# ---- S5. 주석 줄의 홀수 인용부호('# don't touch')는 거부하지 않는다(S2 의 여러 줄 값은 여전히 거부) ----
H="$T/s5"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
printf "# don't touch\nCLAUDE_LMS_FAST='x'\n" > "$H/.config/claude-lms/env"
chmod 600 "$H/.config/claude-lms/env"
inst s5 "$H" "$T/kit" "$PY"
[ "$(rc s5)" = 0 ] && pass "S5 comment apostrophe reinstalls fine" || { bad "S5 comment apostrophe reinstalls fine" "rc=$(rc s5)"; show s5; }
grep -q "^CLAUDE_LMS_FAST='x'\$" "$H/.config/claude-lms/env" && pass "S5 keeps FAST" || bad "S5 keeps FAST" "missing"

# ---- S6. 옛 버전이 남긴 stale "${CONF}.partial": 결과 mode 600 도, symlink 뚫린 쓰기도 없다 --------------
# (mktemp 고유 이름 쓰기라 고정 이름 partial 은 이제 읽지도 쓰지도 않는다)
H="$T/s6a"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
echo stale > "$H/.config/claude-lms/env.partial"
chmod 644 "$H/.config/claude-lms/env.partial"
( umask 022; inst s6a "$H" "$T/kit" "$PY" )
[ "$(rc s6a)" = 0 ] && [ "$(stat -f %Lp "$H/.config/claude-lms/env")" = 600 ] && pass "S6a stale 644 partial: conf born 600" \
    || bad "S6a stale 644 partial: conf born 600" "rc=$(rc s6a) mode=$(stat -f %Lp "$H/.config/claude-lms/env" 2>/dev/null)"
H="$T/s6b"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
echo target-unchanged > "$H/.config/claude-lms/partial-target"
ln -s partial-target "$H/.config/claude-lms/env.partial"
( umask 022; inst s6b "$H" "$T/kit" "$PY" )
[ "$(rc s6b)" = 0 ] && [ "$(stat -f %Lp "$H/.config/claude-lms/env")" = 600 ] && pass "S6b symlink partial: conf born 600" \
    || bad "S6b symlink partial: conf born 600" "rc=$(rc s6b) mode=$(stat -f %Lp "$H/.config/claude-lms/env" 2>/dev/null)"
[ "$(cat "$H/.config/claude-lms/partial-target" 2>/dev/null)" = "target-unchanged" ] && pass "S6b symlink not written through" \
    || bad "S6b symlink not written through" "target changed"

# ---- SP1. 시스템 프롬프트·claude-vscode 설치: conf 옆에 644, 래퍼는 755, conf 에는 힌트 주석만 --------------
H="$T/sp1"; mkhome "$H"
inst sp1 "$H" "$T/kit" "$PY" --no-skills
[ "$(rc sp1)" = 0 ] && pass "SP1 exits 0" || { bad "SP1 exits 0" "rc=$(rc sp1)"; show sp1; }
cmp -s "$T/kit/claude-kit/system-prompt.md" "$H/.config/claude-lms/system-prompt.md" && pass "SP1 system-prompt.md copied verbatim" \
    || bad "SP1 system-prompt.md copied verbatim" "differs from the kit's"
[ "$(stat -f %Lp "$H/.config/claude-lms/system-prompt.md" 2>/dev/null)" = 644 ] && pass "SP1 system-prompt.md mode 644" \
    || bad "SP1 system-prompt.md mode 644" "$(stat -f %Lp "$H/.config/claude-lms/system-prompt.md" 2>/dev/null)"
cmp -s "$G/claude-vscode" "$H/.local/bin/claude-vscode" && pass "SP1 claude-vscode copied verbatim" \
    || bad "SP1 claude-vscode copied verbatim" "differs from the repo's"
[ "$(stat -f %Lp "$H/.local/bin/claude-vscode" 2>/dev/null)" = 755 ] && pass "SP1 claude-vscode mode 755" \
    || bad "SP1 claude-vscode mode 755" "$(stat -f %Lp "$H/.local/bin/claude-vscode" 2>/dev/null)"
grep -qF "# CLAUDE_LMS_SYSTEM_PROMPT_FILE='$H/.config/claude-lms/system-prompt.md'" "$H/.config/claude-lms/env" \
    && pass "SP1 hint comment written" || bad "SP1 hint comment written" "$(grep SYSTEM_PROMPT_FILE "$H/.config/claude-lms/env")"
[ -z "$(grep '^CLAUDE_LMS_SYSTEM_PROMPT_FILE=' "$H/.config/claude-lms/env")" ] && pass "SP1 prompt left off" \
    || bad "SP1 prompt left off" "an active line exists"

# ---- SP2. 재설치: 같은 내용은 그대로, 손본 것은 bak 으로 남기고 교체 ------------------------------------------
inst sp2a "$H" "$T/kit" "$PY" --no-skills
[ "$(rc sp2a)" = 0 ] && pass "SP2a rerun exits 0" || { bad "SP2a rerun exits 0" "rc=$(rc sp2a)"; show sp2a; }
grep -qF "$H/.config/claude-lms/system-prompt.md already up to date" "$T/sp2a.out" && pass "SP2a unchanged prompt kept" \
    || bad "SP2a unchanged prompt kept" "no 'already up to date' line"
[ -z "$(ls "$H/.config/claude-lms" | grep '^system-prompt.md.bak-')" ] && pass "SP2a no backup made" || bad "SP2a no backup made" "a bak exists"
echo '내 프롬프트' > "$H/.config/claude-lms/system-prompt.md"
inst sp2b "$H" "$T/kit" "$PY" --no-skills
[ "$(rc sp2b)" = 0 ] && pass "SP2b exits 0" || { bad "SP2b exits 0" "rc=$(rc sp2b)"; show sp2b; }
bak="$(ls -d "$H/.config/claude-lms"/system-prompt.md.bak-* 2>/dev/null | head -1)"
[ -n "$bak" ] && [ "$(cat "$bak" 2>/dev/null)" = "내 프롬프트" ] && pass "SP2b modified copy kept as .bak" \
    || bad "SP2b modified copy kept as .bak" "backup '${bak:-none}'"
cmp -s "$T/kit/claude-kit/system-prompt.md" "$H/.config/claude-lms/system-prompt.md" && pass "SP2b replaced from the kit" \
    || bad "SP2b replaced from the kit" "still the modified text"
[ "$(ls "$H/.config/claude-lms" | grep -c '^system-prompt.md.bak-')" = 1 ] && pass "SP2b exactly one bak" \
    || bad "SP2b exactly one bak" "$(ls "$H/.config/claude-lms" | grep '^system-prompt.md.bak-')"
[ "$(stat -f %Lp "$H/.config/claude-lms/system-prompt.md")" = 644 ] && pass "SP2b replaced file mode 644" \
    || bad "SP2b replaced file mode 644" "$(stat -f %Lp "$H/.config/claude-lms/system-prompt.md")"

# ---- SP3. 이미 값이 있으면(carry): 그 줄이 이기고 힌트 주석은 없다 --------------------------------------------
H="$T/sp3"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
printf "CLAUDE_LMS_SYSTEM_PROMPT_FILE='/custom/prompt.md'\nCLAUDE_LMS_FAST='x'\n" > "$H/.config/claude-lms/env"
chmod 600 "$H/.config/claude-lms/env"
inst sp3 "$H" "$T/kit" "$PY" --no-skills
[ "$(rc sp3)" = 0 ] && pass "SP3 exits 0" || { bad "SP3 exits 0" "rc=$(rc sp3)"; show sp3; }
grep -q "^CLAUDE_LMS_SYSTEM_PROMPT_FILE='/custom/prompt.md'\$" "$H/.config/claude-lms/env" && pass "SP3 value carried over" \
    || bad "SP3 value carried over" "$(grep SYSTEM_PROMPT_FILE "$H/.config/claude-lms/env")"
[ -z "$(grep '^# CLAUDE_LMS_SYSTEM_PROMPT_FILE=' "$H/.config/claude-lms/env")" ] && pass "SP3 no hint beside a carried value" \
    || bad "SP3 no hint beside a carried value" "hint written anyway"

# ---- SP4. 옛 kit(두 파일 없음): 건너뛰고 안내만, conf 에 힌트도 없다 -------------------------------------------
mkkit "$T/kitsp4"; rm "$T/kitsp4/claude-vscode" "$T/kitsp4/claude-kit/system-prompt.md"
H="$T/sp4"; mkhome "$H"
inst sp4 "$H" "$T/kitsp4" "$PY" --no-skills
[ "$(rc sp4)" = 0 ] && pass "SP4 old-kit install exits 0" || { bad "SP4 old-kit install exits 0" "rc=$(rc sp4)"; show sp4; }
grep -qF 'no system-prompt.md in' "$T/sp4.out" && pass "SP4 names the skipped prompt" || bad "SP4 names the skipped prompt" "no skip line"
grep -qF 'no claude-vscode in' "$T/sp4.out" && pass "SP4 names the skipped wrapper" || bad "SP4 names the skipped wrapper" "no skip line"
[ ! -e "$H/.config/claude-lms/system-prompt.md" ] && [ ! -e "$H/.local/bin/claude-vscode" ] && pass "SP4 writes neither file" \
    || bad "SP4 writes neither file" "one of them exists"
[ -z "$(grep 'CLAUDE_LMS_SYSTEM_PROMPT_FILE' "$H/.config/claude-lms/env")" ] && pass "SP4 no hint without the file" \
    || bad "SP4 no hint without the file" "$(grep SYSTEM_PROMPT_FILE "$H/.config/claude-lms/env")"

# ---- SP5. --dry-run: 힌트·프롬프트 설치를 말하고 아무것도 쓰지 않는다 -----------------------------------------
H="$T/sp5"; mkhome "$H"
inst sp5 "$H" "$T/kit" "$PY" --no-skills --dry-run
[ "$(rc sp5)" = 0 ] && pass "SP5 dry-run exits 0" || { bad "SP5 dry-run exits 0" "rc=$(rc sp5)"; show sp5; }
grep -qF "[dry-run] add # CLAUDE_LMS_SYSTEM_PROMPT_FILE='$H/.config/claude-lms/system-prompt.md'" "$T/sp5.out" \
    && pass "SP5 dry-run names the hint" || bad "SP5 dry-run names the hint" "$(grep SYSTEM_PROMPT_FILE "$T/sp5.out")"
grep -qF "[dry-run] cp $T/kit/claude-kit/system-prompt.md" "$T/sp5.out" && pass "SP5 dry-run names the prompt copy" \
    || bad "SP5 dry-run names the prompt copy" "$(grep -F 'system-prompt.md' "$T/sp5.out" | head -2)"
[ ! -e "$H/.config/claude-lms/system-prompt.md" ] && [ ! -e "$H/.local/bin/claude-vscode" ] && pass "SP5 dry-run writes neither file" \
    || bad "SP5 dry-run writes neither file" "one of them exists"

# ---- P1–P7. 사전 점검: URL·context·model 이 거부되면 무엇이든 쓰기 전에 죽는다 --------------------------------
# 스텁 LM Studio: 정적 v1/models 파일 하나를 127.0.0.1 에서 돌린다. 서버 프로세스가 직접 ("127.0.0.1", 0) 에
# 바인드해 실제 포트를 파일에 적은 뒤 serve_forever 한다 — 포트를 얻으려고 소켓을 한 번 열었다 닫는 사이를
# 다른 프로세스가 가져가는 경주가 없다(껐다 켠 http.server 와는 다름). 요청 로그는 조용히.
# 첫 id 를 text-embedding-x 로 두어 embed 걸러내기(P5)도 같이 본다. 진짜 LM Studio(:1234)는 건드리지 않는다 —
# 이 파일의 모든 사례가 명시적 --lmstudio-url 을 받고, 아래 사례도 각자 넘긴다.
STUB_PID=""
STUB_PORT=""
start_stub() {
    STUB_DIR="$(mktemp -d "$T/stub.XXXXXX")"
    mkdir -p "$STUB_DIR/v1"
    printf '{"data":[{"id":"text-embedding-x"},{"id":"other/a"},{"id":"other/b"}]}' > "$STUB_DIR/v1/models"
    STUB_PORT_FILE="$STUB_DIR.port"
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
' "$STUB_PORT_FILE" "$STUB_DIR" >/dev/null 2>&1 &
    STUB_PID=$!
    local i
    for i in $(seq 1 50); do
        [ -s "$STUB_PORT_FILE" ] && STUB_PORT="$(cat "$STUB_PORT_FILE")"
        [ -n "$STUB_PORT" ] && curl -fsS -m 1 "http://127.0.0.1:$STUB_PORT/v1/models" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    bad "stub LM Studio comes up" "no answer (pid ${STUB_PID:-?}, port ${STUB_PORT:-?})"
    exit 1
}
# 마지막 스텁 사례가 끝난 뒤 부른다(trap 은 스크립트 전체의 안전망으로 그대로).
stop_stub() {
    [ -n "${STUB_PID:-}" ] && kill "$STUB_PID" 2>/dev/null
    STUB_PID=""
}
# inst 는 항상 --model=test-model 을 넘기므로, --model 없이 돌려야 하는 사례는 이렇게 직접 부른다.
instnomodel() {
    local n="$1" h="$2"; shift 2
    HOME="$h" CLAUDE_LMS_PY="$PY" XDG_CONFIG_HOME="$h/.config" TMPDIR="$T/tmp" \
        "$T/kit/install-claude-code.sh" --no-path "$@" > "$T/$n.out" 2>&1
    echo $? > "$T/$n.rc"
}
emptyhome() { [ -z "$(find "$1" -mindepth 1 2>/dev/null)" ]; }

# P1. --context=abc: 거부하고 가짜 홈에는 아무것도 남지 않는다
H="$T/p1"; mkdir -p "$H"
inst p1 "$H" "$T/kit" "$PY" --context=abc
[ "$(rc p1)" != 0 ] && pass "P1 bad --context fails" || { bad "P1 bad --context fails" "rc=0"; show p1; }
grep -qF -- '--context must be a number' "$T/p1.out" && pass "P1 names the context error" \
    || bad "P1 names the context error" "$(tail -2 "$T/p1.out")"
emptyhome "$H" && pass "P1 writes nothing" || bad "P1 writes nothing" "$(find "$H" -mindepth 1 | head -3)"

# P2. --model 도 conf 도 ~/llm-wiki/.env 도 없으면: 거부하고 가짜 홈은 비어 있다
H="$T/p2"; mkdir -p "$H"
instnomodel p2 "$H" --lmstudio-url=http://127.0.0.1:9
[ "$(rc p2)" != 0 ] && pass "P2 no model anywhere fails" || { bad "P2 no model anywhere fails" "rc=0"; show p2; }
grep -qF 'no model to use' "$T/p2.out" && pass "P2 says no model to use" || bad "P2 says no model to use" "$(tail -2 "$T/p2.out")"
emptyhome "$H" && pass "P2 writes nothing" || bad "P2 writes nothing" "$(find "$H" -mindepth 1 | head -3)"

# P3. 스텁이 나열한 목록에 없는 모델: 거부하고 가짜 홈은 비어 있다
start_stub
H="$T/p3"; mkdir -p "$H"
inst p3 "$H" "$T/kit" "$PY" --model=absent/x --lmstudio-url="http://127.0.0.1:$STUB_PORT"
[ "$(rc p3)" != 0 ] && pass "P3 unlisted model fails" || { bad "P3 unlisted model fails" "rc=0"; show p3; }
grep -qF 'has no model absent/x' "$T/p3.out" && pass "P3 names the missing model" \
    || bad "P3 names the missing model" "$(tail -2 "$T/p3.out")"
emptyhome "$H" && pass "P3 writes nothing" || bad "P3 writes nothing" "$(find "$H" -mindepth 1 | head -3)"

# P4. 목록에 있는 모델로 --dry-run: 종료 0, 가짜 홈은 여전히 비어 있다
H="$T/p4"; mkdir -p "$H"
inst p4 "$H" "$T/kit" "$PY" --model=other/b --lmstudio-url="http://127.0.0.1:$STUB_PORT" --dry-run
[ "$(rc p4)" = 0 ] && pass "P4 dry-run with a listed model exits 0" \
    || { bad "P4 dry-run with a listed model exits 0" "rc=$(rc p4)"; show p4; }
emptyhome "$H" && pass "P4 dry-run writes nothing" || bad "P4 dry-run writes nothing" "$(find "$H" -mindepth 1 | head -3)"

# P5. --model 없이: 스텁의 첫 LLM 을 고른다(text-embedding-x 는 embed 걸러로 건너뛰고 other/a)
H="$T/p5"; mkdir -p "$H"
instnomodel p5 "$H" --lmstudio-url="http://127.0.0.1:$STUB_PORT" --dry-run
[ "$(rc p5)" = 0 ] && pass "P5 dry-run without --model exits 0" \
    || { bad "P5 dry-run without --model exits 0" "rc=$(rc p5)"; show p5; }
grep -qF 'model other/a' "$T/p5.out" && pass "P5 picks the first LLM, embed skipped" \
    || bad "P5 picks the first LLM, embed skipped" "$(tail -3 "$T/p5.out")"
emptyhome "$H" && pass "P5 dry-run writes nothing" || bad "P5 dry-run writes nothing" "$(find "$H" -mindepth 1 | head -3)"

# P6. export 접두사가 붙은 conf 의 MODEL: 재설치가 그 값을 잃지 않는다(파일은 grep 으로만 본다)
H="$T/p6"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
printf "export CLAUDE_LMS_MODEL='keep/me'\nCLAUDE_LMS_FAST='x'\n" > "$H/.config/claude-lms/env"
chmod 600 "$H/.config/claude-lms/env"
instnomodel p6 "$H" --lmstudio-url=http://127.0.0.1:9 --no-skills
[ "$(rc p6)" = 0 ] && pass "P6 export-prefixed MODEL reinstalls" || { bad "P6 export-prefixed MODEL reinstalls" "rc=$(rc p6)"; show p6; }
[ "$(grep -c "^CLAUDE_LMS_MODEL='keep/me'\$" "$H/.config/claude-lms/env" 2>/dev/null)" = 1 ] && pass "P6 keeps the MODEL line" \
    || bad "P6 keeps the MODEL line" "grep -c=$(grep -c '^CLAUDE_LMS_MODEL' "$H/.config/claude-lms/env" 2>/dev/null)"
grep -q "^CLAUDE_LMS_FAST='x'\$" "$H/.config/claude-lms/env" && pass "P6 keeps FAST" || bad "P6 keeps FAST" "missing"

# P7. 들여쓰기+큰따옴표 conf 의 CONTEXT: 값이 읽혀 그대로 다시 쓰인다
H="$T/p7"; mkhome "$H"
mkdir -p "$H/.config/claude-lms"
printf '  CLAUDE_LMS_CONTEXT="32768"\n' > "$H/.config/claude-lms/env"
chmod 600 "$H/.config/claude-lms/env"
inst p7 "$H" "$T/kit" "$PY"
[ "$(rc p7)" = 0 ] && pass "P7 indented quoted CONTEXT exits 0" \
    || { bad "P7 indented quoted CONTEXT exits 0" "rc=$(rc p7)"; show p7; }
grep -q '^CLAUDE_LMS_CONTEXT=32768$' "$H/.config/claude-lms/env" && pass "P7 CONTEXT read back as 32768" \
    || bad "P7 CONTEXT read back as 32768" "$(grep '^CLAUDE_LMS_CONTEXT' "$H/.config/claude-lms/env" 2>/dev/null)"

# P8. conf 의 MODEL 이 큰따옴표 안에 작은따옴표를 담으면("a';printf INJ; #'"): conf-literal 점검은 이 줄을
# 통과시키지만(큰따옴표 가지 안의 작은따옴표는 합법), 설치는 쓰기 전에 모델 거부로 죽는다 — '...' 리터럴이
# 일찍 닫히는 shell 인젝션이므로. conf 는 바이트 그대로, claude·claude-lms 도 깔리지 않는다.
H="$T/p8"; mkdir -p "$H/.config/claude-lms"
printf "%s\n" "CLAUDE_LMS_MODEL=\"a';printf INJ; #'\"" > "$H/.config/claude-lms/env"
chmod 600 "$H/.config/claude-lms/env"
cp "$H/.config/claude-lms/env" "$T/p8.orig"
instnomodel p8 "$H" --lmstudio-url=http://127.0.0.1:9 --no-skills
[ "$(rc p8)" != 0 ] && pass "P8 quote-holding conf MODEL fails" || { bad "P8 quote-holding conf MODEL fails" "rc=0"; show p8; }
! grep -q 'not a single-line literal' "$T/p8.out" && pass "P8 conf-literal check accepts the line" \
    || bad "P8 conf-literal check accepts the line" "refused as a conf literal instead"
grep -qF 'the model from' "$T/p8.out" && grep -qF 'single quote or a control character' "$T/p8.out" \
    && pass "P8 names the model refusal" || bad "P8 names the model refusal" "$(tail -2 "$T/p8.out")"
cmp -s "$T/p8.orig" "$H/.config/claude-lms/env" && pass "P8 conf byte-identical" || bad "P8 conf byte-identical" "changed"
[ ! -e "$H/.local/bin/claude" ] && pass "P8 no claude link" || bad "P8 no claude link" "exists"
[ ! -e "$H/.local/bin/claude-lms" ] && pass "P8 no claude-lms" || bad "P8 no claude-lms" "exists"

# P9. --model 값에 줄바꿈: 거부하고(새 줄은 conf 에 줄을 추가한다) 가짜 홈은 비어 있다
H="$T/p9"; mkdir -p "$H"
instnomodel p9 "$H" --model=$'x\ny' --lmstudio-url=http://127.0.0.1:9
[ "$(rc p9)" != 0 ] && pass "P9 newline-holding --model fails" || { bad "P9 newline-holding --model fails" "rc=0"; show p9; }
grep -qF 'single quote or a control character' "$T/p9.out" && pass "P9 names the refusal" \
    || bad "P9 names the refusal" "$(tail -2 "$T/p9.out")"
emptyhome "$H" && pass "P9 writes nothing" || bad "P9 writes nothing" "$(find "$H" -mindepth 1 | head -3)"

# P10. --lmstudio-url 값에 작은따옴표: 거부하고 가짜 홈은 비어 있다(inst 의 기본 URL 을 덮어쓴다)
H="$T/p10"; mkdir -p "$H"
inst p10 "$H" "$T/kit" "$PY" --lmstudio-url="http://127.0.0.1:9/a'b"
[ "$(rc p10)" != 0 ] && pass "P10 quote-holding URL fails" || { bad "P10 quote-holding URL fails" "rc=0"; show p10; }
emptyhome "$H" && pass "P10 writes nothing" || bad "P10 writes nothing" "$(find "$H" -mindepth 1 | head -3)"

# P11. 스텁 목록의 첫 id 가 빈 문자열: 빈 줄을 모델로 삼지 않고 다음 LLM(other/a)을 고른다
printf '{"data":[{"id":""},{"id":"other/a"}]}' > "$STUB_DIR/v1/models"
H="$T/p11"; mkdir -p "$H"
instnomodel p11 "$H" --lmstudio-url="http://127.0.0.1:$STUB_PORT" --dry-run
[ "$(rc p11)" = 0 ] && pass "P11 blank first id, dry-run exits 0" \
    || { bad "P11 blank first id, dry-run exits 0" "rc=$(rc p11)"; show p11; }
grep -qF 'model other/a' "$T/p11.out" && pass "P11 skips the blank id, picks other/a" \
    || bad "P11 skips the blank id, picks other/a" "$(tail -3 "$T/p11.out")"
emptyhome "$H" && pass "P11 dry-run writes nothing" || bad "P11 dry-run writes nothing" "$(find "$H" -mindepth 1 | head -3)"
stop_stub

# ---- P12. 깨진 pptx kit 을 완전히 빈 홈에: smoke 실패는 무엇이든 쓰기 전에 죽는다 ------------------------------
# (I7 은 claude 가 이미 깔린 홈에서 skills 만 보았다. 여기선 홈을 비워 §1 바이너리·§2 claude-lms·conf 도 절대
# 생기지 않음을 본다. kit7 의 pptx_tool.py 는 I7 이 일부러 망가뜨린 것: hwpx·docx·xlsx 는 smoke 를 통과한 뒤
# pptx 에서 죽는다 — 빈 홈 판정(emptyhome)이 이 사례의 핵심이다)
H="$T/p12"; mkdir -p "$H"
inst p12 "$H" "$T/kit7" "$PY"
[ "$(rc p12)" != 0 ] && pass "P12 broken pptx on an empty home fails" || { bad "P12 broken pptx on an empty home fails" "rc=0"; show p12; }
grep -qF 'the pptx skill does not run' "$T/p12.out" && grep -qF 'nothing was changed' "$T/p12.out" \
    && pass "P12 names pptx" || bad "P12 names pptx" "$(tail -3 "$T/p12.out")"
emptyhome "$H" && pass "P12 writes nothing at all" || bad "P12 writes nothing at all" "$(find "$H" -mindepth 1 | head -5)"
[ -z "$(find "$T/tmp" -maxdepth 1 -name 'claude-lms-*' 2>/dev/null)" ] && pass "P12 staging cleaned" \
    || bad "P12 staging cleaned" "$(ls "$T/tmp")"

# ---- P13·P14·P15. codesign -dv 출력이 클 때의 세 얼굴: 좋은 바이너리 통과, 다른 팀 거부, 상위 문자열 팀 거부 ----
# 가짜 codesign 을 PATH 맨 앞에 둔다(인스톨러는 codesign 을 경로 없이 부른다): --verify 인자가 있으면 진짜에
# 위임(exec)하고, -dv 면 진짜의 Identifier 줄을 찍은 뒤 주어진 TeamIdentifier 줄과 약 2MB 의 filler 를 stderr 로
# 쏟는다. 불릴 때마다 witness 파일을 만들어 가짜가 실제로 쓰였음을 남기고, 진짜 -dv 가 실패하면 그 종료 상태로
# 나간다(0 으로 속이지 않는다). check_binary 의 옛 `printf | grep -qx` 는 grep 이 첫 일치에서 일찍 끝나면 printf
# 가 SIGPIPE(141)로 죽고 pipefail 이 좋은 바이너리까지 거부했다 — 사전 점검과 복사 뒤의 두 호출 지점이 모두 가짜를
# 지난다. 진짜 팀 id 는 인스톨러의 TEAM 변수에서 읽는다(여기서 짐작해 박지 않는다).
TEAMID="$(sed -n 's/^TEAM="\([A-Za-z0-9]*\)"$/\1/p' "$G/install-claude-code.sh")"
[ -n "$TEAMID" ] && pass "P13 team id read from the installer" \
    || bad "P13 team id read from the installer" "no TEAM=\"...\" line in install-claude-code.sh"
# mkfakecs <dir> <witness> <TeamIdentifier 줄>: 위의 가짜 codesign 을 만든다. heredoc 인용을 풀어 witness 절대
# 경로와 팀 줄이 생성 시점에 박히게 하고, 나머지 확장은 \$ 로 살린다.
mkfakecs() {
    local d="$1" w="$2" team="$3"
    mkdir -p "$d"
    cat > "$d/codesign" <<FCS
#!/bin/bash
printf '' > '${w}'
for a in "\$@"; do
    [ "\$a" = "--verify" ] && exec /usr/bin/codesign "\$@"
done
out="\$(/usr/bin/codesign "\$@" 2>&1)"
st=\$?
printf '%s\n' "\$out" | sed -n '/^Identifier=/p' >&2
echo '${team}' >&2
i=0
while [ "\$i" -lt 30000 ]; do
    printf 'filler-%06d-abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz0123456789\n' "\$i" >&2
    i=\$((i + 1))
done
exit "\$st"
FCS
    chmod 755 "$d/codesign"
}
# P13. 진짜 팀 줄 + 약 2MB 출력: 좋은 바이너리가 그대로 통과한다
H="$T/p13"; mkdir -p "$H"
mkfakecs "$T/p13bin" "$T/p13.ran" "TeamIdentifier=$TEAMID"
PATH="$T/p13bin:$PATH" inst p13 "$H" "$T/kit" "$PY" --no-skills
[ "$(rc p13)" = 0 ] && pass "P13 large codesign output still accepted" \
    || { bad "P13 large codesign output still accepted" "rc=$(rc p13)"; show p13; }
[ -f "$T/p13.ran" ] && pass "P13 the fake codesign was used" || bad "P13 the fake codesign was used" "no witness"
[ -x "$H/.local/bin/claude" ] && pass "P13 claude installed anyway" || bad "P13 claude installed anyway" "missing"

# ---- P14. P13 의 음성 대조: -dv 가 다른 TeamIdentifier 를 말하면 (큰 출력에서도) 거부된다 ----------------------
H="$T/p14"; mkdir -p "$H"
mkfakecs "$T/p14bin" "$T/p14.ran" 'TeamIdentifier=XXXXXXXXXX'
PATH="$T/p14bin:$PATH" inst p14 "$H" "$T/kit" "$PY" --dry-run --no-skills
[ "$(rc p14)" != 0 ] && pass "P14 wrong TeamIdentifier refused" || { bad "P14 wrong TeamIdentifier refused" "rc=0"; show p14; }
grep -qF "is not Anthropic's signed Claude Code" "$T/p14.out" && pass "P14 names the signature refusal" \
    || bad "P14 names the signature refusal" "$(tail -2 "$T/p14.out")"
[ -f "$T/p14.ran" ] && pass "P14 the fake codesign was used" || bad "P14 the fake codesign was used" "no witness"
emptyhome "$H" && pass "P14 writes nothing" || bad "P14 writes nothing" "$(find "$H" -mindepth 1 | head -3)"

# ---- P15. TeamIdentifier 가 진짜 id 에 한 글자 붙은 상위 문자열이면: 줄 전체 일치가 아니므로 거부된다 ---------
# (Identifier 줄은 진짜로 두어 거부 이유가 팀 줄 하나로 좁혀지게 한다)
H="$T/p15"; mkdir -p "$H"
mkfakecs "$T/p15bin" "$T/p15.ran" "TeamIdentifier=${TEAMID}X"
PATH="$T/p15bin:$PATH" inst p15 "$H" "$T/kit" "$PY" --dry-run --no-skills
[ "$(rc p15)" != 0 ] && pass "P15 superstring TeamIdentifier refused" || { bad "P15 superstring TeamIdentifier refused" "rc=0"; show p15; }
grep -qF "is not Anthropic's signed Claude Code" "$T/p15.out" && pass "P15 names the signature refusal" \
    || bad "P15 names the signature refusal" "$(tail -2 "$T/p15.out")"
[ -f "$T/p15.ran" ] && pass "P15 the fake codesign was used" || bad "P15 the fake codesign was used" "no witness"
emptyhome "$H" && pass "P15 writes nothing" || bad "P15 writes nothing" "$(find "$H" -mindepth 1 | head -3)"

# ---- R6. kit 에 llm-router/router.py 가 없으면 --with-router 는 쓰기 전에 거부된다 ---------------------------
mkkit "$T/kit6"; rm "$T/kit6/llm-router/router.py"
H="$T/r6"; mkhome "$H"
inst r6 "$H" "$T/kit6" "$PY" --with-router
[ "$(rc r6)" != 0 ] && pass "R6 kit without router.py fails" || { bad "R6 kit without router.py fails" "rc=0"; show r6; }
grep -q 'llm-router/router.py' "$T/r6.out" && pass "R6 names router.py" || bad "R6 names router.py" "$(tail -2 "$T/r6.out")"
[ ! -e "$H/.local/bin/claude-lms" ] && [ ! -e "$H/.config" ] && [ ! -e "$H/.guardian-llm" ] && pass "R6 writes nothing" \
    || bad "R6 writes nothing" "$(find "$H" -not -path "$H/.local*" -not -path "$H" | head -3)"

# ---- R7. python 이 아직 없는 맥: --dry-run 은 통과하고 안내만, 실제 실행은 거부 ---------------------------------
H="$T/r7"; mkhome "$H"
inst r7a "$H" "$T/kit" /nonexistent/python --with-router --dry-run
[ "$(rc r7a)" = 0 ] && pass "R7a dry-run without python exits 0" || { bad "R7a dry-run without python exits 0" "rc=$(rc r7a)"; show r7a; }
grep -q 'python not there yet' "$T/r7a.out" && pass "R7a says python not there yet" || bad "R7a says python not there yet" "$(tail -3 "$T/r7a.out")"
[ ! -e "$H/.config" ] && [ ! -e "$H/.guardian-llm" ] && [ ! -e "$H/Library" ] && [ ! -e "$H/.claude" ] \
    && pass "R7a dry-run writes nothing" || bad "R7a dry-run writes nothing" "$(find "$H" -not -path "$H/.local*" -not -path "$H" | head -3)"
inst r7b "$H" "$T/kit" /nonexistent/python --with-router
[ "$(rc r7b)" != 0 ] && pass "R7b real run without python fails" || { bad "R7b real run without python fails" "rc=0"; show r7b; }

# ---- R8. 포트 읽기는 router.py 파서와 똑같이: 따옴표·export·뒤 줄 우선 ----------------------------------------
port_case() {
    local n="$1" envtext="$2" want="$3" h
    h="$T/p-$n"; mkhome "$h"; mkdir -p "$h/.config/llm-router"
    printf '%s\n' "$envtext" > "$h/.config/llm-router/env"; chmod 600 "$h/.config/llm-router/env"
    inst "$n" "$h" "$T/kit" "$PY" --with-router --no-skills
    [ "$(rc "$n")" = 0 ] && grep -q "^CLAUDE_LMS_ROUTER='http://127.0.0.1:${want}'\$" "$h/.config/claude-lms/env" \
        && pass "R8 port $n -> ${want}" || { bad "R8 port $n -> ${want}" "rc=$(rc "$n") $(grep ROUTER "$h/.config/claude-lms/env" 2>&1)"; }
}
port_case q1 "LLM_ROUTER_PORT='1250'" 1250
port_case q2 'export LLM_ROUTER_PORT="1260"' 1260
port_case q3 $'LLM_ROUTER_PORT=1270\nLLM_ROUTER_PORT=1280' 1280
# q5: router.py 는 'export ' (공백 한 칸) 만 접두사로 벗기므로, export 뒤 탭은 key 의 일부가 되어
# 인식되지 않는다 — 여기서도 1250 이 아니라 기본 1240 을 내야 한다.
port_case q5 $'export\tLLM_ROUTER_PORT=1250' 1240
# q4: 라우터와 그 인스톨러는 $HOME/.config 만 보므로, 포트도 XDG_CONFIG_HOME 이 아니라 거기서 읽어야 한다.
h4="$T/p-q4"; mkhome "$h4"; mkdir -p "$h4/.config/llm-router" "$h4/xdg"
printf "LLM_ROUTER_PORT='1255'\n" > "$h4/.config/llm-router/env"; chmod 600 "$h4/.config/llm-router/env"
HOME="$h4" CLAUDE_LMS_PY="$PY" XDG_CONFIG_HOME="$h4/xdg" TMPDIR="$T/tmp" \
    "$T/kit/install-claude-code.sh" --model=test-model --lmstudio-url=http://127.0.0.1:9 --no-path --with-router --no-skills \
    > "$T/q4.out" 2>&1
echo $? > "$T/q4.rc"
[ "$(rc q4)" = 0 ] && grep -q "^CLAUDE_LMS_ROUTER='http://127.0.0.1:1255'\$" "$h4/xdg/claude-lms/env" \
    && pass "R8 port read from \$HOME/.config, not XDG" \
    || { bad "R8 port read from \$HOME/.config, not XDG" "rc=$(rc q4) $(grep ROUTER "$h4/xdg/claude-lms/env" 2>&1)"; }

# ---- R9. 첫 설치의 라우터 env: 이번에 정한 URL/모델로 LOCAL_URL/LOCAL_MODEL 이 쓰인다 -------------------------
H="$T/r9"; mkhome "$H"
inst r9 "$H" "$T/kit" "$PY" --with-router --no-skills --model=test/model-x --lmstudio-url=http://127.0.0.1:1299
[ "$(rc r9)" = 0 ] && pass "R9 exits 0" || { bad "R9 exits 0" "rc=$(rc r9)"; show r9; }
grep -q '^LOCAL_URL=http://127.0.0.1:1299$' "$H/.config/llm-router/env" && pass "R9 LOCAL_URL is this run's URL" \
    || bad "R9 LOCAL_URL is this run's URL" "$(grep '^LOCAL_URL' "$H/.config/llm-router/env")"
grep -q '^LOCAL_MODEL=test/model-x$' "$H/.config/llm-router/env" && pass "R9 LOCAL_MODEL is this run's model" \
    || bad "R9 LOCAL_MODEL is this run's model" "$(grep '^LOCAL_MODEL' "$H/.config/llm-router/env")"
[ "$(stat -f %Lp "$H/.config/llm-router/env")" = 600 ] && pass "R9 router env mode 600" \
    || bad "R9 router env mode 600" "$(stat -f %Lp "$H/.config/llm-router/env")"
[ "$(grep -c '^SPARK_API_KEY=$' "$H/.config/llm-router/env")" = 1 ] && pass "R9 SPARK_API_KEY still there, empty" \
    || bad "R9 SPARK_API_KEY still there, empty" "missing"
H="$T/r9b"; mkhome "$H"
inst r9b "$H" "$T/kit" "$PY" --with-router --no-skills --model=test/model-x --lmstudio-url=http://127.0.0.1:1299 --dry-run
[ "$(rc r9b)" = 0 ] && grep -qF 'LOCAL_URL=http://127.0.0.1:1299' "$T/r9b.out" && grep -qF 'LOCAL_MODEL=test/model-x' "$T/r9b.out" \
    && pass "R9b dry-run says what it would set" || { bad "R9b dry-run says what it would set" "rc=$(rc r9b)"; show r9b; }
[ ! -e "$H/.config" ] && pass "R9b dry-run writes nothing" || bad "R9b dry-run writes nothing" "$(find "$H/.config" | head -3)"

# ---- R10. 이미 있는 라우터 env 는 절대 손대지 않는다(포트만 conf 로 읽어 간다) --------------------------------
H="$T/r10"; mkhome "$H"
mkdir -p "$H/.config/llm-router"
printf 'LLM_ROUTER_PORT=1241\nLOCAL_URL=http://127.0.0.1:1999\nLOCAL_MODEL=keepme\nSPARK_API_KEY=canary-KEEP\n' > "$H/.config/llm-router/env"
chmod 600 "$H/.config/llm-router/env"
cp "$H/.config/llm-router/env" "$T/r10.orig"
inst r10 "$H" "$T/kit" "$PY" --with-router --no-skills
[ "$(rc r10)" = 0 ] && pass "R10 exits 0" || { bad "R10 exits 0" "rc=$(rc r10)"; show r10; }
cmp -s "$T/r10.orig" "$H/.config/llm-router/env" && pass "R10 existing router env untouched" \
    || bad "R10 existing router env untouched" "changed"
grep -q "^CLAUDE_LMS_ROUTER='http://127.0.0.1:1241'\$" "$H/.config/claude-lms/env" && pass "R10 conf uses the env's port 1241" \
    || bad "R10 conf uses the env's port 1241" "$(grep ROUTER "$H/.config/claude-lms/env")"

# ---- R11/R12. 호출 순서: 인스톨러는 --load 없이 먼저, 첫 설치 env 를 고친 뒤에야 --load ------------------------
# stub 인스톨러(launchctl 은 절대 부르지 않는다): argv 를 $HOME/.stub-router.log 에 남기고, router env 가
# 없으면 kit 의 env.example 에서 mode 600 으로 만들며(실제 인스톨러 흉내), 매 호출 시점의
# LOCAL_MODEL=test/model-x 줄 수를 같은 로그에 남긴다 — 두 번째 호출의 값이 첫 설치 rewrite 의 증거다.
mkkit "$T/kit11"
cat > "$T/kit11/llm-router/install-llm-router.sh" <<'STUB'
#!/bin/bash
set -u
LOG="$HOME/.stub-router.log"
ENVF="$HOME/.config/llm-router/env"
printf 'call:%s\n' "$*" >>"$LOG"
if [ ! -f "$ENVF" ]; then
    mkdir -p "$(dirname "$ENVF")"
    d="$(cd "$(dirname "$0")" && pwd)"
    ( umask 077; cp "$d/env.example" "$ENVF" )
fi
printf 'model-x-count:%s\n' "$(grep -c '^LOCAL_MODEL=test/model-x$' "$ENVF")" >>"$LOG"
STUB
chmod 755 "$T/kit11/llm-router/install-llm-router.sh"
H="$T/r11"; mkhome "$H"
inst r11 "$H" "$T/kit11" "$PY" --with-router --no-skills --model=test/model-x --lmstudio-url=http://127.0.0.1:1299
[ "$(rc r11)" = 0 ] && pass "R11 exits 0" || { bad "R11 exits 0" "rc=$(rc r11)"; show r11; }
n="$(grep -c '^call:' "$H/.stub-router.log" 2>/dev/null)"
[ "$n" = 1 ] && pass "R11 plain --with-router: exactly one installer call" \
    || bad "R11 plain --with-router: exactly one installer call" "got ${n:-0} call(s)"
c1="$(sed -n 's/^call://p' "$H/.stub-router.log" 2>/dev/null | sed -n 1p)"
case "$c1" in *--load*) bad "R11 the call has no --load" "$c1" ;; *) pass "R11 the call has no --load" ;; esac
H="$T/r12"; mkhome "$H"
inst r12 "$H" "$T/kit11" "$PY" --with-router --router-load --no-skills --model=test/model-x --lmstudio-url=http://127.0.0.1:1299
[ "$(rc r12)" = 0 ] && pass "R12 exits 0" || { bad "R12 exits 0" "rc=$(rc r12)"; show r12; }
n="$(grep -c '^call:' "$H/.stub-router.log" 2>/dev/null)"
[ "$n" = 2 ] && pass "R12 --router-load: two installer calls" \
    || bad "R12 --router-load: two installer calls" "got ${n:-0} call(s)"
c1="$(sed -n 's/^call://p' "$H/.stub-router.log" 2>/dev/null | sed -n 1p)"
c2="$(sed -n 's/^call://p' "$H/.stub-router.log" 2>/dev/null | sed -n 2p)"
case "$c1" in *--load*) bad "R12 first call has no --load" "$c1" ;; *) pass "R12 first call has no --load" ;; esac
case "$c2" in *--load*) pass "R12 second call has --load" ;; *) bad "R12 second call has --load" "$c2" ;; esac
m1="$(sed -n 's/^model-x-count://p' "$H/.stub-router.log" 2>/dev/null | sed -n 1p)"
m2="$(sed -n 's/^model-x-count://p' "$H/.stub-router.log" 2>/dev/null | sed -n 2p)"
[ "${m1:-x}" = 0 ] && pass "R12 first call still sees env.example's LOCAL_MODEL" \
    || bad "R12 first call still sees env.example's LOCAL_MODEL" "count=${m1:-none}"
[ "${m2:-x}" = 1 ] && pass "R12 env rewritten to this run's model before --load runs" \
    || bad "R12 env rewritten to this run's model before --load runs" "count=${m2:-none}"
[ "$(stat -f %Lp "$H/.config/llm-router/env" 2>/dev/null)" = 600 ] && pass "R12 stub-created env is 600" \
    || bad "R12 stub-created env is 600" "$(stat -f %Lp "$H/.config/llm-router/env" 2>/dev/null)"

echo
if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi
