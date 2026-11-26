#!/usr/bin/env bash
# ==============================================================================
# HWP/HWPX 뷰어 HOP → 하나의 오프라인 꾸러미 (빌드 Mac 에서 실행)
#
# 인터넷 없는 현장 Mac 에 한글 문서(.hwp/.hwpx) 뷰어를 얹히는 소형 꾸러미. 실어 가는
# 것은 HOP 앱 하나뿐이고 여기서는 아무것도 내려받지 않는다: 벤더 dmg 는 --vendor 에서
# 오며, 아래 핀과 byte 단위로 같은지 dmg 안의 앱 봉인이 유효한지 여기서 확인한다.
#   <name>/app/HOP-macos-arm64.dmg   the app (version + bundle id + seal + team + stapled ticket checked here)
#   <name>/install-hop.sh  README.md  MANIFEST.env  SHA256SUMS
#   <name>.tar.gz + .sha256  what travels to the site Mac
#
# Usage:  guardian/pack-hop-viewer.sh [--vendor=DIR] [--out=DIR] [--name=NAME] [--no-tar]
#   --vendor=DIR  the vendor dmg (default <repo>/dist/vendor/hop)
#   --out=DIR     output folder (default <repo>/dist/hop-viewer)
#   --name=NAME   output name (default hop-viewer-<hop version>; letters, digits, . _ - only)
#   --no-tar      stop after the folder (with SHA256SUMS); no .tar.gz is written
# On the site Mac:  shasum -a 256 -c <name>.tar.gz.sha256 && tar xzf <name>.tar.gz && cd <name> \
#   && shasum -a 256 -c SHA256SUMS && ./install-hop.sh --dry-run
# ==============================================================================

set -euo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/.." && pwd)"

# ---- 핀: 이 빌드가 실을 것 --------------------------------------------------------------------
# 새 HOP 로 옮기려면: dist/vendor/hop/HOP-macos-arm64.dmg 를 새 릴리스 파일로 바꾸고, 아래
# 네 값을 갱신한 뒤 guardian/tests/accept_hop_viewer.sh 를 돌린다.
#   HOP:  https://github.com/golbin/hop/releases/tag/v<ver>  →  HOP-macos-arm64.dmg (MIT)
HOP_VERSION="0.5.4"
HOP_DMG_SHA256="1ec5fb98f29ca37f12e43a171c791d0ba391b024741ecc72d4f8bd4f0f2991a4"
HOP_BUNDLE_ID="net.golbin.hop"
HOP_TEAM="CNP6UV7S33"   # Developer ID team; the dmg itself is not notarized, HOP.app inside is (stapled)
HOP_DMG="HOP-macos-arm64.dmg"
BUILT="$(date -u +%Y%m%dT%H%MZ)"

VENDOR=""
OUT=""
NAME=""
NAME_SET=0
DO_TAR=1

usage() { sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
for arg in "$@"; do
    case "${arg}" in
        --vendor=*)
            VENDOR="${arg#--vendor=}"
            [ -n "${VENDOR}" ] || { echo "error: --vendor= needs a directory" >&2; exit 2; } ;;
        --out=*)
            OUT="${arg#--out=}"
            [ -n "${OUT}" ] || { echo "error: --out= needs a directory" >&2; exit 2; } ;;
        --name=*) NAME="${arg#--name=}"; NAME_SET=1 ;;
        --no-tar) DO_TAR=0 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *) usage >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# Whole-string match (a line-based grep would pass a name holding a newline).
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
if [ "${NAME_SET}" = 1 ]; then
    # An explicitly empty --name= is refused, never quietly replaced by the default name.
    [ -n "${NAME}" ] || die "--name= must not be empty"
    valid_name "${NAME}" || die "--name must be letters, digits, . _ or - only: ${NAME}"
fi
[ -n "${NAME}" ] || NAME="hop-viewer-${HOP_VERSION}"
valid_name "${NAME}" || die "the default name is not a safe file name: ${NAME}"

# ---- 1. 벤더 파일은 정확히 핀된 것이어야 한다 -------------------------------------------------
VENDOR="${VENDOR:-${SRC}/dist/vendor/hop}"
[ -d "${VENDOR}" ] || die "vendor dir ${VENDOR} is missing: pass --vendor=DIR"
sha_matches() { [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]; }
[ -f "${VENDOR}/${HOP_DMG}" ] || die "${VENDOR}/${HOP_DMG} is missing"
sha_matches "${VENDOR}/${HOP_DMG}" "${HOP_DMG_SHA256}" \
    || die "${VENDOR}/${HOP_DMG} is not the pinned sha256 ${HOP_DMG_SHA256}"

# ---- 2. dmg: 읽기 전용으로 마운트해 검사; 스테이플 티켓도 여기서 필수로 확인한다 -----------------
V_MNT=""
V_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hop-pack.XXXXXX")"
detach_vendor() {
    if [ -n "${V_MNT}" ]; then
        hdiutil detach -quiet "${V_MNT}" 2>/dev/null || hdiutil detach -quiet -force "${V_MNT}" 2>/dev/null || true
    fi
}
PARTIAL=""
KIT_DIR=""
TAR_GZ=""
SHA_FILE=""
VERIFY_TMP=""
cleanup() {
    rc=$?
    detach_vendor
    [ -z "${VERIFY_TMP}" ] || rm -rf "${VERIFY_TMP:?}"
    [ -z "${V_TMP}" ] || rm -rf "${V_TMP:?}"
    if [ "${rc}" -ne 0 ]; then
        [ -z "${PARTIAL}" ] || rm -rf "${PARTIAL:?}"
        [ -z "${SHA_FILE}" ] || rm -f "${SHA_FILE:?}"
        [ -z "${TAR_GZ}" ] || rm -f "${TAR_GZ:?}"
        [ -z "${KIT_DIR}" ] || rm -rf "${KIT_DIR:?}"
    fi
}
trap cleanup EXIT

log "checking the app inside ${HOP_DMG}"
out="$(hdiutil attach -readonly -nobrowse -noautoopen -mountrandom "${V_TMP}" "${VENDOR}/${HOP_DMG}")" \
    || die "cannot mount ${VENDOR}/${HOP_DMG}"
# 마지막 줄은 "/dev/diskXsY<TAB>/Volumes/이름" 꼴: 탭을 구분자로 잘라야 빈칸이 든 이름도 온전하다.
V_MNT="$(printf '%s\n' "${out}" | tail -1 | awk -F'\t' '{print $NF}')"
APP="HOP.app"
[ -d "${V_MNT}/${APP}" ] || die "${HOP_DMG} has no ${APP}"
ver="$(defaults read "${V_MNT}/${APP}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
[ "${ver}" = "${HOP_VERSION}" ] || die "the app in the dmg is ${ver:-unknown}, the pin says ${HOP_VERSION}"
bid="$(defaults read "${V_MNT}/${APP}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
[ "${bid}" = "${HOP_BUNDLE_ID}" ] || die "the app in the dmg is ${bid:-unknown}, not ${HOP_BUNDLE_ID}"
codesign --verify --deep --strict "${V_MNT}/${APP}" || die "the app inside the dmg does not verify"
# Captured, never piped into a short-exit grep: under set -o pipefail that race fails a good signature.
CS_INFO="$(codesign -dv --verbose=2 "${V_MNT}/${APP}" 2>&1)" || die "cannot read the signature of the app inside the dmg"
grep -qx "TeamIdentifier=${HOP_TEAM}" <<<"${CS_INFO}" || die "the app inside the dmg is not signed by team ${HOP_TEAM}"
# The dmg is not notarized but the app inside must carry a stapled ticket: without one the offline
# site Mac cannot pass Gatekeeper on first launch, so a missing ticket fails the build here.
st="$(xcrun stapler validate "${V_MNT}/${APP}" 2>&1)" && st_rc=0 || st_rc=$?
if [ "${st_rc}" != 0 ]; then
    # 첫 줄만 붙인다(파이프+head 는 pipefail 아래에서 억울한 실패를 만들 수 있다).
    die "the app inside the dmg has no valid stapled notarization ticket: ${st%%$'\n'*}"
fi
log "stapler: the app carries a valid stapled ticket"
detach_vendor
V_MNT=""
rm -rf "${V_TMP:?}"; V_TMP=""

# ---- 3. 꾸러미 자체 파일이 모두 있어야 한다 ---------------------------------------------------
ADDON="${HERE}/hop-viewer"
for f in "install-hop.sh" "README.md"; do
    [ -f "${ADDON}/${f}" ] || die "${ADDON}/${f} is missing"
done

# ---- 4. 스테이지 ----------------------------------------------------------------------------
OUT="${OUT:-${SRC}/dist/hop-viewer}"
KIT="${OUT}/${NAME}"
for f in "${KIT}" "${KIT}.partial" "${KIT}.tar.gz" "${KIT}.tar.gz.sha256" \
    "${KIT}.tar.gz.partial" "${KIT}.tar.gz.sha256.partial"; do
    # -L as well as -e: a dangling symlink hides from -e, and creating through it would write
    # wherever the link points, outside --out.
    if [ -e "${f}" ] || [ -L "${f}" ]; then die "${f} already exists"; fi
done
mkdir -p "${OUT}" || die "cannot create ${OUT}"
OUT="$(cd "${OUT}" && pwd)"
KIT="${OUT}/${NAME}"

log "staging ${NAME}"
# Plain mkdir, no -p: a run that loses the race to a second run fails here, before PARTIAL is
# recorded, so its cleanup can never remove the other run's staging folder.
mkdir "${KIT}.partial" || die "cannot create ${KIT}.partial"
PARTIAL="${KIT}.partial"
mkdir "${PARTIAL}/app"
cp "${VENDOR}/${HOP_DMG}" "${PARTIAL}/app/"
cp "${ADDON}/install-hop.sh" "${PARTIAL}/install-hop.sh"
chmod 755 "${PARTIAL}/install-hop.sh"
cp "${ADDON}/README.md" "${PARTIAL}/README.md"
stray="$(find "${PARTIAL}" -name '.DS_Store' -print)"
[ -z "${stray}" ] || die "a .DS_Store ended up in the kit"
cat >"${PARTIAL}/MANIFEST.env" <<EOF
hop_version=${HOP_VERSION}
hop_bundle_id=${HOP_BUNDLE_ID}
hop_team=${HOP_TEAM}
app_dmg=app/${HOP_DMG}
license=MIT
source=https://github.com/golbin/hop/releases/tag/v${HOP_VERSION}
built_utc=${BUILT}
EOF
# Every file, relative paths, sorted, SHA256SUMS itself excluded.
(cd "${PARTIAL}" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
(cd "${PARTIAL}" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "SHA256SUMS does not match the staged files"
mv "${PARTIAL}" "${KIT}"
PARTIAL=""
KIT_DIR="${KIT}"
log "kit folder done: $(du -sh "${KIT}" | awk '{print $1}') in ${OUT}"

# ---- 5. 아카이브 ------------------------------------------------------------------------------
if [ "${DO_TAR}" = 1 ]; then
    log "archive ${NAME}.tar.gz"
    TARB="${KIT}.tar.gz.partial"
    [ ! -e "${TARB}" ] || die "${TARB} already exists"
    PARTIAL="${TARB}"
    COPYFILE_DISABLE=1 /usr/bin/tar -C "${OUT}" -czf "${TARB}" "${NAME}"
    want="$(cd "${OUT}" && find "${NAME}" | wc -l | tr -d ' ')"
    got="$(/usr/bin/tar -tzf "${TARB}" | wc -l | tr -d ' ')"
    [ "${got}" = "${want}" ] || die "the archive lists ${got} entries, the folder has ${want}"
    # Prove what a clean Mac would unpack: extract into a fresh folder and verify SHA256SUMS there.
    VERIFY_TMP="$(mktemp -d "${OUT}/.verify.XXXXXX")"
    /usr/bin/tar -xzf "${TARB}" -C "${VERIFY_TMP}"
    (cd "${VERIFY_TMP}/${NAME}" && shasum -a 256 -c SHA256SUMS >/dev/null) \
        || die "the archive's SHA256SUMS does not verify when unpacked"
    listed="$(cd "${VERIFY_TMP}/${NAME}" && sed 's/^[0-9a-f]*  //' SHA256SUMS | LC_ALL=C sort)"
    packed="$(cd "${VERIFY_TMP}/${NAME}" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort)"
    [ "${packed}" = "${listed}" ] || die "the archive holds files SHA256SUMS does not list"
    rm -rf "${VERIFY_TMP:?}"
    VERIFY_TMP=""
    mv "${TARB}" "${KIT}.tar.gz"
    PARTIAL=""
    TAR_GZ="${KIT}.tar.gz"
    PARTIAL="${KIT}.tar.gz.sha256.partial"
    (cd "${OUT}" && shasum -a 256 "${NAME}.tar.gz" >"${NAME}.tar.gz.sha256.partial")
    mv "${KIT}.tar.gz.sha256.partial" "${KIT}.tar.gz.sha256"
    PARTIAL=""
    SHA_FILE="${KIT}.tar.gz.sha256"
    log "done: ${KIT}.tar.gz ($(ls -lh "${KIT}.tar.gz" | awk '{print $5}'))"
    echo "    sha256 $(awk '{print $1}' "${KIT}.tar.gz.sha256")"
    echo "Then on the site Mac:"
    echo "  shasum -a 256 -c ${NAME}.tar.gz.sha256 && tar xzf ${NAME}.tar.gz && cd ${NAME} && shasum -a 256 -c SHA256SUMS && ./install-hop.sh --dry-run"
else
    log "done (--no-tar): the kit folder ${KIT} is complete with its SHA256SUMS"
fi
