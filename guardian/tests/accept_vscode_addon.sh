#!/bin/bash
# guardian/pack-vscode-addon.sh + guardian/vscode-addon/install-vscode.sh 인수 시험 (빌드 Mac 전용,
# 사람이 실행한다: 진짜 dmg(약 350MB)를 마운트·복사하고 실제 code CLI 로 확장을 설치한다).
# 사용: guardian/tests/accept_vscode_addon.sh     (모두 통과하면 "ACCEPT PASS", 종료 0)
# 묶음 하나를 --no-tar 로 만들고 스테이지 구성·SHA256SUMS·MANIFEST 핀 일치를 보고, 거부해야 할 경우
# (깨진 벤더 파일, 이미 있는 출력, 이상한 이름, 모르는 옵션)와 설치 전 경로(--dry-run)를 본 뒤,
# 임시 폴더로 완전 격리 설치(router/direct/키트 없음 세 국면)를 돌려 되돌려 본다.
# 시간이 좀 걸린다(dmg 복사 + 확장 설치); 마지막에 경과 시간을 찍는다.
set -u
SECONDS=0
G="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$G/.." && pwd)"
P="$G/pack-vscode-addon.sh"
I="$G/vscode-addon/install-vscode.sh"
V="$ROOT/dist/vendor/vscode"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-vscode-addon.XXXXXX")"
T="$(cd "$T" && pwd)"
trap 'rm -rf "$T"' EXIT
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1: $2"; fail=1; }
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$n"; else bad "$n" "$*"; fi; }
has() { local f="$1" s="$2" hit; hit="$(grep -F -e "$s" "$f" || true)"; [ -n "$hit" ]; }
hasnt() { local f="$1" s="$2" hit; hit="$(grep -F -e "$s" "$f" || true)"; [ -z "$hit" ]; }

[ -x "$P" ] || { echo "FAIL pack script missing or not executable: $P"; exit 1; }
[ -x "$I" ] || { echo "FAIL installer missing or not executable: $I"; exit 1; }
[ -f "$V/VSCode-darwin-arm64.dmg" ] || { echo "FAIL vendor dmg missing: $V"; exit 1; }

# pack 스크립트의 핀(버전·팀) — MANIFEST 와 스테이지 파일 이름이 이와 같아야 한다.
pget() { sed -n "s/^$1=\"\\([^\"]*\\)\".*/\\1/p" "$P" | head -1; }
PVS="$(pget VSCODE_VERSION)"; PTEAM="$(pget VSCODE_TEAM)"
PFOAM="$(pget FOAM_VERSION)"; PCC="$(pget CLAUDE_EXT_VERSION)"; PCTEAM="$(pget CLAUDE_TEAM)"
[ -n "$PVS" ] && [ -n "$PFOAM" ] && [ -n "$PCC" ] || { echo "FAIL cannot read pins from $P"; exit 1; }
APP="Visual Studio Code.app"
CODEBIN="$T/apps/$APP/Contents/Resources/app/bin/code"

# ---- 1. 도움말·옵션 --------------------------------------------------------------------------
"$P" --help >"$T/help.out" 2>&1; rc=$?
[ $rc -eq 0 ] && has "$T/help.out" --vendor= && has "$T/help.out" --out= && has "$T/help.out" --name= \
    && has "$T/help.out" --no-tar && pass "pack help" || bad "pack help" "rc=$rc or options missing"
"$P" --bogus --out="$T/o0" >"$T/bogus.out" 2>&1; rc=$?
[ $rc -eq 2 ] && pass "pack unknown option exits 2" || bad "pack unknown option exits 2" "rc=$rc"
[ ! -e "$T/o0" ] && pass "pack unknown option writes nothing" || bad "pack unknown option writes nothing" "$T/o0 exists"
"$I" --help >"$T/ihelp.out" 2>&1; rc=$?
[ $rc -eq 0 ] && has "$T/ihelp.out" --dry-run && has "$T/ihelp.out" --app-dir= && has "$T/ihelp.out" --user-data-dir= \
    && pass "installer help" || bad "installer help" "rc=$rc or options missing"
"$I" --bogus >"$T/ibogus.out" 2>&1; rc=$?
[ $rc -eq 2 ] && pass "installer unknown option exits 2" || bad "installer unknown option exits 2" "rc=$rc"

# ---- 2. 정상 묶음 (--no-tar) ------------------------------------------------------------------
O="$T/out"; N="t1"
"$P" --no-tar --out="$O" --name="$N" >"$T/pack.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "pack --no-tar exits 0" || { bad "pack --no-tar exits 0" "rc=$rc"; sed 's/^/    /' "$T/pack.out" | tail -8; }
K="$O/$N"
check "stage folder exists" test -d "$K"
# 스테이지는 정확히 예상 파일들(숨김 파일 포함, .DS_Store 없음)로 구성된다.
want="$T/want.list"
cat >"$want" <<EOF
./MANIFEST.env
./README.md
./SHA256SUMS
./app/VSCode-darwin-arm64.dmg
./extensions/Anthropic.claude-code-${PCC}-darwin-arm64.vsix
./extensions/foam.foam-vscode-${PFOAM}.vsix
./install-vscode.sh
./wiki-workspace/.foam/templates/new-note.md
./wiki-workspace/.vscode/settings.json
EOF
(cd "$K" && find . -type f | LC_ALL=C sort) >"$T/got.list" 2>/dev/null
cmp -s "$want" "$T/got.list" && pass "stage holds exactly the expected files" \
    || bad "stage holds exactly the expected files" "$(diff "$want" "$T/got.list" | head -4)"
( cd "$K" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1 && pass "stage SHA256SUMS -c" || bad "stage SHA256SUMS -c" "mismatch"
[ "$(stat -f %Lp "$K/install-vscode.sh")" = 755 ] && pass "install-vscode.sh is 755" || bad "install-vscode.sh is 755" "$(stat -f %Lp "$K/install-vscode.sh")"
# MANIFEST 값이 pack 스크립트의 핀과 하나하나 같은가.
for kv in "vscode_version=$PVS" "vscode_team=$PTEAM" "foam_version=$PFOAM" \
    "claude_code_ext_version=$PCC" "claude_team=$PCTEAM" \
    "app_dmg=app/VSCode-darwin-arm64.dmg" "foam_vsix=extensions/foam.foam-vscode-${PFOAM}.vsix" \
    "claude_vsix=extensions/Anthropic.claude-code-${PCC}-darwin-arm64.vsix"; do
    grep -qx "$kv" "$K/MANIFEST.env" && pass "MANIFEST $kv" || bad "MANIFEST $kv" "missing"
done
grep -Eqx 'built_utc=[0-9]{8}T[0-9]{4}Z' "$K/MANIFEST.env" && pass "MANIFEST built_utc stamp" || bad "MANIFEST built_utc stamp" "$(grep built_utc "$K/MANIFEST.env")"
# 같은 이름으로 반복 → 거부.
"$P" --no-tar --out="$O" --name="$N" >"$T/pack2.out" 2>&1; rc=$?
[ $rc -ne 0 ] && pass "repeat pack with same name refused" || bad "repeat pack with same name refused" "rc=0"

# ---- 3. 깨진 벤더 디렉터리 --------------------------------------------------------------------
cp -R "$V" "$T/v"
printf 'x' >>"$T/v/foam.foam-vscode-${PFOAM}.vsix"
"$P" --vendor="$T/v" --no-tar --out="$T/oref" --name=corrupt >"$T/pack3.out" 2>&1; rc=$?
[ $rc -ne 0 ] && pass "corrupted vendor refused" || bad "corrupted vendor refused" "rc=0"
[ -z "$(find "$T/oref" -mindepth 1 -print 2>/dev/null)" ] && pass "corrupted vendor leaves nothing" \
    || bad "corrupted vendor leaves nothing" "$(find "$T/oref" -mindepth 1 | head -3)"
for nm in "../evil" "sp ace" "a/b" ""; do
    "$P" --no-tar --out="$T/o-name" --name="$nm" >/dev/null 2>&1; rc=$?
    [ $rc -ne 0 ] && pass "refuses name '$nm'" || bad "refuses name '$nm'" "rc=0"
done
[ -z "$(find "$T/o-name" -mindepth 1 -print 2>/dev/null)" ] && pass "bad names write nothing" || bad "bad names write nothing" "files left"

# ---- 4. 완전 격리 설치 (router 모드) -----------------------------------------------------------
mkdir -p "$T/xdg/claude-lms" "$T/wiki" "$T/empty"
cat >"$T/xdg/claude-lms/env" <<EOF
CLAUDE_LMS_MODEL='test-model'
CLAUDE_LMS_ROUTER='http://127.0.0.1:1240'
CLAUDE_LMS_TOKEN='SECRET-TOKEN-SHOULD-NOT-APPEAR'
EOF
RUN=(--app-dir="$T/apps" --user-data-dir="$T/ud" --extensions-dir="$T/ext" --wiki="$T/wiki")
( cd "$K" && XDG_CONFIG_HOME="$T/xdg" ./install-vscode.sh "${RUN[@]}" ) >"$T/ins1.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "isolated install exits 0" || { bad "isolated install exits 0" "rc=$rc"; tail -12 "$T/ins1.log" | sed 's/^/    /'; }
check "app installed in \$T/apps" test -d "$T/apps/$APP"
check "installed app verifies" codesign --verify --deep --strict "$T/apps/$APP"
xattr -p com.apple.quarantine "$T/apps/$APP" >/dev/null 2>&1 && bad "app has no quarantine" "quarantine present" || pass "app has no quarantine"
both="$("$CODEBIN" --user-data-dir "$T/ud" --extensions-dir "$T/ext" --list-extensions --show-versions 2>/dev/null || true)"
low="$(printf '%s\n' "$both" | tr '[:upper:]' '[:lower:]')"
for idv in "foam.foam-vscode@${PFOAM}" "anthropic.claude-code@${PCC}"; do
    hit="$(printf '%s\n' "$low" | grep -Fx "$idv" || true)"
    [ -n "$hit" ] && pass "extension listed: $idv" || bad "extension listed: $idv" "not in --list-extensions"
done
nbin="$(find "$T/ext" -maxdepth 1 -type d -iname 'anthropic.claude-code-*' | head -1)"
check "native binary exists" test -f "$nbin/resources/native-binary/claude"
xattr -p com.apple.quarantine "$nbin/resources/native-binary/claude" >/dev/null 2>&1 \
    && bad "native binary has no quarantine" "quarantine present" || pass "native binary has no quarantine"
S="$T/ud/User/settings.json"
check "settings.json exists" test -s "$S"
[ "$(stat -f %Lp "$S")" = 600 ] && pass "settings.json mode 600" || bad "settings.json mode 600" "$(stat -f %Lp "$S")"
for s in '"http://127.0.0.1:1240"' 'spark-large' 'local-fast' 'ENABLE_CLAUDEAI_MCP_SERVERS'; do
    has "$S" "$s" && pass "settings contain $s" || bad "settings contain $s" "missing"
done
hasnt "$S" "SECRET-TOKEN-SHOULD-NOT-APPEAR" && pass "token never copied into settings" || bad "token never copied into settings" "leaked"
check "wiki .vscode/settings.json placed" test -f "$T/wiki/.vscode/settings.json"
check "wiki new-note.md template placed" test -f "$T/wiki/.foam/templates/new-note.md"

# ---- 5. 재실행: 유지·사이드 파일 ---------------------------------------------------------------
cp "$S" "$T/settings.before"
( cd "$K" && XDG_CONFIG_HOME="$T/xdg" ./install-vscode.sh "${RUN[@]}" ) >"$T/ins2.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "rerun exits 0" || { bad "rerun exits 0" "rc=$rc"; tail -12 "$T/ins2.log" | sed 's/^/    /'; }
has "$T/ins2.log" "same or newer: kept" && pass "rerun keeps the app" || bad "rerun keeps the app" "log lacks 'same or newer: kept'"
has "$T/ins2.log" "foam.foam-vscode@${PFOAM} is the same or newer than ${PFOAM}: kept" \
    && has "$T/ins2.log" "Anthropic.claude-code@${PCC} is the same or newer than ${PCC}: kept" \
    && pass "rerun keeps the extensions" || bad "rerun keeps the extensions" "log lacks the kept notes"
has "$T/ins2.log" "extensions: foam.foam-vscode@${PFOAM} kept; Anthropic.claude-code@${PCC} kept;" \
    && pass "summary lists both extensions as kept" || bad "summary lists both extensions as kept" "$(grep 'extensions:' "$T/ins2.log")"
cmp -s "$S" "$T/settings.before" && pass "settings.json unchanged byte-for-byte" || bad "settings.json unchanged byte-for-byte" "differs"
check "side file settings.vscode-addon.jsonc exists" test -s "$T/ud/User/settings.vscode-addon.jsonc"

# ---- 5b. 확장 다운그레이드 금지: 더 새 버전이 설치돼 있으면 유지 ------------------------------------
# (설치된 claude 확장을 더 새 버전으로 위장한다 — --list-extensions --show-versions 가 보는 건
#  확장 폴더 이름과 그 안 package.json 의 버전이다. 재실행해도 핀 버전으로 내려가면 안 된다)
CCNEW="${PCC%.*}.$((${PCC##*.} + 1))"
mv "$T/ext/anthropic.claude-code-${PCC}" "$T/ext/anthropic.claude-code-${CCNEW}"
sed -i '' "s/\"version\": \"${PCC}\"/\"version\": \"${CCNEW}\"/" "$T/ext/anthropic.claude-code-${CCNEW}/package.json"
sed -i '' "s/anthropic.claude-code-${PCC}/anthropic.claude-code-${CCNEW}/g; s/\"version\":\"${PCC}\"/\"version\":\"${CCNEW}\"/" \
    "$T/ext/extensions.json"
( cd "$K" && XDG_CONFIG_HOME="$T/xdg" ./install-vscode.sh --no-app --no-settings --no-wiki \
    --user-data-dir="$T/ud" --extensions-dir="$T/ext" ) >"$T/ins2n.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "newer-installed run exits 0" \
    || { bad "newer-installed run exits 0" "rc=$rc"; tail -12 "$T/ins2n.log" | sed 's/^/    /'; }
has "$T/ins2n.log" "Anthropic.claude-code@${CCNEW} is the same or newer than ${PCC}: kept" \
    && pass "newer extension kept, not downgraded" || bad "newer extension kept, not downgraded" "log lacks the kept note"
hasnt "$T/ins2n.log" "installed Anthropic.claude-code@" \
    && pass "newer extension not reinstalled over" || bad "newer extension not reinstalled over" "an install note appeared"
newer="$( ("$CODEBIN" --user-data-dir "$T/ud" --extensions-dir "$T/ext" --list-extensions --show-versions 2>/dev/null || true) | tr '[:upper:]' '[:lower:]')"
hit="$(printf '%s\n' "$newer" | grep -Fx "anthropic.claude-code@${CCNEW}" || true)"
[ -n "$hit" ] && pass "claude extension still ${CCNEW} after the run" \
    || bad "claude extension still ${CCNEW} after the run" "listed: $(printf '%s' "$newer" | tr '\n' ' ')"

# ---- 5c. 오래된 버전이 설치돼 있으면 핀 버전으로 설치 ----------------------------------------------
CCOLD="${PCC%.*}.$((${PCC##*.} - 1))"
mv "$T/ext/anthropic.claude-code-${CCNEW}" "$T/ext/anthropic.claude-code-${CCOLD}"
sed -i '' "s/\"version\": \"${CCNEW}\"/\"version\": \"${CCOLD}\"/" "$T/ext/anthropic.claude-code-${CCOLD}/package.json"
sed -i '' "s/anthropic.claude-code-${CCNEW}/anthropic.claude-code-${CCOLD}/g; s/\"version\":\"${CCNEW}\"/\"version\":\"${CCOLD}\"/" \
    "$T/ext/extensions.json"
( cd "$K" && XDG_CONFIG_HOME="$T/xdg" ./install-vscode.sh --no-app --no-settings --no-wiki \
    --user-data-dir="$T/ud" --extensions-dir="$T/ext" ) >"$T/ins2o.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "older-installed run exits 0" \
    || { bad "older-installed run exits 0" "rc=$rc"; tail -12 "$T/ins2o.log" | sed 's/^/    /'; }
has "$T/ins2o.log" "installed Anthropic.claude-code@${PCC}" \
    && pass "older extension replaced by the pinned one" || bad "older extension replaced by the pinned one" "no install note"
back="$( ("$CODEBIN" --user-data-dir "$T/ud" --extensions-dir "$T/ext" --list-extensions --show-versions 2>/dev/null || true) | tr '[:upper:]' '[:lower:]')"
hit="$(printf '%s\n' "$back" | grep -Fx "anthropic.claude-code@${PCC}" || true)"
[ -n "$hit" ] && pass "claude extension back at ${PCC}" \
    || bad "claude extension back at ${PCC}" "listed: $(printf '%s' "$back" | tr '\n' ' ')"

# ---- 6. direct 모드 (라우터 없음) --------------------------------------------------------------
cat >"$T/xdg/claude-lms/env" <<EOF
CLAUDE_LMS_MODEL='test-model'
CLAUDE_LMS_TOKEN='SECRET-TOKEN-SHOULD-NOT-APPEAR'
EOF
# --app-dir/--extensions-dir 로 빌드 Mac 의 실제 환경을 건드리지 않게 한다.
( cd "$K" && XDG_CONFIG_HOME="$T/xdg" ./install-vscode.sh --app-dir="$T/apps" --user-data-dir="$T/ud2" \
    --extensions-dir="$T/ext" --no-app --no-wiki ) >"$T/ins3.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "direct-mode run exits 0" || { bad "direct-mode run exits 0" "rc=$rc"; tail -12 "$T/ins3.log" | sed 's/^/    /'; }
S2="$T/ud2/User/settings.json"
check "direct-mode settings exist" test -s "$S2"
has "$S2" '"http://127.0.0.1:1234"' && pass "direct mode uses the LM Studio URL" || bad "direct mode uses the LM Studio URL" "missing"
has "$S2" 'test-model' && pass "direct mode names test-model" || bad "direct mode names test-model" "missing"
hasnt "$S2" "SECRET-TOKEN-SHOULD-NOT-APPEAR" && pass "direct mode leaks no token either" || bad "direct mode leaks no token either" "leaked"

# ---- 7. 키트 없음 (env 파일 없음) ---------------------------------------------------------------
( cd "$K" && XDG_CONFIG_HOME="$T/empty" ./install-vscode.sh --user-data-dir="$T/ud3" \
    --no-app --no-wiki --no-extensions ) >"$T/ins4.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "no-kit run exits 0" || { bad "no-kit run exits 0" "rc=$rc"; tail -12 "$T/ins4.log" | sed 's/^/    /'; }
S3="$T/ud3/User/settings.json"
check "no-kit settings exist" test -s "$S3"
has "$S3" 'telemetry.telemetryLevel' && pass "offline settings still written" || bad "offline settings still written" "missing"
hasnt "$S3" 'claudeCode.environmentVariables' && pass "no claudeCode block without the kit" || bad "no claudeCode block without the kit" "written anyway"

# ---- 7b. claudeProcessWrapper: claude-vscode 가 HOME 에 있으면 절대 경로로 등록, 없으면 안 쓴다 -------------
# (설정 단계만 돌린다 — HOME 을 가짜로 바꿔도 앱·확장 CLI 는 건드리지 않게 --no-app --no-extensions --no-wiki)
mkdir -p "$T/fhw/.local/bin"
cp "$G/claude-vscode" "$T/fhw/.local/bin/claude-vscode"
chmod 755 "$T/fhw/.local/bin/claude-vscode"
( cd "$K" && HOME="$T/fhw" XDG_CONFIG_HOME="$T/xdg" ./install-vscode.sh --no-app --no-extensions \
    --no-wiki --user-data-dir="$T/ud5" ) >"$T/ins5.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "wrapper-home run exits 0" \
    || { bad "wrapper-home run exits 0" "rc=$rc"; tail -8 "$T/ins5.log" | sed 's/^/    /'; }
S5="$T/ud5/User/settings.json"
check "wrapper-home settings exist" test -s "$S5"
has "$S5" "\"claudeCode.claudeProcessWrapper\": \"$T/fhw/.local/bin/claude-vscode\"" \
    && pass "settings register claudeProcessWrapper (absolute, no ~)" \
    || bad "settings register claudeProcessWrapper (absolute, no ~)" "$(grep claudeProcessWrapper "$S5")"
mkdir -p "$T/fhw2"
( cd "$K" && HOME="$T/fhw2" XDG_CONFIG_HOME="$T/xdg" ./install-vscode.sh --no-app --no-extensions \
    --no-wiki --user-data-dir="$T/ud6" ) >"$T/ins6.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "no-wrapper-home run exits 0" || bad "no-wrapper-home run exits 0" "rc=$rc (log: $(tail -3 "$T/ins6.log"))"
S6="$T/ud6/User/settings.json"
check "no-wrapper-home settings exist" test -s "$S6"
hasnt "$S6" "claudeProcessWrapper" && pass "no claudeProcessWrapper without the wrapper" \
    || bad "no claudeProcessWrapper without the wrapper" "$(grep claudeProcessWrapper "$S6")"

# ---- 7c. deny/prompt 안내: wrapper 있으면 claude-vscode 로 적용됐다고, 없으면 이유와 함께 미적용 -------
# (값 자체는 로그에 절대 찍히면 안 된다 — 표식값으로 확인한다)
mkdir -p "$T/xdgwrap/claude-lms"
cat >"$T/xdgwrap/claude-lms/env" <<EOF
CLAUDE_LMS_MODEL='test-model'
CLAUDE_LMS_DISALLOWED_TOOLS='WebFetch,SECRET-DENY-VALUE'
CLAUDE_LMS_SYSTEM_PROMPT_FILE='$T/SECRET-PROMPT-VALUE.md'
EOF
( cd "$K" && HOME="$T/fhw" XDG_CONFIG_HOME="$T/xdgwrap" ./install-vscode.sh --no-app --no-extensions \
    --no-wiki --user-data-dir="$T/ud7" ) >"$T/ins9.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "deny-note wrapper-home run exits 0" \
    || { bad "deny-note wrapper-home run exits 0" "rc=$rc"; tail -8 "$T/ins9.log" | sed 's/^/    /'; }
has "$T/ins9.log" "CLAUDE_LMS_DISALLOWED_TOOLS is applied to the extension through claude-vscode" \
    && pass "deny applied note with the wrapper" || bad "deny applied note with the wrapper" "missing"
has "$T/ins9.log" "CLAUDE_LMS_SYSTEM_PROMPT_FILE is applied to the extension through claude-vscode" \
    && pass "prompt-file applied note with the wrapper" || bad "prompt-file applied note with the wrapper" "missing"
hasnt "$T/ins9.log" "SECRET-DENY-VALUE" && pass "deny value never printed" || bad "deny value never printed" "leaked"
hasnt "$T/ins9.log" "SECRET-PROMPT-VALUE" && pass "prompt-file value never printed" || bad "prompt-file value never printed" "leaked"
( cd "$K" && HOME="$T/fhw2" XDG_CONFIG_HOME="$T/xdgwrap" ./install-vscode.sh --no-app --no-extensions \
    --no-wiki --user-data-dir="$T/ud8" ) >"$T/ins10.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "deny-note no-wrapper run exits 0" \
    || bad "deny-note no-wrapper run exits 0" "rc=$rc (log: $(tail -3 "$T/ins10.log"))"
has "$T/ins10.log" "CLAUDE_LMS_DISALLOWED_TOOLS is set, but there is no $T/fhw2/.local/bin/claude-vscode: not applied (install the Claude Code kit first)" \
    && pass "deny not-applied note names the reason" || bad "deny not-applied note names the reason" "missing"
has "$T/ins10.log" "CLAUDE_LMS_SYSTEM_PROMPT_FILE is set, but there is no $T/fhw2/.local/bin/claude-vscode: not applied (install the Claude Code kit first)" \
    && pass "prompt-file not-applied note names the reason" || bad "prompt-file not-applied note names the reason" "missing"
hasnt "$T/ins10.log" "SECRET-DENY-VALUE" && pass "no-wrapper run leaks no deny value either" \
    || bad "no-wrapper run leaks no deny value either" "leaked"
hasnt "$T/ins10.log" "SECRET-PROMPT-VALUE" && pass "no-wrapper run leaks no prompt-file value either" \
    || bad "no-wrapper run leaks no prompt-file value either" "leaked"

# ---- 8. --dry-run 은 아무것도 만들지 않는다 ----------------------------------------------------
( cd "$K" && XDG_CONFIG_HOME="$T/xdg" ./install-vscode.sh --dry-run --app-dir="$T/apps2" \
    --user-data-dir="$T/ud4" --wiki="$T/wiki" ) >"$T/dry.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "dry-run exits 0" || bad "dry-run exits 0" "rc=$rc (log: $(tail -3 "$T/dry.log"))"
[ ! -e "$T/apps2" ] && pass "dry-run creates no app dir" || bad "dry-run creates no app dir" "$T/apps2 exists"
[ ! -e "$T/ud4" ] && pass "dry-run creates no user-data dir" || bad "dry-run creates no user-data dir" "$T/ud4 exists"
has "$T/dry.log" "[dry-run]" && pass "dry-run prints its actions" || bad "dry-run prints its actions" "no [dry-run] lines"
has "$T/dry.log" "would install" && pass "dry-run without the app would install both" \
    || bad "dry-run without the app would install both" "no would-install note"

# ---- 8b. 앱이 이미 있는 --dry-run: 확장마다 설치할지 유지할지 예고 -----------------------------------
# (--list-extensions 는 읽기만 하므로 dry-run 에서도 실제로 읽는다 — 단 이미 있는 디렉터리로만)
( cd "$K" && XDG_CONFIG_HOME="$T/xdg" ./install-vscode.sh --dry-run --app-dir="$T/apps" \
    --user-data-dir="$T/ud" --extensions-dir="$T/ext" --no-wiki --no-settings ) >"$T/dry2.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "dry-run with the app exits 0" || bad "dry-run with the app exits 0" "rc=$rc (log: $(tail -3 "$T/dry2.log"))"
has "$T/dry2.log" "[dry-run] keep foam.foam-vscode@${PFOAM} (the same or newer than ${PFOAM})" \
    && pass "dry-run with the app would keep foam" || bad "dry-run with the app would keep foam" "missing"
has "$T/dry2.log" "[dry-run] keep Anthropic.claude-code@${PCC} (the same or newer than ${PCC})" \
    && pass "dry-run with the app would keep claude" || bad "dry-run with the app would keep claude" "missing"

echo
echo "elapsed: ${SECONDS}s"
if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi
