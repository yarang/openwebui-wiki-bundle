#!/bin/bash
# ==============================================================================
# HOP 뷰어 키트 설치 스크립트 (추출한 꾸러미 폴더 안에서 현장 Mac 에 실행; 그 Mac 은
# 인터넷이 없다. 실어 주는 것은 .hwp/.hwpx 뷰어 HOP 앱 하나뿐이다.)
#
# Steps: 0 SHA256SUMS + MANIFEST  1 기기 요건 (arm64, macOS 12+)  2 HOP 앱 설치
#        3 LaunchServices 등록  4 요약.
#
# Usage:  ./install-hop.sh [options]
#   --dry-run      print every action, change nothing
#   --app-dir=DIR  where the app goes (default /Applications; tests use a temp dir)
#   --no-register  skip step 3 (the LaunchServices registration)
# Undo: 먼저 lsregister -u "/Applications/HOP.app" 로 등록을 풀고, 그다음 HOP.app 을 휴지통으로.
# ==============================================================================

set -euo pipefail
# CDPATH 가 있으면 아래 "cd … && pwd" 가 뜻밖의 경로로 가고, 그 경로를 stdout 에 찍는다.
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY=0
APP_DIR="/Applications"
DO_REGISTER=1

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY=1 ;;
        --app-dir=*)
            APP_DIR="${arg#--app-dir=}"
            [ -n "${APP_DIR}" ] || { echo "error: --app-dir= needs a directory" >&2; exit 2; } ;;
        --no-register) DO_REGISTER=0 ;;
        -h|--help) sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: ${arg}" >&2; exit 2 ;;
        *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
note() { echo "    $*"; }
step() { echo; echo "▶ $*"; }
run() {
    if [ "${DRY}" = 1 ]; then note "[dry-run] $*"; else "$@"; fi
}
# guardian/install-all.sh 과 같은 비교: 숫자 부분만 보므로 0.5.4 vs 0.10.0 도 정확하다.
version_ge() {
    local a b i x y
    a="$(printf '%s' "$1" | sed 's/[^0-9.].*//')"
    b="$(printf '%s' "$2" | sed 's/[^0-9.].*//')"
    local IFS=.
    # shellcheck disable=SC2206
    local -a av=(${a}) bv=(${b})
    for i in 0 1 2 3; do
        x="${av[i]:-0}"; y="${bv[i]:-0}"
        if [ "$((10#${x}))" -gt "$((10#${y}))" ]; then return 0; fi
        if [ "$((10#${x}))" -lt "$((10#${y}))" ]; then return 1; fi
    done
    return 0
}
manifest() { sed -n "s/^$1=//p" "${HERE}/MANIFEST.env" | head -1; }

APP_NAME="HOP.app"
MIN_MACOS="12.0"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 마운트된 이미지나 반쯤 복사된 스테이징 앱을 절대 남기지 않는다 (install-vscode.sh 과 같은 방어).
DMG_MNT=""
MNT_ROOT=""
STAGE=""
cleanup() {
    rc=$?
    if [ -n "${DMG_MNT}" ]; then
        hdiutil detach -quiet "${DMG_MNT}" 2>/dev/null || hdiutil detach -quiet -force "${DMG_MNT}" 2>/dev/null \
            || echo "warning: ${DMG_MNT} is still attached" >&2
    fi
    [ -z "${MNT_ROOT}" ] || rm -rf "${MNT_ROOT:?}"
    [ -z "${STAGE}" ] || rm -rf "${STAGE:?}"
    return "${rc}"
}
trap cleanup EXIT

# ---- 0. 꾸러미 무결성 ------------------------------------------------------------------------
step "0/4 kit integrity (SHA256SUMS, MANIFEST.env)"
[ -f "${HERE}/SHA256SUMS" ] || die "SHA256SUMS is missing next to this script"
[ -f "${HERE}/MANIFEST.env" ] || die "MANIFEST.env is missing next to this script"
if ! (cd "${HERE}" && shasum -a 256 -c SHA256SUMS >/dev/null); then
    die "SHA256SUMS does not match the kit files: copy the kit folder again"
fi
note "SHA256SUMS ok"
for k in hop_version hop_bundle_id hop_team app_dmg; do
    [ -n "$(manifest "${k}")" ] || die "MANIFEST.env has no ${k}"
done
HOP_VER="$(manifest hop_version)"
HOP_BID="$(manifest hop_bundle_id)"
HOP_TEAM="$(manifest hop_team)"
APP_DMG="$(manifest app_dmg)"

# ---- 1. 기기 요건 ----------------------------------------------------------------------------
step "1/4 this Mac can run HOP (arm64, macOS ${MIN_MACOS}+)"
[ "$(uname -m)" = "arm64" ] || die "HOP is arm64 only: this Mac reports $(uname -m)"
macos="$(sw_vers -productVersion 2>/dev/null || true)"
[ -n "${macos}" ] || die "cannot read the macOS version with sw_vers"
version_ge "${macos}" "${MIN_MACOS}" || die "HOP needs macOS ${MIN_MACOS} or newer: this Mac reports ${macos}"
note "ok: $(uname -m), macOS ${macos}"

# ---- 2. HOP 앱 -------------------------------------------------------------------------------
APP_RESULT="skipped"

# dmg 를 읽기 전용으로 마운트해 매니페스트와 대조하고, ditto 로 $2 아래 스테이징 폴더에 복사한
# 뒤, 그 앱만 quarantine 를 지우고 봉인을 다시 확인한다.
copy_app_from_dmg() {
    local dmg="$1" dest="$2" out mnt app ver bid cs
    MNT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/hop-dmg.XXXXXX")"
    out="$(hdiutil attach -readonly -nobrowse -noautoopen -mountrandom "${MNT_ROOT}" "${dmg}")" \
        || die "cannot mount ${dmg}"
    # 마지막 줄은 "/dev/diskXsY<TAB>/Volumes/이름" 꼴: 탭을 구분자로 잘라야 빈칸이 든 이름도 온전하다.
    mnt="$(printf '%s\n' "${out}" | tail -1 | awk -F'\t' '{print $NF}')"
    DMG_MNT="${mnt}"
    [ -d "${mnt}/${APP_NAME}" ] || die "${dmg} has no ${APP_NAME}"
    app="${mnt}/${APP_NAME}"
    ver="$(defaults read "${app}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
    [ "${ver}" = "${HOP_VER}" ] || die "the app in the dmg is ${ver:-unknown}, the manifest says ${HOP_VER}"
    bid="$(defaults read "${app}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
    [ "${bid}" = "${HOP_BID}" ] || die "the app in the dmg is ${bid:-unknown}, not ${HOP_BID}"
    codesign --verify --deep --strict "${app}" || die "the app inside ${dmg} does not verify"
    # Captured, never piped into a short-exit grep: under set -o pipefail that race fails a good signature.
    cs="$(codesign -dv --verbose=2 "${app}" 2>&1)" || die "cannot read the signature of the app inside ${dmg}"
    grep -qx "TeamIdentifier=${HOP_TEAM}" <<<"${cs}" || die "the app inside ${dmg} is not signed by team ${HOP_TEAM}"
    # Copied next to its final place first, so an interrupted copy never sits where the version check looks.
    STAGE="$(mktemp -d "${dest}/.hop-install.XXXXXX")"
    ditto "${app}" "${STAGE}/${APP_NAME}"
    hdiutil detach -quiet "${DMG_MNT}" 2>/dev/null || hdiutil detach -quiet -force "${DMG_MNT}" 2>/dev/null || true
    DMG_MNT=""
    rm -rf "${MNT_ROOT:?}"; MNT_ROOT=""
    # A dmg carried in by USB is quarantined, and so is what ditto takes out of it — this app only.
    xattr -dr com.apple.quarantine "${STAGE}/${APP_NAME}"
    codesign --verify --deep --strict "${STAGE}/${APP_NAME}" || die "the copied app does not verify"
}

install_app() {
    local dmg="${HERE}/${APP_DMG}" exists=0 cur="" bid="" keep=0 running old
    step "2/4 HOP ${HOP_VER} app → ${APP_DIR}"
    [ -f "${dmg}" ] || die "${dmg} is missing"
    if [ -d "${APP_DIR}" ]; then
        # dry-run 은 쓸 수 없는 폴더를 경고만 하고 계속 간다; 실제 실행은 그대로 멈춘다.
        if [ ! -w "${APP_DIR}" ]; then
            if [ "${DRY}" = 1 ]; then
                warn "\"${APP_DIR}\" is not writable: a real run would stop here (pass --app-dir=DIR with a folder you can write to)"
            else
                die "\"${APP_DIR}\" is not writable: pass --app-dir=DIR with a folder you can write to (this installer never uses sudo)"
            fi
        fi
    else
        run mkdir -p "${APP_DIR}" || die "cannot create ${APP_DIR}"
    fi
    # 디렉터리가 있음이 확실하면 절대 경로로 정규화한다 (dry-run 은 이미 있을 때만).
    # 아래 pgrep 패턴과 옮겨 두는 이름이 상대 경로 때문에 어긋나지 않게 한다.
    if [ -d "${APP_DIR}" ]; then
        APP_DIR="$(cd "${APP_DIR}" && pwd)"
    fi
    if [ -e "${APP_DIR}/${APP_NAME}" ] || [ -L "${APP_DIR}/${APP_NAME}" ]; then
        exists=1
        cur="$(defaults read "${APP_DIR}/${APP_NAME}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
        bid="$(defaults read "${APP_DIR}/${APP_NAME}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
        # 우리 번들이고 버전을 읽었고 그 버전이 같거나 더 새울 때만 그대로 둔다. 버전을 못
        # 읽는 깨진 번들이나 번들 ID 가 다른 HOP.app 은 무조건 옮겨 두고 새로 놓는다.
        if [ "${bid}" = "${HOP_BID}" ] && [ -n "${cur}" ] && version_ge "${cur}" "${HOP_VER}"; then
            keep=1
        fi
    fi
    if [ "${keep}" = 1 ]; then
        note "installed ${cur} is the same or newer: kept"
        APP_RESULT="kept installed ${cur} in ${APP_DIR}"
        return 0
    fi
    if [ "${exists}" = 1 ]; then
        # 옮겨 둘 예정인 앱이 실행 중이면 거부한다 (dry-run 일 때도 같은 조건으로 거부한다).
        running="$(pgrep -f "${APP_DIR}/${APP_NAME}/Contents/MacOS/" 2>/dev/null || true)"
        [ -z "${running}" ] || die "HOP ${cur:-unknown} is running: quit HOP first"
    fi
    if [ "${DRY}" = 1 ]; then
        [ "${exists}" = 0 ] || note "[dry-run] mv \"${APP_DIR}/${APP_NAME}\" aside as \"${APP_NAME%.app}.old-${cur:-unknown}.app\""
        note "[dry-run] mount ${dmg}, check version/bundle id/seal/team, ditto ${APP_NAME} into \"${APP_DIR}\", clear quarantine, move it into place"
        APP_RESULT="would install ${HOP_VER} into ${APP_DIR}"
        return 0
    fi
    copy_app_from_dmg "${dmg}" "${APP_DIR}"
    if [ "${exists}" = 1 ]; then
        old="${APP_DIR}/${APP_NAME%.app}.old-${cur:-unknown}.app"
        if [ -e "${old}" ] || [ -L "${old}" ]; then old="${APP_DIR}/${APP_NAME%.app}.old-${cur:-unknown}-$(date +%Y%m%d%H%M%S).app"; fi
        mv "${APP_DIR}/${APP_NAME}" "${old}"
        [ "${bid}" = "${HOP_BID}" ] || note "the existing ${APP_NAME} is not ${HOP_BID}: moved aside"
        note "the ${cur:+older }${cur:-unknown} was moved aside: ${old}"
        if [ "${DO_REGISTER}" = 1 ]; then
            # LaunchServices 가 옮겨진 옛 앱을 잊게 한다; 실패해도 설치 자체에는 상관없다.
            "${LSREGISTER}" -u "${old}" >/dev/null 2>&1 || true
        fi
    fi
    mv "${STAGE}/${APP_NAME}" "${APP_DIR}/${APP_NAME}"
    # ditto 가 스테이징 폴더에 잔여물을 남길 수 있으므로 rmdir 대신 지운다; ":?" 로 빈 값 방어.
    rm -rf "${STAGE:?}"; STAGE=""
    note "installed ${HOP_VER} to ${APP_DIR}"
    APP_RESULT="installed ${HOP_VER} to ${APP_DIR}"
}

# ---- 3. LaunchServices 등록 ------------------------------------------------------------------
REG_RESULT="skipped (--no-register)"

do_register() {
    step "3/4 LaunchServices registration"
    if [ "${DO_REGISTER}" = 0 ]; then
        note "skipped: --no-register"
        return 0
    fi
    if [ "${DRY}" = 1 ]; then
        note "[dry-run] ${LSREGISTER} -f \"${APP_DIR}/${APP_NAME}\""
        REG_RESULT="would register ${APP_DIR}/${APP_NAME} with LaunchServices"
        return 0
    fi
    # HOP은 .hwp/.hwpx 를 LSHandlerRank Owner 로 등록한다. lsregister -f 로 Finder 가 앱을
    # 바로 알게끔 한다; 실패해도 경고만 한다 — 앱은 이미 제자리에 있다.
    if "${LSREGISTER}" -f "${APP_DIR}/${APP_NAME}"; then
        note "registered: Finder sees HOP at once, no first manual open needed"
        REG_RESULT="registered ${APP_DIR}/${APP_NAME}"
    else
        warn "lsregister -f failed: open HOP once by hand, then Finder lists it in \"Open With\""
        REG_RESULT="WARNING: lsregister -f failed"
    fi
}

# ---- 4. 요약 ---------------------------------------------------------------------------------
summary() {
    step "4/4 summary"
    note "app:      ${APP_RESULT}"
    note "register: ${REG_RESULT}"
    note "viewer:   HOP ${HOP_VER} (MIT, github.com/golbin/hop)"
    echo
    note "다음부터 .hwp/.hwpx 파일이 HOP으로 열릴 수 있다; Finder 스페이스바 미리보기와 썸네일도 HOP이 그린다"
    note "기본 앱을 되돌리려면: Finder 에서 .hwp 파일 하나 선택 → 정보 가져오기(Cmd+I) → \"다음으로 열기\" 에서 앱 고르고 \"모두 변경\""
    note "HOP은 시작할 때 업데이트를 한 번 확인한다: 오프라인이면 로그만 남기고 조용히 실패하며, 업데이트는 사람이 눌러야만 설치된다"
}

if [ "${DRY}" = 1 ]; then echo "HOP viewer kit installer — dry run (nothing is changed)"; fi
install_app
do_register
summary
