#!/bin/bash
# guardian/pack-claude-code.sh 인수 시험 (빌드 Mac 전용: 진짜 ~/.local/bin/claude 를 묶는다).
# 사용: guardian/tests/accept_pack_claude_code.sh [CLAUDE_BIN]   (모두 통과하면 "ACCEPT PASS", 종료 0)
# 묶음 하나를 만들고 풀어서 해시·권한·제외 목록·버전을 보고, 거부해야 할 경우(서명이 다른 바이너리, 없는 파일,
# 이미 있는 출력, 이상한 이름, 모르는 옵션)를 본다. build-merged-bundle.sh §4b 와 핀·제외 목록이 같은지도 본다.
set -u
G="$(cd "$(dirname "$0")/.." && pwd)"
P="$G/pack-claude-code.sh"
B="$G/build-merged-bundle.sh"
CB="${1:-$HOME/.local/bin/claude}"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-pack.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else bad "$n" "$*"; fi; }

[ -x "$P" ] || { echo "FAIL pack script missing or not executable: $P"; exit 1; }
[ -x "$CB" ] || { echo "FAIL claude binary missing: $CB"; exit 1; }
VER="$("$(readlink -f "$CB")" --version | awk '{print $1}')"
PIN="$(sed -n 's/^HWPX_WHL_SHA256="\([0-9a-f]\{64\}\)"$/\1/p' "$B")"

# ---- 1. 도움말·옵션 --------------------------------------------------------------------------
"$P" --help >"$T/help.out" 2>&1; rc=$?
[ $rc -eq 0 ] && grep -q -- '--out=' "$T/help.out" && grep -q -- '--claude-code=' "$T/help.out" \
    && grep -q -- '--no-tar' "$T/help.out" && pass "help" || bad "help" "rc=$rc or options missing"
"$P" --bogus --out="$T/o0" >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && pass "unknown option exits 2" || bad "unknown option exits 2" "rc=$rc"
[ ! -e "$T/o0" ] || [ -z "$(ls -A "$T/o0")" ] && pass "unknown option writes nothing" || bad "unknown option writes nothing" "$(ls "$T/o0")"

# ---- 2. 정상 묶음 -----------------------------------------------------------------------------
N="claude-code-kit-test-macos-arm64"
O="$T/out"
"$P" --claude-code="$CB" --out="$O" --name="$N" >"$T/ok.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "pack exits 0" || { bad "pack exits 0" "rc=$rc"; sed 's/^/    /' "$T/ok.out" | tail -20; }
A="$O/$N.tar.gz"
check "archive exists" test -s "$A"
check "sha256 file exists" test -s "$A.sha256"
check "no .partial left" test -z "$(find "$O" -name '*.partial' -print)"
check "staging folder kept for inspection" test -d "$O/$N"
( cd "$O" && shasum -a 256 -c "$N.tar.gz.sha256" ) >/dev/null 2>&1 && pass "outer sha256 -c" || bad "outer sha256 -c" "mismatch"
grep -q "  $N.tar.gz\$" "$A.sha256" && pass "sha256 file names bare archive" || bad "sha256 file names bare archive" "$(cat "$A.sha256")"

/usr/bin/tar -tzf "$A" >"$T/list.txt" 2>/dev/null || bad "list archive" "/usr/bin/tar -tzf failed"
grep -q "^$N/" "$T/list.txt" && ! grep -Evq "^$N/" "$T/list.txt" && pass "single top folder" || bad "single top folder" "$(head -3 "$T/list.txt")"
for pat in '/\._' '\.DS_Store' '__pycache__' '\.pyc$' '/tests/' '\.bak' '\.env$' 'key.*\.json$' 'webui\.db' \
    "llm-router/(tests|spark)/"; do
    grep -Eq "$pat" "$T/list.txt" && bad "excluded: $pat" "$(grep -E "$pat" "$T/list.txt" | head -2)" || pass "excluded: $pat"
done
want="$(cd "$O" && find "$N" | wc -l | tr -d ' ')"
got="$(grep -c . "$T/list.txt")"
[ "$want" = "$got" ] && pass "archive matches folder ($got entries)" || bad "archive matches folder" "folder $want, archive $got"

X="$T/x"; mkdir -p "$X"; /usr/bin/tar -xzf "$A" -C "$X"; K="$X/$N"
( cd "$K" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1 && pass "inner SHA256SUMS -c" || bad "inner SHA256SUMS -c" "mismatch"
nsum="$(grep -c . "$K/SHA256SUMS")"; nfile="$(cd "$K" && find . -type f ! -name SHA256SUMS | wc -l | tr -d ' ')"
[ "$nsum" = "$nfile" ] && pass "SHA256SUMS covers every file ($nsum)" || bad "SHA256SUMS covers every file" "sums $nsum, files $nfile"
LC_ALL=C sort -c -k2 "$K/SHA256SUMS" 2>/dev/null && pass "SHA256SUMS sorted by path" || bad "SHA256SUMS sorted by path" "unsorted"
for f in VERSION claude install-claude-code.sh claude-lms claude-vscode claude-kit/system-prompt.md \
    claude-kit/skills/hwpx/SKILL.md \
    claude-kit/skills/hwpx/scripts/hwpx claude-kit/skills/hwpx/scripts/skill-guard \
    claude-kit/skills/hwpx/scripts/skill_guard.py claude-kit/wheels/python_hwpx-6.11.0-py3-none-any.whl; do
    check "has $f" test -f "$K/$f"
done
# 오피스 skill(docx/xlsx/pptx): 휠 없이 SKILL.md + 래퍼 + 도구만, 래퍼는 실행 가능해야 한다.
OFFICE="docx xlsx pptx"
for s in $OFFICE; do
    for f in SKILL.md "scripts/$s" "scripts/${s}_tool.py"; do check "has $s/$f" test -f "$K/claude-kit/skills/$s/$f"; done
done
for f in claude install-claude-code.sh claude-lms claude-vscode claude-kit/skills/hwpx/scripts/hwpx \
    claude-kit/skills/hwpx/scripts/skill-guard \
    claude-kit/skills/docx/scripts/docx claude-kit/skills/xlsx/scripts/xlsx claude-kit/skills/pptx/scripts/pptx \
    llm-router/spark-model llm-router/install-llm-router.sh; do
    [ "$(stat -f %Lp "$K/$f" 2>/dev/null)" = 755 ] && pass "755 $f" || bad "755 $f" "$(stat -f %Lp "$K/$f" 2>/dev/null)"
done
# llm-router: 정확히 다섯 파일이 kit 에 들어가고(스크립트 둘은 755), tar 목록에도 그 다섯만 보인다.
LR="router.py spark-model install-llm-router.sh env.example README.md"
for f in $LR; do check "has llm-router/$f" test -f "$K/llm-router/$f"; done
n_lr="$(grep "^$N/llm-router/" "$T/list.txt" | grep -vc '/$' | tr -d ' ')"
n_lrw="$(printf '%s\n' $LR | wc -l | tr -d ' ')"
[ "$n_lr" = "$n_lrw" ] && pass "archive lists exactly the $n_lrw llm-router files" \
    || bad "archive lists exactly the llm-router files" "$(grep "^$N/llm-router/" "$T/list.txt")"
for f in $LR; do cmp -s "$K/llm-router/$f" "$G/llm-router/$f" && pass "same llm-router $f" || bad "same llm-router $f" "differs"; done
[ "$(cat "$K/VERSION" 2>/dev/null)" = "$VER" ] && pass "VERSION = $VER" || bad "VERSION" "$(cat "$K/VERSION" 2>/dev/null) != $VER"
cmp -s "$K/claude" "$(readlink -f "$CB")" && pass "claude binary identical" || bad "claude binary identical" "differs"
for f in install-claude-code.sh claude-lms claude-vscode claude-kit/system-prompt.md; do
    cmp -s "$K/$f" "$G/$f" && pass "same $f" || bad "same $f" "differs"
done
for f in scripts/hwpx scripts/skill-guard scripts/skill_guard.py scripts/hwpx_tool.py SKILL.md; do
    cmp -s "$K/claude-kit/skills/hwpx/$f" "$G/claude-kit/skills/hwpx/$f" && pass "same skill $f" || bad "same skill $f" "differs"
done
for s in $OFFICE; do
    for f in SKILL.md "scripts/$s" "scripts/${s}_tool.py"; do
        cmp -s "$K/claude-kit/skills/$s/$f" "$G/claude-kit/skills/$s/$f" && pass "same skill $s/$f" || bad "same skill $s/$f" "differs"
    done
done
[ -n "$PIN" ] && [ "$(shasum -a 256 "$K/claude-kit/wheels/python_hwpx-6.11.0-py3-none-any.whl" | awk '{print $1}')" = "$PIN" ] \
    && pass "wheel matches pin" || bad "wheel matches pin" "pin '$PIN'"
grep -q "$N.tar.gz" "$T/ok.out" && grep -q 'shasum -a 256 -c' "$T/ok.out" && pass "prints target commands" || bad "prints target commands" "missing"

# ---- 3. 거부해야 하는 경우 ---------------------------------------------------------------------
before="$(shasum -a 256 "$A" "$A.sha256")"
"$P" --claude-code="$CB" --out="$O" --name="$N" >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && pass "refuses existing output" || bad "refuses existing output" "rc=0"
[ "$(shasum -a 256 "$A" "$A.sha256")" = "$before" ] && pass "existing output untouched" || bad "existing output untouched" "changed"
# 깨진 심볼릭 링크는 [ -e ] 로 안 보인다: 출력 자리에 있으면 거부하고 링크 너머에 아무것도 만들지 않아야 한다.
mkdir -p "$T/o-dl"; ln -s "$T/outside-target" "$T/o-dl/kdl.tar.gz.sha256"
"$P" --claude-code="$CB" --out="$T/o-dl" --name=kdl >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -e "$T/outside-target" ] && [ ! -e "$T/o-dl/kdl" ] && [ ! -e "$T/o-dl/kdl.tar.gz" ] \
    && pass "refuses dangling symlink output" || bad "refuses dangling symlink output" "rc=$rc"

for case in "apple-signed:/bin/ls" "missing:$T/nope/claude"; do
    nm="${case%%:*}"; bin="${case#*:}"; o="$T/o-$nm"
    "$P" --claude-code="$bin" --out="$o" --name="k-$nm" >/dev/null 2>&1; rc=$?
    [ $rc -ne 0 ] && pass "refuses $nm binary" || bad "refuses $nm binary" "rc=0"
    [ -z "$(find "$o" -mindepth 1 -print 2>/dev/null)" ] && pass "$nm leaves nothing" || bad "$nm leaves nothing" "$(find "$o" -mindepth 1 | head -3)"
done

for nm in "../evil" "a/b" "" ".hidden" "sp ace" $'ok\n/../../evil'; do
    "$P" --claude-code="$CB" --out="$T/o-name" --name="$nm" >/dev/null 2>&1; rc=$?
    [ $rc -ne 0 ] && pass "refuses name '$nm'" || bad "refuses name '$nm'" "rc=0"
done
[ ! -e "$T/evil" ] && [ -z "$(find "$T/o-name" -mindepth 1 -print 2>/dev/null)" ] && pass "bad names write nothing" || bad "bad names write nothing" "files left"

# kit 원본에 claude-vscode 나 claude-kit/system-prompt.md 가 없으면: 폴더를 만들기 전에 거부한다.
for miss in claude-vscode:km-vscode claude-kit/system-prompt.md:km-prompt; do
    file="${miss%%:*}"; nm="k-${miss#*:}"
    FG="$T/g-$nm"; mkdir -p "$FG"
    cp "$P" "$G/install-claude-code.sh" "$G/claude-lms" "$G/claude-vscode" "$FG/"
    rsync -a --exclude tests "$G/claude-kit" "$FG/"
    rm "$FG/$file"
    "$FG/pack-claude-code.sh" --claude-code="$CB" --out="$T/o-$nm" --name="$nm" --no-tar >"$T/$nm.out" 2>&1; rc=$?
    [ $rc -ne 0 ] && pass "refuses kit without $file" || bad "refuses kit without $file" "rc=0"
    grep -qF "$file is missing" "$T/$nm.out" && pass "names the missing $file" || bad "names the missing $file" "$(tail -1 "$T/$nm.out")"
    [ -z "$(find "$T/o-$nm" -mindepth 1 -print 2>/dev/null)" ] && pass "missing $file leaves nothing" \
        || bad "missing $file leaves nothing" "$(find "$T/o-$nm" -mindepth 1 | head -2)"
done

# ---- 4. --no-tar ------------------------------------------------------------------------------
"$P" --claude-code="$CB" --out="$T/nt" --name="k-notar" --no-tar >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && [ -f "$T/nt/k-notar/SHA256SUMS" ] && [ -z "$(find "$T/nt" -name '*.tar.gz*' -print)" ] \
    && pass "--no-tar keeps folder only" || bad "--no-tar keeps folder only" "rc=$rc"

# ---- 5. 기본 이름 ------------------------------------------------------------------------------
"$P" --claude-code="$CB" --out="$T/dn" --no-tar >/dev/null 2>&1; rc=$?
dn="$(ls "$T/dn" 2>/dev/null)"
echo "$dn" | grep -Eqx "claude-code-kit-${VER//./\\.}-[0-9]{8}T[0-9]{4}Z-macos-arm64" \
    && pass "default name ($dn)" || bad "default name" "rc=$rc '$dn'"

# ---- 6. build-merged-bundle.sh §4b 와 어긋나지 않는가 ---------------------------------------------
for key in 'HWPX_WHL_SHA256=' 'EXCL=(' 'OFFICE_SKILLS=' 'LLM_ROUTER_FILES='; do
    a="$(grep -m1 "^$key" "$B")"; b="$(grep -m1 "^$key" "$P")"
    [ -n "$a" ] && [ "$a" = "$b" ] && pass "same as build: $key" || bad "same as build: $key" "build '$a' / pack '$b'"
done
grep -q 'scripts/skill-guard' "$B" && pass "build §4b chmods skill-guard" || bad "build §4b chmods skill-guard" "missing"
# 번들 빌드의 §4b 도 llm-router 다섯 파일을 claude-code/ 아래에 넣는다(mkdir·cp·chmod 최소 세 곳에서 언급).
n_lr="$(grep -c 'claude-code/llm-router' "$B")"
[ "${n_lr:-0}" -ge 3 ] && pass "build §4b stages llm-router ($n_lr mentions)" \
    || bad "build §4b stages llm-router" "claude-code/llm-router mentioned ${n_lr:-0} times in $B"
# 번들 빌드도 오피스 skill 래퍼를 chmod 하고(§4b) 시험 venv 에서 from-md + read 를 돌린다(§5): 두 곳 이상에서 쓰여야 한다.
n="$(grep -c '${OFFICE_SKILLS}' "$B")"
[ "${n:-0}" -ge 2 ] && pass "build uses OFFICE_SKILLS for chmod and smoke ($n)" || bad "build uses OFFICE_SKILLS for chmod and smoke" "found ${n:-0}"

# ---- 7. pipefail + grep -q 경쟁 ----------------------------------------------------------------
# set -o pipefail 에서 `생산자 | grep -q` 는 grep 이 먼저 끝나면 생산자가 SIGPIPE 로 죽어 파이프 전체가 실패한다.
# codesign -dv 는 TeamIdentifier 뒤에 3줄을 더 써서 서명이 맞아도 가끔 거부되고(300회 중 202회 재현),
# find … -print | grep -q . 는 일치가 많으면 비밀 파일이 있어도 "없음"이 된다(50회 중 50회). 출력을 변수로 받아 검사해야 한다.
for f in "$P" "$B"; do
    if grep -nE 'codesign[^|]*\|[[:space:]]*grep|-print[[:space:]]*\|[[:space:]]*grep[[:space:]]+-q' "$f" >"$T/pipe.txt"; then
        bad "no producer|grep -q race in $(basename "$f")" "$(head -2 "$T/pipe.txt")"
    else
        pass "no producer|grep -q race in $(basename "$f")"
    fi
done
# 번들 빌드의 비밀 파일 검사는 §4b 가 claude-kit 을 복사한 뒤에 돌아야 그 skill 폴더까지 본다.
scan="$(grep -n 'secret or data file ended up in the bundle' "$B" | head -1 | cut -d: -f1)"
kit="$(grep -n 'rsync -a "${EXCL\[@\]}" "${HERE}/claude-kit/skills"' "$B" | head -1 | cut -d: -f1)"
[ -n "$scan" ] && [ -n "$kit" ] && [ "$scan" -gt "$kit" ] && pass "build secret scan runs after §4b copies claude-kit" \
    || bad "build secret scan runs after §4b copies claude-kit" "scan line ${scan:-?}, claude-kit rsync line ${kit:-?}"
# 그 검사 블록(주석 '# A secret must never ride along' 부터 마지막 die 줄까지)을 잘라 가짜 번들에 돌린다.
# 남이 만든 파일(pip·LM Studio 안의 certifi cacert.pem)은 통과, 우리 claude-code/ 의 .pem·번들 맨 위 .env 는 거부.
s0="$(grep -n '^# A secret must never ride along' "$B" | head -1 | cut -d: -f1)"
s1="$(grep -n 'secret or data file ended up in the bundle' "$B" | tail -1 | cut -d: -f1)"
if [ -n "$s0" ] && [ -n "$s1" ] && [ "$s1" -gt "$s0" ]; then
    sed -n "${s0},${s1}p" "$B" >"$T/scan.sh"
    for case in thirdparty ourpem rootenv; do
        FB="$T/fb-$case"; mkdir -p "$FB/tools/python/lib/python3.12/site-packages/pip/_vendor/certifi" \
            "$FB/lmstudio-home/x/site-packages/certifi" "$FB/claude-code/claude-kit/skills/hwpx"
        touch "$FB/tools/python/lib/python3.12/site-packages/pip/_vendor/certifi/cacert.pem" \
            "$FB/lmstudio-home/x/site-packages/certifi/cacert.pem"
        case "$case" in ourpem) touch "$FB/claude-code/claude-kit/skills/hwpx/server.pem" ;; rootenv) touch "$FB/.env" ;; esac
        bash -c 'set -euo pipefail; die(){ echo "DIE: $*"; exit 1; }; BUNDLE="$1"; source "$2"' _ "$FB" "$T/scan.sh" >"$T/scan-$case.out" 2>&1; rc=$?
        if [ "$case" = thirdparty ]; then
            [ "$rc" -eq 0 ] && pass "build scan accepts third-party cacert.pem" || bad "build scan accepts third-party cacert.pem" "rc=$rc $(head -1 "$T/scan-$case.out")"
        else
            [ "$rc" -ne 0 ] && grep -q 'DIE: a secret or data file ended up in the bundle' "$T/scan-$case.out" \
                && pass "build scan refuses $case" || bad "build scan refuses $case" "rc=$rc $(head -1 "$T/scan-$case.out")"
        fi
    done
else
    bad "build scan block found" "marker line ${s0:-?}, die line ${s1:-?}"
fi
# --no-tar 는 만들지 않은 .tar.gz 를 복사하라고 안내하지 않는다.
"$P" --claude-code="$CB" --out="$T/nt2" --name=k-nt2 --no-tar >"$T/nt2.out" 2>&1
! grep -q 'k-nt2.tar.gz' "$T/nt2.out" && pass "--no-tar does not mention an archive" || bad "--no-tar does not mention an archive" "$(grep 'tar.gz' "$T/nt2.out" | head -1)"
# 비밀 파일 거부를 실제로: 가짜 guardian 사본의 skill 폴더에 .env 하나 / key 파일 여러 개를 심는다.
# one/many: 원래 목록, envlocal/pem: .env.* 와 개인키, symlink: rsync -a 가 보존하는 링크(밖을 가리키면 대상 Mac 에서 깨지고
# chmod 가 링크 너머 파일을 바꾼다) — 모두 거부해야 한다. 가짜 사본은 라우터 다섯 파일도 갖춘 완전한 kit 이어야
# (없으면 preflight 에서 죽어 비밀 검사 메시지가 나오지 않는다): control 은 아무것도 심지 않은 채 성공해 fixture 가
# 완전함을 증명하고, 심은 경우는 rc 만이 아니라 거부 메시지 그 자체를 확인한다.
for plant in control one many envlocal pem symlink; do
    FG="$T/g-$plant"; mkdir -p "$FG"
    cp "$P" "$G/install-claude-code.sh" "$G/claude-lms" "$G/claude-vscode" "$FG/"
    rsync -a --exclude tests "$G/claude-kit" "$FG/"
    mkdir -p "$FG/llm-router"
    for f in router.py spark-model install-llm-router.sh env.example README.md; do cp "$G/llm-router/$f" "$FG/llm-router/"; done
    chmod 755 "$FG/llm-router/spark-model" "$FG/llm-router/install-llm-router.sh"
    H="$FG/claude-kit/skills/hwpx"
    case "$plant" in
        control) ;;
        one) : > "$H/.env" ;;
        many) for i in $(seq 1 2000); do : > "$H/k${i}key.json"; done ;;
        envlocal) : > "$H/.env.local" ;;
        pem) : > "$H/server.pem" ;;
        symlink) ln -s /etc/hosts "$H/hosts-link" ;;
    esac
    "$FG/pack-claude-code.sh" --claude-code="$CB" --out="$T/o-sec-$plant" --name=k --no-tar >"$T/sec-$plant.out" 2>&1; rc=$?
    if [ "$plant" = control ]; then
        [ $rc -eq 0 ] && [ -f "$T/o-sec-control/k/SHA256SUMS" ] && pass "planted-secret fixture complete (control packs)" \
            || { bad "planted-secret fixture complete (control packs)" "rc=$rc $(tail -2 "$T/sec-control.out")"; }
    else
        want="a secret or data file ended up in the kit"
        [ "$plant" = symlink ] && want="a symlink ended up in the kit"
        [ $rc -ne 0 ] && grep -qF "$want" "$T/sec-$plant.out" && pass "refuses planted secret ($plant, names it)" \
            || { bad "refuses planted secret ($plant, names it)" "rc=$rc, message: $(tail -1 "$T/sec-$plant.out")"; }
        [ -z "$(find "$T/o-sec-$plant" -mindepth 1 -print 2>/dev/null)" ] && pass "planted secret ($plant) leaves nothing" \
            || bad "planted secret ($plant) leaves nothing" "$(find "$T/o-sec-$plant" -mindepth 1 -maxdepth 1)"
    fi
done

echo
if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi
