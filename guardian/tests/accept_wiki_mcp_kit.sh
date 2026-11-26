#!/bin/bash
# guardian/pack-wiki-mcp-kit.sh + guardian/wiki-mcp-kit/install-wiki-mcp.sh + run-wiki-mcp.sh
# 인수 시험 (빌드 Mac 전용, 사람이 실행한다).
# 사용: guardian/tests/accept_wiki_mcp_kit.sh [--python=PY] [--wire-venv=DIR]
#   --python=PY      pack 스크립트에 그대로 넘긴다 (기본: pack 이 후보에서 알아서 고른다;
#                    이 Mac 처럼 기본 python3 에 setuptools 가 없으면 --python=python3.11)
#   --wire-venv=DIR  선택 와이어 시험: wiki-mcp(http 지원)+mcpo 가 든 venv 로 실제 루프
#                    (mcpo 먼저 기동→서버 대기, 키 200/401, mcpo 422/403, serve 거부,
#                    서버 재시작 후 회복)를 18765/18766 포트에서 돌려 본다
# 진짜 서비스·네트워크·진짜 HOME 는 건드리지 않는다: 설치 시험은 --dry-run + 가짜 HOME +
# 스텁 launchctl/lsof/claude 로 완전 격리되고, 휠 빌드만 진짜로 돈다. 묶음 하나를 --no-tar
# 로 만들어 구성·SHA256SUMS·MANIFEST 를 보고, tar 꾸러미도 만들어 본다. 모두 통과하면
# "ACCEPT PASS", 종료 0.
set -u
SECONDS=0
G="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$G/.." && pwd)"
P="$G/pack-wiki-mcp-kit.sh"
I="$G/wiki-mcp-kit/install-wiki-mcp.sh"
RW="$ROOT/run-wiki-mcp.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-wikikit.XXXXXX")"
T="$(cd "$T" && pwd)"
WIRE_VENV=""
WIRE_PIDS=""
cleanup() {
    if [ -n "${WIRE_PIDS}" ]; then kill ${WIRE_PIDS} 2>/dev/null || true; fi
    rm -rf "${T:?}"
}
trap cleanup EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else bad "$n" "$*"; fi; }
has()  { local f="$1" s="$2"; grep -Fq -e "$s" "$f"; }
hasnt() { local f="$1" s="$2"; ! grep -Fq -e "$s" "$f"; }

PYOPT=()
for arg in "$@"; do
    case "${arg}" in
        --python=*) PYOPT=(--python="${arg#--python=}") ;;
        --wire-venv=*) WIRE_VENV="${arg#--wire-venv=}" ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

[ -x "$P" ] || { echo "FAIL pack script missing or not executable: $P"; exit 1; }
[ -x "$I" ] || { echo "FAIL installer missing or not executable: $I"; exit 1; }
[ -f "$RW" ] || { echo "FAIL runner missing: $RW"; exit 1; }

# ---- 1. 문법 -----------------------------------------------------------------------------------
check "bash -n run-wiki-mcp.sh" /bin/bash -n "$RW"
check "bash -n installer" /bin/bash -n "$I"
check "bash -n pack script" /bin/bash -n "$P"

# ---- 2. run-wiki-mcp.sh: http 서브커맨드 --------------------------------------------------------
# 진짜 .env 를 절대 읽지 않게 임시 폴더로 복사해 빈 .env 를 둔다. 가짜 venv 의
# wiki-mcp/mcpo 는 실행 표식을 남긴다 — 표식이 생기면 exec 해 버린 것이다.
mkdir -p "$T/rw/fakevenv/bin"
cp "$RW" "$T/rw/run-wiki-mcp.sh"
cp "$ROOT/load-env.sh" "$T/rw/load-env.sh"
: > "$T/rw/.env"
printf '#!/bin/sh\ntouch "$EXECMARK"\n' > "$T/rw/fakevenv/bin/wiki-mcp"
printf '#!/bin/sh\ntouch "$EXECMARK"\n' > "$T/rw/fakevenv/bin/mcpo"
chmod 755 "$T/rw/fakevenv/bin/wiki-mcp" "$T/rw/fakevenv/bin/mcpo"
EXECMARK="$T/execed"; export EXECMARK

out="$T/rw-usage.out"
WIKI_VENV="$T/rw/fakevenv" /bin/bash "$T/rw/run-wiki-mcp.sh" bogus >"$out" 2>&1; rc=$?
[ $rc -eq 2 ] && has "$out" "{serve|http|mcpo|watch}" && pass "usage lists http" \
    || bad "usage lists http" "rc=$rc"

rm -f "$EXECMARK"
out="$T/rw-http.out"
WIKI_MCP_API_KEY="" WIKI_VENV="$T/rw/fakevenv" /bin/bash "$T/rw/run-wiki-mcp.sh" http >"$out" 2>&1; rc=$?
[ $rc -ne 0 ] && has "$out" "WIKI_MCP_API_KEY" && [ ! -e "$EXECMARK" ] && pass "http without key refuses (no exec)" \
    || bad "http without key refuses (no exec)" "rc=$rc execed=$([ -e "$EXECMARK" ] && echo yes || echo no)"

rm -f "$EXECMARK"
out="$T/rw-mcpo.out"
WIKI_MCPO_UPSTREAM=http WIKI_MCPO_KEY=x WIKI_MCP_API_KEY="" WIKI_VENV="$T/rw/fakevenv" \
    /bin/bash "$T/rw/run-wiki-mcp.sh" mcpo >"$out" 2>&1; rc=$?
[ $rc -ne 0 ] && has "$out" "WIKI_MCP_API_KEY" && [ ! -e "$EXECMARK" ] && pass "mcpo http-relay without api key refuses (no exec)" \
    || bad "mcpo http-relay without api key refuses (no exec)" "rc=$rc execed=$([ -e "$EXECMARK" ] && echo yes || echo no)"

# ---- 3. pack -----------------------------------------------------------------------------------
VER="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$ROOT/wiki-mcp/pyproject.toml" | head -1)"
[ -n "$VER" ] || { echo "FAIL cannot read the wiki-mcp version from pyproject.toml"; exit 1; }
WHEEL="wheels/wiki_mcp-${VER}-py3-none-any.whl"

"$P" --help >"$T/phelp.out" 2>&1; rc=$?
[ $rc -eq 0 ] && has "$T/phelp.out" "--python=" && has "$T/phelp.out" "--wheel=" \
    && has "$T/phelp.out" "--out=" \
    && has "$T/phelp.out" "--name=" && has "$T/phelp.out" "--no-tar" && pass "pack help" \
    || bad "pack help" "rc=$rc or options missing"
"$P" --bogus --out="$T/o-unk" >"$T/pbogus.out" 2>&1; rc=$?
[ $rc -eq 2 ] && pass "pack unknown option exits 2" || bad "pack unknown option exits 2" "rc=$rc"
[ ! -e "$T/o-unk" ] && pass "pack unknown option writes nothing" || bad "pack unknown option writes nothing" "$T/o-unk exists"

for nm in "a/b" "../evil"; do
    "$P" ${PYOPT[@]+"${PYOPT[@]}"} --no-tar --out="$T/o-name" --name="$nm" >/dev/null 2>&1; rc=$?
    [ $rc -ne 0 ] && pass "pack refuses name '$nm'" || bad "pack refuses name '$nm'" "rc=0"
done
[ -z "$(find "$T/o-name" -mindepth 1 -print 2>/dev/null)" ] && pass "bad names write nothing" \
    || bad "bad names write nothing" "files left under $T/o-name"

O="$T/out1"; N="k1"
"$P" ${PYOPT[@]+"${PYOPT[@]}"} --no-tar --out="$O" --name="$N" >"$T/pack1.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "pack --no-tar exits 0" \
    || { bad "pack --no-tar exits 0" "rc=$rc"; sed 's/^/    /' "$T/pack1.out" | tail -8; }
K="$O/$N"
check "stage folder exists" test -d "$K"
# 스테이지는 정확히 예상 파일 7개(.DS_Store 없음)로 구성된다.
want="$T/want.list"
cat >"$want" <<EOF
./MANIFEST.env
./README.md
./SHA256SUMS
./install-wiki-mcp.sh
./load-env.sh
./run-wiki-mcp.sh
./$WHEEL
EOF
(cd "$K" && find . -type f | LC_ALL=C sort) >"$T/got.list" 2>/dev/null
cmp -s "$want" "$T/got.list" && pass "stage holds exactly the expected files" \
    || bad "stage holds exactly the expected files" "$(diff "$want" "$T/got.list" | head -4)"
( cd "$K" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1 && pass "stage SHA256SUMS -c" || bad "stage SHA256SUMS -c" "mismatch"
[ "$(stat -f %Lp "$K/install-wiki-mcp.sh")" = 755 ] && pass "install-wiki-mcp.sh is 755" \
    || bad "install-wiki-mcp.sh is 755" "$(stat -f %Lp "$K/install-wiki-mcp.sh")"
[ "$(stat -f %Lp "$K/run-wiki-mcp.sh")" = 755 ] && pass "run-wiki-mcp.sh is 755" \
    || bad "run-wiki-mcp.sh is 755" "$(stat -f %Lp "$K/run-wiki-mcp.sh")"
check "wheel is in the stage" test -f "$K/$WHEEL"
for kv in "kit=wiki-mcp-kit" "wiki_mcp=$VER" "wheel=$WHEEL" "mcp_port=8765" "mcp_path=/mcp" \
    "label=dev.guardian.wiki-mcp"; do
    grep -qx "$kv" "$K/MANIFEST.env" && pass "MANIFEST $kv" || bad "MANIFEST $kv" "missing"
done
grep -Eqx 'built_utc=[0-9]{8}T[0-9]{4}Z' "$K/MANIFEST.env" && pass "MANIFEST built_utc stamp" \
    || bad "MANIFEST built_utc stamp" "$(grep built_utc "$K/MANIFEST.env")"
grep -Eqx 'git_commit=([0-9a-f]{7,40}|unknown)' "$K/MANIFEST.env" && pass "MANIFEST git_commit" \
    || bad "MANIFEST git_commit" "$(grep git_commit "$K/MANIFEST.env")"
# 같은 이름으로 반복 → 거부.
"$P" ${PYOPT[@]+"${PYOPT[@]}"} --no-tar --out="$O" --name="$N" >"$T/pack2.out" 2>&1; rc=$?
[ $rc -ne 0 ] && pass "repeat pack with same name refused" || bad "repeat pack with same name refused" "rc=0"

# tar 꾸러미: .tar.gz + .sha256 검증.
"$P" ${PYOPT[@]+"${PYOPT[@]}"} --out="$T/out2" --name=k2 >"$T/tar.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "pack (with tar) exits 0" \
    || { bad "pack (with tar) exits 0" "rc=$rc"; sed 's/^/    /' "$T/tar.out" | tail -8; }
check "k2.tar.gz exists" test -f "$T/out2/k2.tar.gz"
check "k2.tar.gz.sha256 exists" test -f "$T/out2/k2.tar.gz.sha256"
( cd "$T/out2" && shasum -a 256 -c k2.tar.gz.sha256 ) >/dev/null 2>&1 \
    && pass "k2.tar.gz.sha256 -c" || bad "k2.tar.gz.sha256 -c" "mismatch"

# ---- 3b. --wheel: 다시 빌드하지 않고 그 휠을 싣는다 ------------------------------------------------
# k1 이 만든 휠을 그대로 넣어 kit 을 하나 더 만든다: wheels/ 의 휠은 원본과 바이트가 같아야 한다.
# 이름이 다른 휠(내용은 같지만 이름만 바꿔 복사한 것)은 거부되고 아무것도 남기지 않아야 한다.
WHL_SRC="$K/$WHEEL"
"$P" --wheel="$WHL_SRC" --no-tar --out="$T/o-wheel" --name=kw >"$T/wheel1.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "pack --wheel exits 0" \
    || { bad "pack --wheel exits 0" "rc=$rc $(tail -1 "$T/wheel1.out")"; }
cmp -s "$T/o-wheel/kw/$WHEEL" "$WHL_SRC" && pass "--wheel ships the given wheel byte-identical" \
    || bad "--wheel ships the given wheel byte-identical" "differs"
( cd "$T/o-wheel/kw" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1 \
    && pass "--wheel kit SHA256SUMS -c" || bad "--wheel kit SHA256SUMS -c" "mismatch"
grep -qx "wiki_mcp=$VER" "$T/o-wheel/kw/MANIFEST.env" && pass "--wheel kit MANIFEST version" \
    || bad "--wheel kit MANIFEST version" "$(grep '^wiki_mcp=' "$T/o-wheel/kw/MANIFEST.env")"
cp "$WHL_SRC" "$T/wiki_mcp-0.0.0-py3-none-any.whl"
"$P" --wheel="$T/wiki_mcp-0.0.0-py3-none-any.whl" --no-tar --out="$T/o-wheel2" --name=kw2 >"$T/wheel2.out" 2>&1; rc=$?
[ $rc -ne 0 ] && pass "pack --wheel refuses a wrong-name wheel" \
    || bad "pack --wheel refuses a wrong-name wheel" "rc=0"
has "$T/wheel2.out" "$(basename "$WHEEL")" && pass "the refusal names the wheel it wants" \
    || bad "the refusal names the wheel it wants" "$(tail -1 "$T/wheel2.out")"
[ -z "$(find "$T/o-wheel2" -mindepth 1 -print 2>/dev/null)" ] && pass "wrong-name wheel leaves nothing" \
    || bad "wrong-name wheel leaves nothing" "$(find "$T/o-wheel2" -mindepth 1 | head -3)"

# ---- 4. installer --dry-run: 가짜 HOME + 스텁으로 완전 격리 ---------------------------------------
H="$T/home"
mkdir -p "$H/llm-wiki" "$T/fakevenv/bin" "$T/stubbin"
cat > "$H/llm-wiki/.env" <<EOF
WIKI_VENV=$T/fakevenv
WIKI_MCPO_PORT=8766
WIKI_MCPO_KEY=dummy-mcpo-key-value-123
EOF
chmod 600 "$H/llm-wiki/.env"
printf '#!/bin/sh\nexit 0\n' > "$T/fakevenv/bin/python"
printf '#!/bin/sh\nexit 0\n' > "$T/fakevenv/bin/mcpo"
chmod 755 "$T/fakevenv/bin/python" "$T/fakevenv/bin/mcpo"
# 스텁은 호출만 기록한다. launchctl print → exit 1 (= not loaded). 진짜 launchctl/lsof/claude 는
# 절대 돌지 않는다(PATH 가 여기서 갈린다).
for s in launchctl lsof claude; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/stub.log"\n' "$s" "$T" > "$T/stubbin/$s"
    if [ "$s" = launchctl ]; then
        printf '[ "$1" = print ] && exit 1\nexit 0\n' >> "$T/stubbin/$s"
    else
        printf 'exit 0\n' >> "$T/stubbin/$s"
    fi
    chmod 755 "$T/stubbin/$s"
done
snap() { (cd "$H" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort); }
snap > "$T/home-before.txt"

PATH="$T/stubbin:$PATH" HOME="$H" "$K/install-wiki-mcp.sh" --dry-run --no-claude > "$T/dry.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "installer --dry-run exits 0" \
    || { bad "installer --dry-run exits 0" "rc=$rc"; sed 's/^/    /' "$T/dry.out" | tail -12; }
has "$T/dry.out" "[dry-run]" && pass "dry-run prints its actions" || bad "dry-run prints its actions" "no [dry-run] lines"
hasnt "$T/dry.out" "dummy-mcpo-key-value-123" && pass "dry-run never prints the mcpo key" \
    || bad "dry-run never prints the mcpo key" "key leaked into the output"
has "$T/dry.out" "WIKI_MCP_API_KEY: generated" && pass "dry-run reports the api key as generated" \
    || bad "dry-run reports the api key as generated" "no 'WIKI_MCP_API_KEY: generated' line"
has "$T/dry.out" "WIKI_MCPO_UPSTREAM=http" && pass "dry-run flips WIKI_MCPO_UPSTREAM=http" \
    || bad "dry-run flips WIKI_MCPO_UPSTREAM=http" "no upstream flip line"
# 컷오버 순서: mcpo 내리기 → wiki-mcp 올리기 → mcpo 올리기(중계).
la="$(grep -nE 'launchctl bootout gui/[0-9]+/dev\.guardian\.wiki-mcpo$' "$T/dry.out" | head -1 | cut -d: -f1)"
lb="$(grep -nE 'launchctl bootstrap gui/[0-9]+ .*dev\.guardian\.wiki-mcp\.plist' "$T/dry.out" | head -1 | cut -d: -f1)"
lc="$(grep -nE 'launchctl bootstrap gui/[0-9]+ .*dev\.guardian\.wiki-mcpo\.plist' "$T/dry.out" | head -1 | cut -d: -f1)"
[ -n "$la" ] && [ -n "$lb" ] && [ -n "$lc" ] && [ "$la" -lt "$lb" ] && [ "$lb" -lt "$lc" ] \
    && pass "cutover order: mcpo out -> wiki-mcp up -> mcpo up" \
    || bad "cutover order: mcpo out -> wiki-mcp up -> mcpo up" "lines ${la:-?}/${lb:-?}/${lc:-?}"
snap > "$T/home-after.txt"
cmp -s "$T/home-before.txt" "$T/home-after.txt" && pass "dry-run leaves the fake HOME byte-identical" \
    || bad "dry-run leaves the fake HOME byte-identical" "$(diff "$T/home-before.txt" "$T/home-after.txt" | head -4)"

PATH="$T/stubbin:$PATH" HOME="$H" "$K/install-wiki-mcp.sh" --bogus > "$T/dry2.out" 2>&1; rc=$?
[ $rc -eq 2 ] && pass "installer unknown option exits 2" || bad "installer unknown option exits 2" "rc=$rc"

mkdir -p "$T/home2"
PATH="$T/stubbin:$PATH" HOME="$T/home2" "$K/install-wiki-mcp.sh" --dry-run --no-claude > "$T/noenv.out" 2>&1; rc=$?
[ $rc -ne 0 ] && has "$T/noenv.out" "install the wiki layer first" && pass "missing .env dies with the layer hint" \
    || bad "missing .env dies with the layer hint" "rc=$rc"

PATH="$T/stubbin:$PATH" HOME="$H" "$K/install-wiki-mcp.sh" --uninstall --dry-run --no-claude > "$T/unin.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "uninstall --dry-run exits 0" \
    || { bad "uninstall --dry-run exits 0" "rc=$rc"; sed 's/^/    /' "$T/unin.out" | tail -12; }
has "$T/unin.out" "WIKI_MCPO_UPSTREAM=stdio" && pass "uninstall flips WIKI_MCPO_UPSTREAM back to stdio" \
    || bad "uninstall flips WIKI_MCPO_UPSTREAM back to stdio" "no stdio flip line"
cmp -s "$T/home-before.txt" "$T/home-after.txt" && pass "uninstall dry-run also leaves the fake HOME alone" \
    || bad "uninstall dry-run also leaves the fake HOME alone" "tree changed"

# --uninstall --no-start (dry-run 아님): launchctl 은 하나도 치지 않고 손으로 칠 명령만.
: > "$T/stub.log"
PATH="$T/stubbin:$PATH" HOME="$H" "$K/install-wiki-mcp.sh" --uninstall --no-start --no-claude > "$T/unin3.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "uninstall --no-start exits 0" \
    || { bad "uninstall --no-start exits 0" "rc=$rc"; sed 's/^/    /' "$T/unin3.out" | tail -8; }
if ! grep -q 'bootout' "$T/stub.log"; then pass "uninstall --no-start issues no launchctl stop";
    else bad "uninstall --no-start issues no launchctl stop" "$(grep bootout "$T/stub.log" | head -2 | tr '\n' ' ')"; fi
la="$(grep -nE 'launchctl bootout gui/[0-9]+/dev\.guardian\.wiki-mcpo$' "$T/unin3.out" | head -1 | cut -d: -f1)"
lb="$(grep -nE 'launchctl bootout gui/[0-9]+/dev\.guardian\.wiki-mcp$' "$T/unin3.out" | head -1 | cut -d: -f1)"
lc="$(grep -nE 'launchctl bootstrap gui/[0-9]+ .*dev\.guardian\.wiki-mcpo\.plist' "$T/unin3.out" | head -1 | cut -d: -f1)"
[ -n "$la" ] && [ -n "$lb" ] && [ -n "$lc" ] && [ "$la" -lt "$lb" ] \
    && pass "uninstall --no-start prints the hand commands in order (mcpo out, wiki-mcp out, mcpo in)" \
    || bad "uninstall --no-start prints the hand commands in order (mcpo out, wiki-mcp out, mcpo in)" \
        "lines ${la:-?}/${lb:-?}/${lc:-?}"

# cutover 롤백: 응답 없는 18767 로 wait_http_401 실패 → HTTP 서버 down → mcpo stdio 로 재기동.
# WIKI_MCP_KIT_WAIT=2 로 대기를 줄인다. launchctl 스텁에 순서가 기록되는지 본다.
H3="$T/home3"
mkdir -p "$H3/llm-wiki" "$H3/Library/LaunchAgents"
cat > "$H3/llm-wiki/.env" <<EOF
WIKI_VENV=$T/fakevenv
WIKI_MCPO_PORT=8766
WIKI_MCPO_KEY=dummy-mcpo-key-value-123
EOF
chmod 600 "$H3/llm-wiki/.env"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<plist version="1.0"><dict><key>Label</key><string>dev.guardian.wiki-mcpo</string></dict></plist>' \
    > "$H3/Library/LaunchAgents/dev.guardian.wiki-mcpo.plist"
: > "$T/stub.log"
PATH="$T/stubbin:$PATH" HOME="$H3" WIKI_MCP_KIT_WAIT=2 \
    "$K/install-wiki-mcp.sh" --port=18767 --no-claude --no-wheel > "$T/roll.out" 2>&1; rc=$?
[ $rc -eq 1 ] && pass "failed cutover dies 1" || bad "failed cutover dies 1" "rc=$rc"
has "$T/roll.out" "stdio mode" && has "$T/roll.out" "logs/http.log" \
    && pass "rollback message names the stdio rollback and the http.log path" \
    || bad "rollback message names the stdio rollback and the http.log path" "wording missing"
if ! grep -q '^WIKI_MCPO_UPSTREAM=' "$H3/llm-wiki/.env"; then pass "rollback leaves .env un-flipped (still stdio)";
    else bad "rollback leaves .env un-flipped (still stdio)" "WIKI_MCPO_UPSTREAM was written"; fi
n1="$(grep -nE 'launchctl bootstrap gui/[0-9]+ .*dev\.guardian\.wiki-mcp\.plist' "$T/stub.log" | head -1 | cut -d: -f1)"
n2="$(awk -v s="${n1:-0}" 'NR > s && /^launchctl bootout gui\/[0-9]+\/dev\.guardian\.wiki-mcp$/ {print NR; exit}' "$T/stub.log")"
n3="$(awk -v s="${n2:-0}" 'NR > s && /launchctl bootstrap/ && /dev\.guardian\.wiki-mcpo\.plist/ {print NR; exit}' "$T/stub.log")"
[ -n "$n1" ] && [ -n "$n2" ] && [ -n "$n3" ] \
    && pass "rollback order in launchctl stub: HTTP server down -> mcpo back up (stdio)" \
    || bad "rollback order in launchctl stub: HTTP server down -> mcpo back up (stdio)" \
        "stub lines ${n1:-?}/${n2:-?}/${n3:-?}"

# ---- 5. 와이어 시험 (--wire-venv=DIR 만) ---------------------------------------------------------
if [ -n "$WIRE_VENV" ]; then
    W="$T/wire"
    if [ ! -x "$WIRE_VENV/bin/python" ] || [ ! -x "$WIRE_VENV/bin/mcpo" ] || [ ! -x "$WIRE_VENV/bin/wiki-mcp" ]; then
        bad "wire venv is usable" "$WIRE_VENV lacks bin/python, bin/mcpo or bin/wiki-mcp"
    elif [ -n "$(lsof -nP -iTCP:18765 -sTCP:LISTEN -t 2>/dev/null)" ] \
        || [ -n "$(lsof -nP -iTCP:18766 -sTCP:LISTEN -t 2>/dev/null)" ]; then
        bad "wire ports free" "18765/18766 already in use — close them and rerun"
    else
        mkdir -p "$W/wiki" "$W/wiki-data" "$W/logs"
        cp "$K/run-wiki-mcp.sh" "$W/run-wiki-mcp.sh"
        cp "$K/load-env.sh" "$W/load-env.sh"
        WK1="$(openssl rand -hex 24)"; WK2="$(openssl rand -hex 24)"
        cat > "$W/.env" <<EOF
WIKI_VENV=$WIRE_VENV
WIKI_PATH=$W/wiki
WIKI_DATA_DIR=$W/wiki-data
EMBEDDING_DISABLED=1
WIKI_MCP_HOST=127.0.0.1
WIKI_MCP_PORT=18765
WIKI_MCP_API_KEY=$WK1
WIKI_MCPO_HOST=127.0.0.1
WIKI_MCPO_PORT=18766
WIKI_MCPO_KEY=$WK2
WIKI_MCPO_UPSTREAM=http
EOF
        chmod 600 "$W/.env"
        # mcpo 를 먼저 띄운다(실행기가 서버를 최대 30초 기다려야 한다), 그다음 서버.
        /bin/bash "$W/run-wiki-mcp.sh" mcpo >"$W/logs/mcpo.log" 2>&1 & MPID=$!
        WIRE_PIDS="$WIRE_PIDS $MPID"
        /bin/bash "$W/run-wiki-mcp.sh" http >"$W/logs/http.log" 2>&1 & SPID=$!
        WIRE_PIDS="$WIRE_PIDS $SPID"
        up=""
        for i in $(seq 1 60); do
            curl -sf -o /dev/null http://127.0.0.1:18766/openapi.json && { up=$i; break; }
            sleep 1
        done
        [ -n "$up" ] && pass "wire: mcpo relay up (${up}s, waited for the server)" \
            || bad "wire: mcpo relay up" "no openapi.json in 60s; mcpo: $(tail -2 "$W/logs/mcpo.log" 2>/dev/null | tr '\n' ' ')"
        body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}'
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' -H @- -d "$body" \
            http://127.0.0.1:18765/mcp <<< "Authorization: Bearer $WK1")" || code=000
        [ "$code" = 200 ] && pass "wire: initialize with key -> 200" || bad "wire: initialize with key -> 200" "HTTP $code"
        # stateless 확인: initialize 응답 헤더에 mcp-session-id 가 없어야 한다(stateful 이면
        # 서버 재시작 뒤 mcpo 가 묵은 세션 ID 로 404 → 500 에 갇힌다). 대소문자 무시.
        ihdr="$W/logs/init-hdrs.txt"
        curl -s -o /dev/null -D "$ihdr" -m 5 -X POST -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' -H @- -d "$body" \
            http://127.0.0.1:18765/mcp <<< "Authorization: Bearer $WK1" || true
        ! grep -qi 'mcp-session-id' "$ihdr" \
            && pass "wire: server is stateless (no mcp-session-id)" \
            || bad "wire: server is stateless (no mcp-session-id)" "mcp-session-id present in initialize response headers"
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' -d "$body" http://127.0.0.1:18765/mcp)" || code=000
        [ "$code" = 401 ] && pass "wire: initialize without key -> 401" || bad "wire: initialize without key -> 401" "HTTP $code"
        tool="$(curl -sf http://127.0.0.1:18766/openapi.json | "$WIRE_VENV/bin/python" -I -c '
import json, sys
d = json.load(sys.stdin)
schemas = d.get("components", {}).get("schemas", {})
for path, ops in sorted(d.get("paths", {}).items()):
    s = ops.get("post", {}).get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema", {})
    s = schemas.get(s.get("$ref", "").rsplit("/", 1)[-1], s)
    if s.get("required"):
        print(path)
        break
')" || tool=""
        [ -n "$tool" ] && pass "wire: picked a tool with required args ($tool)" \
            || bad "wire: picked a tool with required args" "openapi.json unreadable"
        if [ -n "$tool" ]; then
            code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' \
                -H @- -d '{}' "http://127.0.0.1:18766$tool" <<< "Authorization: Bearer $WK2")" || code=000
            [ "$code" = 422 ] && pass "wire: mcpo good key -> 422" || bad "wire: mcpo good key -> 422" "HTTP $code"
            code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -X POST -H 'Content-Type: application/json' \
                -H @- -d '{}' "http://127.0.0.1:18766$tool" <<< "Authorization: Bearer wrong-key")" || code=000
            [ "$code" = 403 ] && pass "wire: mcpo wrong key -> 403" || bad "wire: mcpo wrong key -> 403" "HTTP $code"
        fi
        # 서버가 떠 있는 동안 stdio serve 는 거부되어야 한다.
        out="$W/logs/serve.log"
        /bin/bash "$W/run-wiki-mcp.sh" serve >"$out" 2>&1; rc=$?
        [ $rc -ne 0 ] && has "$out" "실행 중" && pass "wire: serve refuses while the HTTP server runs" \
            || bad "wire: serve refuses while the HTTP server runs" "rc=$rc"
        # stdio 업스트림의 mcpo 도 같은 이유로 거부되어야 한다. 포트는 이미 떠 있는 중계
        # mcpo(18766) 를 건드리지 않도록 18767 로; 가드를 뚫고 떠 버리면 즉시 죽인다.
        out="$W/logs/mcpo-stdio.log"
        WIKI_MCPO_UPSTREAM=stdio WIKI_MCPO_PORT=18767 \
            /bin/bash "$W/run-wiki-mcp.sh" mcpo >"$out" 2>&1 & GPID=$!
        WIRE_PIDS="$WIRE_PIDS $GPID"
        gdone=""
        for i in 1 2 3 4 5; do
            kill -0 "$GPID" 2>/dev/null || { gdone=1; break; }
            sleep 1
        done
        [ -n "$gdone" ] || { kill "$GPID" 2>/dev/null || true; }
        wait "$GPID" 2>/dev/null; rc=$?
        [ "$rc" -eq 1 ] && has "$out" "WIKI_MCPO_UPSTREAM=http" \
            && pass "wire: mcpo with stdio upstream refuses while the HTTP server runs" \
            || bad "wire: mcpo with stdio upstream refuses while the HTTP server runs" \
                "rc=$rc $(tail -1 "$out" 2>/dev/null)"
        # 서버 재시작: mcpo 는 다음 호출에 스스로 회복된다.
        kill "$SPID" 2>/dev/null || true
        for i in $(seq 1 20); do
            [ -z "$(lsof -nP -iTCP:18765 -sTCP:LISTEN -t 2>/dev/null)" ] && break
            sleep 1
        done
        /bin/bash "$W/run-wiki-mcp.sh" http >>"$W/logs/http.log" 2>&1 & SPID=$!
        WIRE_PIDS="$WIRE_PIDS $SPID"
        up=""
        for i in $(seq 1 60); do
            code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 http://127.0.0.1:18765/mcp)" || code=000
            case "$code" in 401|406|200) up=$i; break ;; esac
            sleep 1
        done
        [ -n "$up" ] && pass "wire: server restarted (${up}s)" || bad "wire: server restarted" "no answer in 60s"
        code=""
        for i in $(seq 1 10); do
            code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST -H 'Content-Type: application/json' \
                -H @- -d '{"query":"wiki"}' http://127.0.0.1:18766/search_wiki <<< "Authorization: Bearer $WK2")" || code=000
            [ "$code" = 200 ] && break
            sleep 2
        done
        [ "$code" = 200 ] && pass "wire: /search_wiki through mcpo after restart -> 200" \
            || bad "wire: /search_wiki through mcpo after restart -> 200" "HTTP $code"
    fi
fi

echo
echo "elapsed: ${SECONDS}s"
if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi
