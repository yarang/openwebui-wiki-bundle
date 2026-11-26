#!/bin/bash
# guardian/pack-hop-viewer.sh + guardian/hop-viewer/install-hop.sh 인수 시험 (빌드 Mac 전용,
# 사람이 실행한다: 진짜 dmg(약 52MB)를 마운트·복사한다).
# 사용: guardian/tests/accept_hop_viewer.sh     (모두 통과하면 "ACCEPT PASS", 종료 0)
# 묶음 하나를 --no-tar 로 만들고 스테이지 구성·SHA256SUMS·MANIFEST 핀 일치를 보고, 거부해야
# 할 경우(깨진 벤더 파일, 이미 있는 출력, 이상한 이름, 모르는 옵션)를 본 뒤, tar 꾸러미도
# 만들어 본다. 임시 폴더로 완전 격리 설치를 돌려 유지·구버전 교체·깨진 번들·남의 번들·
# --dry-run 을 확인한다. 시험은 절대 /Applications 에 쓰지 않고 설치에는 항상
# --no-register 를 준다. dmg 복사라 시간이 좀 걸린다; 마지막에 경과 시간을 찍는다.
set -u
SECONDS=0
G="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$G/.." && pwd)"
P="$G/pack-hop-viewer.sh"
I="$G/hop-viewer/install-hop.sh"
V="$ROOT/dist/vendor/hop"
T="$(mktemp -d "${TMPDIR:-/tmp}/accept-hop-viewer.XXXXXX")"
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
[ -f "$V/HOP-macos-arm64.dmg" ] || { echo "FAIL vendor dmg missing: $V"; exit 1; }

# pack 스크립트의 핀(버전·번들 ID·팀) — MANIFEST 가 이와 같아야 한다.
pget() { sed -n "s/^$1=\"\\([^\"]*\\)\".*/\\1/p" "$P" | head -1; }
PHOP="$(pget HOP_VERSION)"; PBID="$(pget HOP_BUNDLE_ID)"; PTEAM="$(pget HOP_TEAM)"
[ -n "$PHOP" ] && [ -n "$PBID" ] && [ -n "$PTEAM" ] || { echo "FAIL cannot read pins from $P"; exit 1; }
APP="HOP.app"

# ---- 1. 도움말·옵션 --------------------------------------------------------------------------
"$P" --help >"$T/help.out" 2>&1; rc=$?
[ $rc -eq 0 ] && has "$T/help.out" --vendor= && has "$T/help.out" --out= && has "$T/help.out" --name= \
    && has "$T/help.out" --no-tar && pass "pack help" || bad "pack help" "rc=$rc or options missing"
"$P" --bogus --out="$T/o0" >"$T/bogus.out" 2>&1; rc=$?
[ $rc -eq 2 ] && pass "pack unknown option exits 2" || bad "pack unknown option exits 2" "rc=$rc"
[ ! -e "$T/o0" ] && pass "pack unknown option writes nothing" || bad "pack unknown option writes nothing" "$T/o0 exists"
"$I" --help >"$T/ihelp.out" 2>&1; rc=$?
[ $rc -eq 0 ] && has "$T/ihelp.out" --dry-run && has "$T/ihelp.out" --app-dir= && has "$T/ihelp.out" --no-register \
    && pass "installer help" || bad "installer help" "rc=$rc or options missing"
"$I" --bogus >"$T/ibogus.out" 2>&1; rc=$?
[ $rc -eq 2 ] && pass "installer unknown option exits 2" || bad "installer unknown option exits 2" "rc=$rc"
"$I" --app-dir= --no-register >"$T/iempty.out" 2>&1; rc=$?
[ $rc -eq 2 ] && pass "installer empty --app-dir= exits 2" || bad "installer empty --app-dir= exits 2" "rc=$rc"

# ---- 2. 정상 묶음 (--no-tar) ------------------------------------------------------------------
O="$T/out"; N="t1"
"$P" --no-tar --out="$O" --name="$N" >"$T/pack.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "pack --no-tar exits 0" || { bad "pack --no-tar exits 0" "rc=$rc"; sed 's/^/    /' "$T/pack.out" | tail -8; }
K="$O/$N"
check "stage folder exists" test -d "$K"
# 스테이지는 정확히 예상 파일 5개(.DS_Store 없음)로 구성된다.
want="$T/want.list"
cat >"$want" <<EOF
./MANIFEST.env
./README.md
./SHA256SUMS
./app/HOP-macos-arm64.dmg
./install-hop.sh
EOF
(cd "$K" && find . -type f | LC_ALL=C sort) >"$T/got.list" 2>/dev/null
cmp -s "$want" "$T/got.list" && pass "stage holds exactly the expected files" \
    || bad "stage holds exactly the expected files" "$(diff "$want" "$T/got.list" | head -4)"
( cd "$K" && shasum -a 256 -c SHA256SUMS ) >/dev/null 2>&1 && pass "stage SHA256SUMS -c" || bad "stage SHA256SUMS -c" "mismatch"
[ "$(stat -f %Lp "$K/install-hop.sh")" = 755 ] && pass "install-hop.sh is 755" || bad "install-hop.sh is 755" "$(stat -f %Lp "$K/install-hop.sh")"
# MANIFEST 값이 pack 스크립트의 핀과 하나하나 같은가.
for kv in "hop_version=$PHOP" "hop_bundle_id=$PBID" "hop_team=$PTEAM" \
    "app_dmg=app/HOP-macos-arm64.dmg" "license=MIT" \
    "source=https://github.com/golbin/hop/releases/tag/v$PHOP"; do
    grep -qx "$kv" "$K/MANIFEST.env" && pass "MANIFEST $kv" || bad "MANIFEST $kv" "missing"
done
grep -Eqx 'built_utc=[0-9]{8}T[0-9]{4}Z' "$K/MANIFEST.env" && pass "MANIFEST built_utc stamp" || bad "MANIFEST built_utc stamp" "$(grep built_utc "$K/MANIFEST.env")"
# 같은 이름으로 반복 → 거부.
"$P" --no-tar --out="$O" --name="$N" >"$T/pack2.out" 2>&1; rc=$?
[ $rc -ne 0 ] && pass "repeat pack with same name refused" || bad "repeat pack with same name refused" "rc=0"

# ---- 3. 깨진 벤더 디렉터리·이상한 이름 ---------------------------------------------------------
cp -R "$V" "$T/v"
printf 'x' >>"$T/v/HOP-macos-arm64.dmg"
"$P" --vendor="$T/v" --no-tar --out="$T/oref" --name=corrupt >"$T/pack3.out" 2>&1; rc=$?
[ $rc -ne 0 ] && pass "corrupted vendor refused" || bad "corrupted vendor refused" "rc=0"
[ -z "$(find "$T/oref" -mindepth 1 -print 2>/dev/null)" ] && pass "corrupted vendor leaves nothing" \
    || bad "corrupted vendor leaves nothing" "$(find "$T/oref" -mindepth 1 | head -3)"
for nm in "../evil" "sp ace" "a/b" ""; do
    "$P" --no-tar --out="$T/o-name" --name="$nm" >/dev/null 2>&1; rc=$?
    [ $rc -ne 0 ] && pass "refuses name '$nm'" || bad "refuses name '$nm'" "rc=0"
done
[ -z "$(find "$T/o-name" -mindepth 1 -print 2>/dev/null)" ] && pass "bad names write nothing" || bad "bad names write nothing" "files left"

# ---- 4. 완전 격리 설치 ------------------------------------------------------------------------
# 시험이라 LaunchServices 등록은 끄고, --app-dir 로 빌드 Mac 의 /Applications 를 건드리지 않는다.
RUN=(--app-dir="$T/apps" --no-register)
( cd "$K" && ./install-hop.sh "${RUN[@]}" ) >"$T/ins1.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "isolated install exits 0" || { bad "isolated install exits 0" "rc=$rc"; tail -12 "$T/ins1.log" | sed 's/^/    /'; }
check "app installed in \$T/apps" test -d "$T/apps/$APP"
check "installed app verifies" codesign --verify --deep --strict "$T/apps/$APP"
xattr -p com.apple.quarantine "$T/apps/$APP" >/dev/null 2>&1 && bad "app has no quarantine" "quarantine present" || pass "app has no quarantine"
# --no-register 을 줬으니 등록 단계는 건너뛰었어야 한다.
hasnt "$T/ins1.log" "lsregister" && pass "--no-register really skips registration" || bad "--no-register really skips registration" "log mentions lsregister"
[ "$(defaults read "$T/apps/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)" = "$PHOP" ] \
    && pass "installed version is the pin ($PHOP)" || bad "installed version is the pin ($PHOP)" "not $PHOP"

# ---- 5. 재실행: 유지 -------------------------------------------------------------------------
( cd "$K" && ./install-hop.sh "${RUN[@]}" ) >"$T/ins2.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "rerun exits 0" || { bad "rerun exits 0" "rc=$rc"; tail -12 "$T/ins2.log" | sed 's/^/    /'; }
has "$T/ins2.log" "same or newer: kept" && pass "rerun keeps the app" || bad "rerun keeps the app" "log lacks 'same or newer: kept'"

# ---- 6. 구버전이 있으면 치우고 새로 설치 --------------------------------------------------------
# 실제 설치된 앱을 복사해 CFBundleShortVersionString 만 0.0.1 로 바꾼 가짜 구버전 앱을 만든다
# (plist 를 고치면 서명이 깨지지만, 인스톨러는 구버전을 옮길 때 서명을 보지 않으므로 시험엔 문제없다).
rm -rf "$T/fakeold"
cp -R "$T/apps/$APP" "$T/fakeold"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 0.0.1" "$T/fakeold/Contents/Info.plist"
rm -rf "$T/apps/$APP"
mv "$T/fakeold" "$T/apps/$APP"
( cd "$K" && ./install-hop.sh "${RUN[@]}" ) >"$T/ins3.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "older-version rerun exits 0" || { bad "older-version rerun exits 0" "rc=$rc"; tail -12 "$T/ins3.log" | sed 's/^/    /'; }
check "old app moved aside as HOP.old-0.0.1.app" test -d "$T/apps/HOP.old-0.0.1.app"
[ "$(defaults read "$T/apps/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)" = "$PHOP" ] \
    && pass "new app is $PHOP" || bad "new app is $PHOP" "not $PHOP"
check "new app verifies" codesign --verify --deep --strict "$T/apps/$APP"

# ---- 7. --dry-run 은 아무것도 만들지 않는다 ----------------------------------------------------
( cd "$K" && ./install-hop.sh --dry-run --app-dir="$T/apps2" --no-register ) >"$T/dry.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "dry-run exits 0" || bad "dry-run exits 0" "rc=$rc (log: $(tail -3 "$T/dry.log"))"
[ ! -e "$T/apps2" ] && pass "dry-run creates no app dir" || bad "dry-run creates no app dir" "$T/apps2 exists"
has "$T/dry.log" "[dry-run]" && pass "dry-run prints its actions" || bad "dry-run prints its actions" "no [dry-run] lines"

# ---- 8. tar 꾸러미 ----------------------------------------------------------------------------
# tar 까지 만들어 본다: sha256 이 맞는지, 아카이브가 담은 파일이 스테이지의 5개 파일과
# 정확히 같은지(디렉터리 항목은 제외하고)를 본다.
"$P" --out="$T/otar" --name=ttar >"$T/tar.out" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "pack (with tar) exits 0" || { bad "pack (with tar) exits 0" "rc=$rc"; sed 's/^/    /' "$T/tar.out" | tail -8; }
check "ttar.tar.gz exists" test -f "$T/otar/ttar.tar.gz"
check "ttar.tar.gz.sha256 exists" test -f "$T/otar/ttar.tar.gz.sha256"
( cd "$T/otar" && shasum -a 256 -c ttar.tar.gz.sha256 ) >/dev/null 2>&1 \
    && pass "ttar.tar.gz.sha256 -c" || bad "ttar.tar.gz.sha256 -c" "mismatch"
want_t="$T/want.tar.list"
( cd "$K" && find . -type f | LC_ALL=C sort | sed 's|^\./|ttar/|' ) >"$want_t"
/usr/bin/tar -tzf "$T/otar/ttar.tar.gz" | grep -v '/$' | LC_ALL=C sort >"$T/got.tar.list"
cmp -s "$want_t" "$T/got.tar.list" && pass "tarball holds exactly the staged files" \
    || bad "tarball holds exactly the staged files" "$(diff "$want_t" "$T/got.tar.list" | head -4)"

# ---- 9. 깨진 번들: 버전을 읽을 수 없는 HOP.app ---------------------------------------------------
# Info.plist 없이 Contents 만 들어 있는 HOP.app → unknown 으로 옮겨 두고 새 앱을 제자리에
# 놓아야 한다. 옛 버그(새 앱이 옛 디렉터리 안으로 들어가 HOP.app/HOP.app 이 생김)도 본다.
mkdir -p "$T/apps3/$APP/Contents"
( cd "$K" && ./install-hop.sh --app-dir="$T/apps3" --no-register ) >"$T/ins4.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "damaged-bundle install exits 0" || { bad "damaged-bundle install exits 0" "rc=$rc"; tail -12 "$T/ins4.log" | sed 's/^/    /'; }
check "damaged bundle moved aside as HOP.old-unknown.app" test -d "$T/apps3/HOP.old-unknown.app"
[ ! -e "$T/apps3/$APP/$APP" ] && pass "no nested $APP/$APP" || bad "no nested $APP/$APP" "$T/apps3/$APP/$APP exists"
[ "$(defaults read "$T/apps3/$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)" = "$PHOP" ] \
    && pass "damaged-bundle new app is $PHOP" || bad "damaged-bundle new app is $PHOP" "not $PHOP"
check "damaged-bundle new app verifies" codesign --verify --deep --strict "$T/apps3/$APP"

# ---- 10. 남의 번들: 번들 ID 가 다른 HOP.app ----------------------------------------------------
# 설치된 앱을 복사해 CFBundleIdentifier 만 com.example.other 로 바꾼다(버전은 $PHOP 그대로).
# 버전이 같아도 번들 ID 가 다르면 그대로 두지 않고 옮겨 두고 새로 놓아야 한다.
mkdir -p "$T/apps4"
cp -R "$T/apps/$APP" "$T/apps4/$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.other" "$T/apps4/$APP/Contents/Info.plist"
( cd "$K" && ./install-hop.sh --app-dir="$T/apps4" --no-register ) >"$T/ins5.log" 2>&1; rc=$?
[ $rc -eq 0 ] && pass "foreign-bundle install exits 0" || { bad "foreign-bundle install exits 0" "rc=$rc"; tail -12 "$T/ins5.log" | sed 's/^/    /'; }
check "foreign bundle moved aside as HOP.old-$PHOP.app" test -d "$T/apps4/HOP.old-$PHOP.app"
[ "$(defaults read "$T/apps4/$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$PBID" ] \
    && pass "foreign-bundle new app has bundle id $PBID" || bad "foreign-bundle new app has bundle id $PBID" "not $PBID"
check "foreign-bundle new app verifies" codesign --verify --deep --strict "$T/apps4/$APP"

echo
echo "elapsed: ${SECONDS}s"
if [ $fail -eq 0 ]; then echo "ACCEPT PASS"; exit 0; else echo "ACCEPT FAIL"; exit 1; fi
