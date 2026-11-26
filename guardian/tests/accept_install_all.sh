#!/bin/bash
# guardian/install-all.sh 인수 시험 (빌드 Mac 전용, 사람이 실행한다).
# 진짜 인스톨러·진짜 HOME·launchctl·claude 는 전혀 건드리지 않는다: mktemp 가짜 번들
# (install-all.sh 사본 + MANIFEST.env + 스텁 설치기 넷)과 가짜 HOME 으로 완전히 격리해
# 돌린다. 각 스텁은 자기 이름과 argv 를 $CALLS 로그에 한 줄로 남긴다. dmg 는 app_dmg=
# 빈 값 + --no-app 으로 피한다. 모두 통과하면 "ACCEPT PASS", 종료 0.
set -u
SECONDS=0
G="$(cd "$(dirname "$0")/.." && pwd)"
IA="$G/install-all.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-installall.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "${T:?}"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }
has()  { local f="$1" s="$2"; grep -Fq -e "$s" "$f"; }
hasnt(){ local f="$1" s="$2"; ! grep -Fq -e "$s" "$f"; }

CALLS="$T/calls.log"
export CALLS

# stub PATH NAME [RC] — 호출을 한 줄로 기록하는 가짜 설치기
stub() {
    local p="$1" n="$2" rc="${3:-0}"
    printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\nexit %s\n' "$n" "$rc" >"$p"
    chmod 755 "$p"
}

# mk_bundle DIR KIT CC [KIT_RC] [BUILT_HOME] [VS] [VS_RC] [HOP] [HOP_RC] — 가짜 번들 (KIT/CC/VS/HOP: 1=폴더 있음, 0=뺌)
mk_bundle() {
    local d="$1" kit="$2" cc="$3" kitrc="${4:-0}" bh="${5:-}" vs="${6:-0}" vsrc="${7:-0}" hop="${8:-0}" hoprc="${9:-0}"
    mkdir -p "$d/wiki-layer"
    cp "$IA" "$d/install-all.sh"
    cat >"$d/MANIFEST.env" <<EOF
app_name=LM Studio.app
app_version=0.0.1
app_dmg=
EOF
    if [ -n "$bh" ]; then echo "built_home=$bh" >>"$d/MANIFEST.env"; fi
    stub "$d/install.sh" install.sh
    stub "$d/wiki-layer/install-wiki.sh" install-wiki.sh
    if [ "$cc" = 1 ]; then
        mkdir -p "$d/claude-code"
        stub "$d/claude-code/install-claude-code.sh" install-claude-code.sh
    fi
    if [ "$kit" = 1 ]; then
        mkdir -p "$d/wiki-mcp-kit"
        stub "$d/wiki-mcp-kit/install-wiki-mcp.sh" install-wiki-mcp.sh "$kitrc"
    fi
    if [ "$vs" = 1 ]; then
        mkdir -p "$d/vscode-addon"
        stub "$d/vscode-addon/install-vscode.sh" install-vscode.sh "$vsrc"
    fi
    if [ "$hop" = 1 ]; then
        mkdir -p "$d/hop-viewer"
        stub "$d/hop-viewer/install-hop.sh" install-hop.sh "$hoprc"
    fi
}

# sc_write FILE TARGET — MLX 엔진 venv 의 sitecustomize.py 흉내: 첫 줄 import sys,
# 마지막 줄 addsitedir('TARGET'). 모드 640 을 강제해 cat > 치환이 모드를 지키는지도 본다.
sc_write() {
    mkdir -p "$(dirname "$1")"
    { printf 'import sys\n'; printf "addsitedir('%s')\n" "$2"; } >"$1"
    chmod 640 "$1"
}

# run_all BUNDLE OUT ERR args... — 가짜 HOME 으로 install-all.sh 실행
run_all() {
    local b="$1" o="$2" e="$3"; shift 3
    HOME="$T/home" bash "$b/install-all.sh" "$@" >"$o" 2>"$e"
}

kit_line() { grep -m1 '^install-wiki-mcp\.sh ' "$CALLS"; }
vs_line()  { grep -m1 '^install-vscode\.sh ' "$CALLS"; }
hop_line() { grep -m1 '^install-hop\.sh ' "$CALLS"; }

# ---- 1. 문법 -------------------------------------------------------------------------------------
/bin/bash -n "$IA" && pass "bash -n install-all.sh" || bad "bash -n install-all.sh" "does not parse"

mkdir -p "$T/home"
B="$T/b1"
mk_bundle "$B" 1 1

# ---- 2. (a)+(b) 순서와 인자 전달: dry-run 이어도 wiki-home 에 .env 가 있으면 kit 이 실제로 불린다 ----
mkdir -p "$T/wh1"
: >"$T/wh1/.env"
: >"$CALLS"
run_all "$B" "$T/a.out" "$T/a.err" --no-app --dry-run --no-start --wiki-home="$T/wh1" --wiki-mcp-port=18765
rc=$?
[ $rc -eq 0 ] && pass "dry-run with .env exits 0" || bad "dry-run with .env exits 0" "rc=$rc $(tail -2 "$T/a.err")"
n1="$(grep -n '^install\.sh ' "$CALLS" | head -1 | cut -d: -f1)"
n2="$(grep -n '^install-wiki\.sh ' "$CALLS" | head -1 | cut -d: -f1)"
n3="$(grep -n '^install-claude-code\.sh ' "$CALLS" | head -1 | cut -d: -f1)"
n4="$(grep -n '^install-wiki-mcp\.sh ' "$CALLS" | head -1 | cut -d: -f1)"
[ -n "$n1" ] && [ -n "$n2" ] && [ -n "$n3" ] && [ -n "$n4" ] \
    && [ "$n1" -lt "$n2" ] && [ "$n2" -lt "$n3" ] && [ "$n3" -lt "$n4" ] \
    && pass "order: guardian -> wiki -> claude -> kit" \
    || bad "order: guardian -> wiki -> claude -> kit" "lines ${n1:-?}/${n2:-?}/${n3:-?}/${n4:-?}"
kl="$T/kit-line.txt"; kit_line >"$kl"
for s in "--dry-run" "--no-start" "--wiki-home=$T/wh1" "--port=18765"; do
    has "$kl" "$s" && pass "kit gets $s" || bad "kit gets $s" "$(cat "$kl")"
done
has "$CALLS" "install.sh --no-start --no-app --dry-run" \
    && pass "guardian gets --no-start --no-app --dry-run" \
    || bad "guardian gets --no-start --no-app --dry-run" "$(grep -m1 '^install\.sh ' "$CALLS")"

# ---- 3. (c) dry-run + .env 없음 → kit 미호출, [dry-run] note --------------------------------------
: >"$CALLS"
run_all "$B" "$T/c.out" "$T/c.err" --no-app --dry-run
rc=$?
[ $rc -eq 0 ] && pass "dry-run without .env exits 0" || bad "dry-run without .env exits 0" "rc=$rc $(tail -2 "$T/c.err")"
hasnt "$CALLS" "install-wiki-mcp.sh" && pass "dry-run without .env does not call the kit" \
    || bad "dry-run without .env does not call the kit" "$(kit_line)"
has "$T/c.out" "[dry-run] wiki-mcp-kit/install-wiki-mcp.sh" && pass "prints the [dry-run] kit line" \
    || bad "prints the [dry-run] kit line" "$(grep 'dry-run.*wiki-mcp-kit' "$T/c.out" | head -1)"

# ---- 4. (d) --no-claude-code → kit 에 --no-claude -------------------------------------------------
: >"$CALLS"
run_all "$B" "$T/d.out" "$T/d.err" --no-app --dry-run --no-claude-code --wiki-home="$T/wh1"
rc=$?
[ $rc -eq 0 ] && pass "--no-claude-code run exits 0" || bad "--no-claude-code run exits 0" "rc=$rc $(tail -2 "$T/d.err")"
kit_line | grep -q -- '--no-claude' && pass "--no-claude-code passes --no-claude to the kit" \
    || bad "--no-claude-code passes --no-claude to the kit" "$(kit_line)"
hasnt "$CALLS" "install-claude-code.sh" && pass "--no-claude-code skips the claude step" \
    || bad "--no-claude-code skips the claude step" "$(grep -m1 '^install-claude-code\.sh ' "$CALLS")"

# ---- 5. (e) 번들에 claude-code/ 없음 → kit 에 --no-claude ----------------------------------------
B2="$T/b2"
mk_bundle "$B2" 1 0
: >"$CALLS"
run_all "$B2" "$T/e.out" "$T/e.err" --no-app --dry-run --wiki-home="$T/wh1"
rc=$?
[ $rc -eq 0 ] && pass "bundle without claude-code/ exits 0" || bad "bundle without claude-code/ exits 0" "rc=$rc $(tail -2 "$T/e.err")"
kit_line | grep -q -- '--no-claude' && pass "no claude-code/ passes --no-claude to the kit" \
    || bad "no claude-code/ passes --no-claude to the kit" "$(kit_line)"
has "$T/e.out" "no claude-code" && pass "no claude-code/ says so" || bad "no claude-code/ says so" "note missing"

# ---- 6. (f) --no-wiki-mcp-http → kit 미호출 ------------------------------------------------------
: >"$CALLS"
run_all "$B" "$T/f.out" "$T/f.err" --no-app --dry-run --no-wiki-mcp-http --wiki-home="$T/wh1"
rc=$?
[ $rc -eq 0 ] && pass "--no-wiki-mcp-http exits 0" || bad "--no-wiki-mcp-http exits 0" "rc=$rc $(tail -2 "$T/f.err")"
hasnt "$CALLS" "install-wiki-mcp.sh" && pass "--no-wiki-mcp-http does not call the kit" \
    || bad "--no-wiki-mcp-http does not call the kit" "$(kit_line)"
has "$T/f.out" "--no-wiki-mcp-http" && pass "--no-wiki-mcp-http prints its note" \
    || bad "--no-wiki-mcp-http prints its note" "note missing"

# ---- 7. (g) 번들에 wiki-mcp-kit/ 없음 → 미호출 (옛 번들 호환) -------------------------------------
B3="$T/b3"
mk_bundle "$B3" 0 1
: >"$CALLS"
run_all "$B3" "$T/g.out" "$T/g.err" --no-app --dry-run
rc=$?
[ $rc -eq 0 ] && pass "bundle without wiki-mcp-kit/ exits 0" || bad "bundle without wiki-mcp-kit/ exits 0" "rc=$rc $(tail -2 "$T/g.err")"
hasnt "$CALLS" "install-wiki-mcp.sh" && pass "no wiki-mcp-kit/ does not call the kit" \
    || bad "no wiki-mcp-kit/ does not call the kit" "$(kit_line)"
has "$T/g.out" "no wiki-mcp-kit" && pass "no wiki-mcp-kit/ says so" || bad "no wiki-mcp-kit/ says so" "note missing"

# ---- 8. (h) kit 실패 → install-all 실패 + stderr 에 http.log 안내 ---------------------------------
B4="$T/b4"
mk_bundle "$B4" 1 1 1
: >"$CALLS"
run_all "$B4" "$T/h.out" "$T/h.err" --no-app --wiki-home="$T/wh1"
rc=$?
[ $rc -ne 0 ] && pass "kit exit 1 fails install-all" || bad "kit exit 1 fails install-all" "rc=0"
has "$T/h.err" "$T/wh1/logs/http.log" && pass "failure names the http.log under the wiki home" \
    || bad "failure names the http.log under the wiki home" "$(tail -1 "$T/h.err")"
has "$T/h.err" "wiki-mcp-kit/install-wiki-mcp.sh" && pass "failure says the kit can be rerun alone" \
    || bad "failure says the kit can be rerun alone" "$(tail -1 "$T/h.err")"
has "$T/h.err" "stdio" && pass "failure says Open WebUI keeps the stdio wiki" \
    || bad "failure says Open WebUI keeps the stdio wiki" "$(tail -1 "$T/h.err")"

# ---- 9. (i) --help --------------------------------------------------------------------------------
bash "$B/install-all.sh" --help >"$T/i.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "--help exits 0" || bad "--help exits 0" "rc=$rc"
has "$T/i.out" "--no-wiki-mcp-http" && pass "--help lists --no-wiki-mcp-http" \
    || bad "--help lists --no-wiki-mcp-http" "missing"
has "$T/i.out" "--wiki-mcp-port=N" && pass "--help lists --wiki-mcp-port=N" \
    || bad "--help lists --wiki-mcp-port=N" "missing"
head -1 "$T/i.out" | grep -qF "LLM + wiki bundle installer" && pass "--help first line is not cut off" \
    || bad "--help first line is not cut off" "$(head -1 "$T/i.out")"
has "$T/i.out" "openwebui-wiki-bundle-0.10.2" && pass "--help last line is not cut off" \
    || bad "--help last line is not cut off" "$(tail -1 "$T/i.out")"

# ---- 10. 모르는 옵션 --------------------------------------------------------------------------------
run_all "$B" "$T/u.out" "$T/u.err" --no-app --bogus
rc=$?
[ $rc -eq 2 ] && pass "unknown option exits 2" || bad "unknown option exits 2" "rc=$rc"

# ---- 11. MLX 엔진 sitecustomize.py 경로 재작성 (built_home -> 현재 HOME) ----------------------------
LX="$T/home/.lmstudio/extensions/backends/vendor/_amphibian"
SC="$LX/app-mlx-generate-mac14-arm64@39/lib/python3.11/site-packages/sitecustomize.py"
TG="$LX/cpython3.11-mac-arm64@10/lib/python3.11/site-packages"
mkdir -p "$TG"
sc_write "$SC" "/Users/builder/.lmstudio/extensions/backends/vendor/_amphibian/cpython3.11-mac-arm64@10/lib/python3.11/site-packages"
mode0="$(stat -f %Lp "$SC")"
B5="$T/b5"
mk_bundle "$B5" 1 1 0 /Users/builder

# (a) dry-run: 파일은 그대로, [dry-run] 안내만
cp "$SC" "$T/lx0"
run_all "$B5" "$T/lxa.out" "$T/lxa.err" --dry-run --no-app --no-claude-code --no-wiki-mcp-http
rc=$?
[ $rc -eq 0 ] && pass "sitecustomize dry-run exits 0" || bad "sitecustomize dry-run exits 0" "rc=$rc $(tail -2 "$T/lxa.err")"
cmp -s "$T/lx0" "$SC" && pass "dry-run leaves sitecustomize unchanged" \
    || bad "dry-run leaves sitecustomize unchanged" "file changed"
has "$T/lxa.out" "[dry-run] would rewrite" && pass "dry-run prints the would-rewrite note" \
    || bad "dry-run prints the would-rewrite note" "$(grep 'dry-run.*rewrite' "$T/lxa.out" | head -1)"

# (b) 실제 실행: builder home -> 가짜 HOME, 모드·첫 줄 유지, 대상 디렉터리가 있으니 warning 없음
run_all "$B5" "$T/lxb.out" "$T/lxb.err" --no-app --no-claude-code --no-wiki-mcp-http
rc=$?
[ $rc -eq 0 ] && pass "sitecustomize rewrite exits 0" || bad "sitecustomize rewrite exits 0" "rc=$rc $(tail -2 "$T/lxb.err")"
has "$SC" "addsitedir('$T/home/.lmstudio/" && pass "rewrite points addsitedir at the new home" \
    || bad "rewrite points addsitedir at the new home" "$(tail -1 "$SC")"
hasnt "$SC" "/Users/builder" && pass "no builder home left" || bad "no builder home left" "$(tail -1 "$SC")"
[ "$(head -1 "$SC")" = "import sys" ] && pass "first line kept" || bad "first line kept" "$(head -1 "$SC")"
[ "$(stat -f %Lp "$SC")" = "$mode0" ] && pass "file mode kept" || bad "file mode kept" "$(stat -f %Lp "$SC") != $mode0"
has "$T/lxb.out" "MLX engine path:" && pass "rewrite prints the MLX engine path note" \
    || bad "rewrite prints the MLX engine path note" "note missing"
hasnt "$T/lxb.out" "warning:" && pass "existing target does not warn" \
    || bad "existing target does not warn" "$(grep 'warning:' "$T/lxb.out" | head -1)"
cp "$SC" "$T/lx1"

# (c) 다시 실행: 바이트 동일, note 도 없음 (멱등)
run_all "$B5" "$T/lxc.out" "$T/lxc.err" --no-app --no-claude-code --no-wiki-mcp-http
rc=$?
[ $rc -eq 0 ] && pass "second run exits 0" || bad "second run exits 0" "rc=$rc $(tail -2 "$T/lxc.err")"
cmp -s "$T/lx1" "$SC" && pass "second run is byte-identical" || bad "second run is byte-identical" "file changed"
hasnt "$T/lxc.out" "MLX engine path:" && pass "second run prints no MLX note" \
    || bad "second run prints no MLX note" "$(grep 'MLX engine path' "$T/lxc.out" | head -1)"

# (d) 대상 디렉터리가 없는 두 번째 venv: 재작성 + warning, 종료 코드는 0
SC2="$LX/app-other@1/lib/python3.11/site-packages/sitecustomize.py"
sc_write "$SC2" "/Users/builder/.lmstudio/extensions/backends/vendor/_amphibian/missing@1/lib/python3.11/site-packages"
run_all "$B5" "$T/lxd.out" "$T/lxd.err" --no-app --no-claude-code --no-wiki-mcp-http
rc=$?
[ $rc -eq 0 ] && pass "missing-target run exits 0" || bad "missing-target run exits 0" "rc=$rc $(tail -2 "$T/lxd.err")"
has "$SC2" "addsitedir('$T/home/.lmstudio/" && pass "missing-target file is rewritten too" \
    || bad "missing-target file is rewritten too" "$(tail -1 "$SC2")"
has "$T/lxd.out" "warning:" && pass "missing target warns" \
    || bad "missing target warns" "$(grep 'warning:' "$T/lxd.out" | head -1)"

# (e) built_home 가 현재 HOME 과 같으면 건드리지 않는다
B6="$T/b6"
mk_bundle "$B6" 1 1 0 "$T/home"
sc_write "$SC" "/Users/builder/.lmstudio/extensions/backends/vendor/_amphibian/cpython3.11-mac-arm64@10/lib/python3.11/site-packages"
cp "$SC" "$T/lx2"
run_all "$B6" "$T/lxe.out" "$T/lxe.err" --no-app --no-claude-code --no-wiki-mcp-http
rc=$?
[ $rc -eq 0 ] && pass "same-home bundle exits 0" || bad "same-home bundle exits 0" "rc=$rc $(tail -2 "$T/lxe.err")"
cmp -s "$T/lx2" "$SC" && pass "same home leaves builder paths untouched" \
    || bad "same home leaves builder paths untouched" "file changed"
hasnt "$T/lxe.out" "MLX engine path:" && pass "same home prints no MLX note" \
    || bad "same home prints no MLX note" "$(grep 'MLX engine path' "$T/lxe.out" | head -1)"

# (f) 특수문자: 빌드 홈의 glob 문자([ ] * ?)는 글자 그대로, 대상 홈의 & 공백도 글자 그대로 (bash 5.2+ patsub_replacement),
#     대상 홈의 ' 와 \ 는 Python '...' 리터럴 안에서 같은 값이 되도록 \' \\ 로 적힌다
H7="$T/h&o'q \\me"
LP="/.lmstudio/extensions/backends/vendor/_amphibian/cp@1/lib/python3.11/site-packages"
SC7="$H7/.lmstudio/extensions/backends/vendor/_amphibian/app@1/lib/python3.11/site-packages/sitecustomize.py"
mkdir -p "$H7$LP"
sc_write "$SC7" "/Users/b[u]i*ld?er$LP"
B7="$T/b7"
mk_bundle "$B7" 1 1 0 "/Users/b[u]i*ld?er"
HOME="$H7" bash "$B7/install-all.sh" --no-app --no-claude-code --no-wiki-mcp-http >"$T/lxf.out" 2>"$T/lxf.err"
rc=$?
[ $rc -eq 0 ] && pass "special-char homes exit 0" || bad "special-char homes exit 0" "rc=$rc $(tail -2 "$T/lxf.err")"
[ "$(tail -1 "$SC7")" = "addsitedir('$T/h&o\\'q \\\\me$LP')" ] \
    && pass "special-char homes are written as a Python literal" \
    || bad "special-char homes are written as a Python literal" "$(tail -1 "$SC7")"
if command -v python3 >/dev/null 2>&1; then
    got="$(python3 -I -c 'import ast, sys
line = open(sys.argv[1]).read().splitlines()[-1]
sys.stdout.write(ast.literal_eval(line[len("addsitedir("):-1]))' "$SC7")"
    [ "$got" = "$H7$LP" ] && pass "Python reads the special-char path back as HOME's" \
        || bad "Python reads the special-char path back as HOME's" "$got"
fi

# (g) 대상 홈이 빌드 홈으로 끝나도 (/X/home 과 /home) 다시 실행할 때 겹쳐 쓰지 않는다
sc_write "$SC" "/home/.lmstudio/extensions/backends/vendor/_amphibian/cpython3.11-mac-arm64@10/lib/python3.11/site-packages"
B8="$T/b8"
mk_bundle "$B8" 1 1 0 /home
want="addsitedir('$T/home/.lmstudio/extensions/backends/vendor/_amphibian/cpython3.11-mac-arm64@10/lib/python3.11/site-packages')"
run_all "$B8" "$T/lxg.out" "$T/lxg.err" --no-app --no-claude-code --no-wiki-mcp-http
run_all "$B8" "$T/lxg2.out" "$T/lxg2.err" --no-app --no-claude-code --no-wiki-mcp-http
rc=$?
[ $rc -eq 0 ] && pass "suffix-home runs exit 0" || bad "suffix-home runs exit 0" "rc=$rc $(tail -2 "$T/lxg2.err")"
[ "$(tail -1 "$SC")" = "$want" ] && pass "suffix home is rewritten once, not nested" \
    || bad "suffix home is rewritten once, not nested" "$(tail -1 "$SC")"
hasnt "$T/lxg2.out" "MLX engine path:" && pass "suffix home: second run prints no MLX note" \
    || bad "suffix home: second run prints no MLX note" "$(grep 'MLX engine path' "$T/lxg2.out" | head -1)"

# ---- 12. VS Code 애드온 단계 (6/7) ------------------------------------------------------------------
B9="$T/b9"
mk_bundle "$B9" 1 1 0 "" 1
vl="$T/vs-line.txt"

# (a) --vscode-app-dir 로 명시: --dry-run/--wiki/--app-dir 전달, --no-app(LM Studio 것)은 미전달,
#     kit 뒤에 호출되고 6/6 표시. kit 이 실제로 불리려 dry-run + .env(§2 에서 만든 $T/wh1) 필요.
: >"$CALLS"
run_all "$B9" "$T/va.out" "$T/va.err" --no-app --dry-run --wiki-home="$T/wh1" --vscode-app-dir="$T/apps"
rc=$?
[ $rc -eq 0 ] && pass "--vscode-app-dir run exits 0" || bad "--vscode-app-dir run exits 0" "rc=$rc $(tail -2 "$T/va.err")"
vs_line >"$vl"
for s in "--dry-run" "--wiki=$T/wh1/wiki" "--app-dir=$T/apps"; do
    has "$vl" "$s" && pass "vscode gets $s" || bad "vscode gets $s" "$(cat "$vl")"
done
hasnt "$vl" "--no-app" && pass "vscode does not get the LM Studio --no-app" \
    || bad "vscode does not get the LM Studio --no-app" "$(cat "$vl")"
nk="$(grep -n '^install-wiki-mcp\.sh ' "$CALLS" | head -1 | cut -d: -f1)"
nv="$(grep -n '^install-vscode\.sh ' "$CALLS" | head -1 | cut -d: -f1)"
[ -n "$nk" ] && [ -n "$nv" ] && [ "$nk" -lt "$nv" ] && pass "order: kit -> vscode" \
    || bad "order: kit -> vscode" "lines ${nk:-?}/${nv:-?}"
has "$T/va.out" "6/7" && pass "stdout has the 6/7 step" || bad "stdout has the 6/7 step" "header missing"

# (b) --no-vscode → 미호출 + note
: >"$CALLS"
run_all "$B9" "$T/vb.out" "$T/vb.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http --no-vscode
rc=$?
[ $rc -eq 0 ] && pass "--no-vscode exits 0" || bad "--no-vscode exits 0" "rc=$rc $(tail -2 "$T/vb.err")"
hasnt "$CALLS" "install-vscode.sh" && pass "--no-vscode does not call the add-on" \
    || bad "--no-vscode does not call the add-on" "$(vs_line)"
has "$T/vb.out" "--no-vscode: skipped" && pass "--no-vscode prints its note" \
    || bad "--no-vscode prints its note" "note missing"

# (c) 번들에 vscode-addon/ 없음 → 미호출 (옛 번들 호환)
B10="$T/b10"
mk_bundle "$B10" 1 1
: >"$CALLS"
run_all "$B10" "$T/vc.out" "$T/vc.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http
rc=$?
[ $rc -eq 0 ] && pass "bundle without vscode-addon/ exits 0" || bad "bundle without vscode-addon/ exits 0" "rc=$rc $(tail -2 "$T/vc.err")"
hasnt "$CALLS" "install-vscode.sh" && pass "no vscode-addon/ does not call the add-on" \
    || bad "no vscode-addon/ does not call the add-on" "$(vs_line)"
has "$T/vc.out" "this bundle has no vscode-addon/: skipped" && pass "no vscode-addon/ says so" \
    || bad "no vscode-addon/ says so" "note missing"

# (d) --no-vscode-app + --vscode-app-dir → --no-app 도 --app-dir 도 전달
: >"$CALLS"
run_all "$B9" "$T/vd.out" "$T/vd.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http \
    --vscode-app-dir="$T/apps" --no-vscode-app
rc=$?
[ $rc -eq 0 ] && pass "--no-vscode-app run exits 0" || bad "--no-vscode-app run exits 0" "rc=$rc $(tail -2 "$T/vd.err")"
vs_line >"$vl"
has "$vl" "--no-app" && pass "--no-vscode-app passes --no-app" \
    || bad "--no-vscode-app passes --no-app" "$(cat "$vl")"
has "$vl" "--app-dir=$T/apps" && pass "--no-vscode-app keeps --app-dir" \
    || bad "--no-vscode-app keeps --app-dir" "$(cat "$vl")"

# (e) 애드온 스텁 실패(3) → install-all 실패 + 단독 재실행 안내
B11="$T/b11"
mk_bundle "$B11" 1 1 0 "" 1 3
: >"$CALLS"
run_all "$B11" "$T/ve.out" "$T/ve.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http \
    --vscode-app-dir="$T/apps"
rc=$?
[ $rc -ne 0 ] && pass "add-on exit 3 fails install-all" || bad "add-on exit 3 fails install-all" "rc=0"
has "$T/ve.err" "rerun just vscode-addon/install-vscode.sh" && pass "failure says the add-on can be rerun alone" \
    || bad "failure says the add-on can be rerun alone" "$(tail -1 "$T/ve.err")"

# (f) app-dir 옵션 없음 (자동 선택; 이 Mac 의 /Applications 상태가 결정하니 모양만 확인)
: >"$CALLS"
run_all "$B9" "$T/vf.out" "$T/vf.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http
rc=$?
[ $rc -eq 0 ] && pass "auto app-dir run exits 0" || bad "auto app-dir run exits 0" "rc=$rc $(tail -2 "$T/vf.err")"
vs_line | grep -q -- '--wiki=' && pass "auto choice still passes --wiki" \
    || bad "auto choice still passes --wiki" "$(vs_line)"

# ---- 13. HOP 뷰어 단계 (7/7) ------------------------------------------------------------------------
B12="$T/b12"
mk_bundle "$B12" 1 1 0 "" 1 0 1
hl="$T/hop-line.txt"

# (g) --hop-app-dir 로 명시: --dry-run/--app-dir 전달, --wiki=/--no-app(LM Studio 것)/--no-register 는
#     미전달, vscode 뒤에 호출되고 7/7 표시.
: >"$CALLS"
run_all "$B12" "$T/ga.out" "$T/ga.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http \
    --vscode-app-dir="$T/apps" --hop-app-dir="$T/happs"
rc=$?
if [ $rc -eq 0 ]; then pass "--hop-app-dir run exits 0"; else bad "--hop-app-dir run exits 0" "rc=$rc $(tail -2 "$T/ga.err")"; fi
hop_line >"$hl"
for s in "--dry-run" "--app-dir=$T/happs"; do
    if has "$hl" "$s"; then pass "hop gets $s"; else bad "hop gets $s" "$(cat "$hl")"; fi
done
for s in "--wiki=" "--no-app" "--no-register"; do
    if hasnt "$hl" "$s"; then pass "hop does not get $s"; else bad "hop does not get $s" "$(cat "$hl")"; fi
done
nv="$(grep -n '^install-vscode\.sh ' "$CALLS" | head -1 | cut -d: -f1)"
nh="$(grep -n '^install-hop\.sh ' "$CALLS" | head -1 | cut -d: -f1)"
if [ -n "$nv" ] && [ -n "$nh" ] && [ "$nv" -lt "$nh" ]; then pass "order: vscode -> hop"; \
    else bad "order: vscode -> hop" "lines ${nv:-?}/${nh:-?}"; fi
if has "$T/ga.out" "7/7"; then pass "stdout has the 7/7 step"; else bad "stdout has the 7/7 step" "header missing"; fi

# (h) --no-hop → 미호출 + note
: >"$CALLS"
run_all "$B12" "$T/gb.out" "$T/gb.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http \
    --vscode-app-dir="$T/apps" --no-hop
rc=$?
if [ $rc -eq 0 ]; then pass "--no-hop exits 0"; else bad "--no-hop exits 0" "rc=$rc $(tail -2 "$T/gb.err")"; fi
if hasnt "$CALLS" "install-hop.sh"; then pass "--no-hop does not call the HOP viewer"; \
    else bad "--no-hop does not call the HOP viewer" "$(hop_line)"; fi
if has "$T/gb.out" "--no-hop: skipped"; then pass "--no-hop prints its note"; else bad "--no-hop prints its note" "note missing"; fi

# (i) 번들에 hop-viewer/ 없음 → 미호출 (옛 번들 호환)
B13="$T/b13"
mk_bundle "$B13" 1 1 0 "" 1 0 0
: >"$CALLS"
run_all "$B13" "$T/gc.out" "$T/gc.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http \
    --vscode-app-dir="$T/apps"
rc=$?
if [ $rc -eq 0 ]; then pass "bundle without hop-viewer/ exits 0"; \
    else bad "bundle without hop-viewer/ exits 0" "rc=$rc $(tail -2 "$T/gc.err")"; fi
if hasnt "$CALLS" "install-hop.sh"; then pass "no hop-viewer/ does not call the viewer"; \
    else bad "no hop-viewer/ does not call the viewer" "$(hop_line)"; fi
if has "$T/gc.out" "this bundle has no hop-viewer/: skipped"; then pass "no hop-viewer/ says so"; \
    else bad "no hop-viewer/ says so" "note missing"; fi

# (j) --no-hop-register + --hop-app-dir → --no-register 도 --app-dir 도 전달
: >"$CALLS"
run_all "$B12" "$T/gd.out" "$T/gd.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http \
    --no-vscode --no-hop-register --hop-app-dir="$T/happs"
rc=$?
if [ $rc -eq 0 ]; then pass "--no-hop-register run exits 0"; \
    else bad "--no-hop-register run exits 0" "rc=$rc $(tail -2 "$T/gd.err")"; fi
hop_line >"$hl"
for s in "--no-register" "--app-dir=$T/happs"; do
    if has "$hl" "$s"; then pass "hop gets $s"; else bad "hop gets $s" "$(cat "$hl")"; fi
done

# (k) 뷰어 스텁 실패(3) → install-all 실패 + 단독 재실행 안내
B14="$T/b14"
mk_bundle "$B14" 1 1 0 "" 1 0 1 3
: >"$CALLS"
run_all "$B14" "$T/ge.out" "$T/ge.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http \
    --vscode-app-dir="$T/apps" --hop-app-dir="$T/happs"
rc=$?
if [ $rc -ne 0 ]; then pass "viewer exit 3 fails install-all"; else bad "viewer exit 3 fails install-all" "rc=0"; fi
if has "$T/ge.err" "rerun just hop-viewer/install-hop.sh"; then pass "failure says the viewer can be rerun alone"; \
    else bad "failure says the viewer can be rerun alone" "$(tail -1 "$T/ge.err")"; fi

# (l) hop app-dir 옵션 없음 (자동 선택; 이 Mac 의 실제 /Applications 가 결정하니 모양만 확인)
: >"$CALLS"
run_all "$B12" "$T/gf.out" "$T/gf.err" --no-app --dry-run --no-claude-code --no-wiki-mcp-http \
    --vscode-app-dir="$T/apps"
rc=$?
if [ $rc -eq 0 ]; then pass "auto hop app-dir run exits 0"; \
    else bad "auto hop app-dir run exits 0" "rc=$rc $(tail -2 "$T/gf.err")"; fi
if grep -q '^install-hop\.sh ' "$CALLS" || has "$T/gf.out" "HOP in /Applications is kept"; then
    pass "auto choice runs the viewer or keeps the /Applications copy"
else
    bad "auto choice runs the viewer or keeps the /Applications copy" "$(hop_line)"
fi

echo
echo "elapsed: ${SECONDS}s"
if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi
