#!/usr/bin/env bash
# ==============================================================================
# VS Code app + Foam + Claude Code extension → one offline add-on (run on the build Mac)
#
# For a site Mac that already has the wiki (~/llm-wiki/wiki) and usually the Claude Code kit,
# but no internet and no VS Code. The add-on carries only what those need to work offline:
#   <name>/app/VSCode-darwin-arm64.dmg                        the app (seal + team checked here)
#   <name>/extensions/foam.foam-vscode-<ver>.vsix             Foam, for the wiki's [[id]] links
#   <name>/extensions/Anthropic.claude-code-<ver>-darwin-arm64.vsix  the Claude Code extension
#   <name>/install-vscode.sh  README.md  wiki-workspace/  MANIFEST.env  SHA256SUMS
#   <name>.tar.gz + .sha256  what travels to the site Mac
# Nothing is downloaded here: the three vendor files come from --vendor and must match the pins
# below byte for byte.
#
# Usage:  guardian/pack-vscode-addon.sh [--vendor=DIR] [--out=DIR] [--name=NAME] [--no-tar]
#   --vendor=DIR  the three vendor files (default <repo>/dist/vendor/vscode)
#   --out=DIR     output folder (default <repo>/dist/vscode-addon)
#   --name=NAME   output name (default vscode-addon-<vscode ver>-cc<claude ver>-<UTC yyyymmddTHHMMZ>-macos-arm64;
#                 letters, digits, . _ - only)
#   --no-tar      stop after the folder (with SHA256SUMS); no .tar.gz is written
# On the site Mac:  shasum -a 256 -c <name>.tar.gz.sha256 && tar xzf <name>.tar.gz && cd <name> \
#   && shasum -a 256 -c SHA256SUMS && ./install-vscode.sh --dry-run
# ==============================================================================

set -euo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/.." && pwd)"

# ---- pins: what this build ships -------------------------------------------------------------
# To move to a newer VS Code / Foam / extension: download the three files into dist/vendor/vscode/,
# update the six version+sha256 values here (and the file names are derived from the versions),
# and run guardian/tests/accept_vscode_addon.sh.
#   VS Code:  https://update.code.visualstudio.com/<ver>/darwin-arm64-dmg/stable
#   Foam:     https://open-vsx.org/api/foam/foam-vscode/<ver>/file/foam.foam-vscode-<ver>.vsix
#   Claude:   https://open-vsx.org/api/Anthropic/claude-code/darwin-arm64/<ver>/file/Anthropic.claude-code-<ver>@darwin-arm64.vsix
VSCODE_VERSION="1.146.0"
VSCODE_DMG_SHA256="0312d0f42f4d55ce872c9afcb64f182b70fa74c82d10b91c98ed22c12d992a63"
FOAM_VERSION="0.48.0"
FOAM_VSIX_SHA256="1d93d6aeb9f230918be4f92a08130cabef360982ee000192ba8238db4f11a5cf"
CLAUDE_EXT_VERSION="2.1.325"
CLAUDE_VSIX_SHA256="0616d6fd5556934be98e9d684de4a7207df9d89d6e79d00287cfe37c398f0ee2"
VSCODE_TEAM="UBF8T346G9"   # com.microsoft.VSCode is sealed by Microsoft
CLAUDE_TEAM="Q6L2SF6YDW"   # the extension's native claude binary is sealed by Anthropic
VSCODE_DMG="VSCode-darwin-arm64.dmg"
FOAM_VSIX="foam.foam-vscode-${FOAM_VERSION}.vsix"
CLAUDE_VSIX="Anthropic.claude-code-${CLAUDE_EXT_VERSION}-darwin-arm64.vsix"
BUILT="$(date -u +%Y%m%dT%H%MZ)"

VENDOR=""
OUT=""
NAME=""
NAME_SET=0
DO_TAR=1

usage() { sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
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
[ -n "${NAME}" ] || NAME="vscode-addon-${VSCODE_VERSION}-cc${CLAUDE_EXT_VERSION}-${BUILT}-macos-arm64"
valid_name "${NAME}" || die "the default name is not a safe file name: ${NAME}"

# ---- 1. the vendor files must be exactly the pinned ones -------------------------------------
VENDOR="${VENDOR:-${SRC}/dist/vendor/vscode}"
[ -d "${VENDOR}" ] || die "vendor dir ${VENDOR} is missing: pass --vendor=DIR"
sha_matches() { [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]; }
for f in "${VSCODE_DMG}:${VSCODE_DMG_SHA256}" "${FOAM_VSIX}:${FOAM_VSIX_SHA256}" "${CLAUDE_VSIX}:${CLAUDE_VSIX_SHA256}"; do
    file="${VENDOR}/${f%%:*}"
    [ -f "${file}" ] || die "${file} is missing in ${VENDOR}"
    sha_matches "${file}" "${f#*:}" || die "${file} is not the pinned sha256 ${f#*:}"
done

# ---- 2. the dmg: mounted read-only and checked; the stapler result is only reported -----------
V_MNT=""
V_TMP="$(mktemp -d "${TMPDIR:-/tmp}/vscode-pack.XXXXXX")"
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

log "checking the app inside ${VSCODE_DMG}"
out="$(hdiutil attach -readonly -nobrowse -noautoopen -mountrandom "${V_TMP}" "${VENDOR}/${VSCODE_DMG}")" \
    || die "cannot mount ${VENDOR}/${VSCODE_DMG}"
V_MNT="$(printf '%s\n' "${out}" | tail -1 | awk '{print $NF}')"
APP="Visual Studio Code.app"
[ -d "${V_MNT}/${APP}" ] || die "${VSCODE_DMG} has no ${APP}"
ver="$(defaults read "${V_MNT}/${APP}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
[ "${ver}" = "${VSCODE_VERSION}" ] || die "the app in the dmg is ${ver:-unknown}, the pin says ${VSCODE_VERSION}"
bid="$(defaults read "${V_MNT}/${APP}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
[ "${bid}" = "com.microsoft.VSCode" ] || die "the app in the dmg is ${bid:-unknown}, not com.microsoft.VSCode"
codesign --verify --deep --strict "${V_MNT}/${APP}" || die "the app inside the dmg does not verify"
# Captured, never piped into a short-exit grep: under set -o pipefail that race fails a good signature.
CS_INFO="$(codesign -dv --verbose=2 "${V_MNT}/${APP}" 2>&1)" || die "cannot read the signature of the app inside the dmg"
grep -qx "TeamIdentifier=${VSCODE_TEAM}" <<<"${CS_INFO}" || die "the app inside the dmg is not signed by team ${VSCODE_TEAM}"
# The dmg is notarized but not stapled, and that is fine: report only, do not fail the build.
st="$(xcrun stapler validate "${V_MNT}/${APP}" 2>&1)" && st_rc=0 || st_rc=$?
if [ "${st_rc}" = 0 ]; then
    log "stapler: the app carries a valid stapled ticket"
else
    st_first="$(printf '%s\n' "${st}" | head -1)"
    log "stapler: not stapled — allowed for VS Code: install-vscode.sh checks the seal and team, then clears quarantine on this app only"
    [ -z "${st_first}" ] || echo "    stapler said: ${st_first}"
fi
detach_vendor
V_MNT=""
rm -rf "${V_TMP:?}"; V_TMP=""

# ---- 3. the two vsix files -------------------------------------------------------------------
# package.json of each vsix, parsed with plutil from stdin (no python, no jq on a stock Mac).
vsix_field() {  # $1 = vsix, $2 = key
    local pkg
    pkg="$(unzip -p "$1" extension/package.json)" || die "cannot read extension/package.json in $1"
    printf '%s' "${pkg}" | plutil -extract "$2" raw - || die "no $2 in extension/package.json of $1"
}
log "checking the two vsix files"
[ "$(vsix_field "${VENDOR}/${FOAM_VSIX}" publisher)" = "foam" ] || die "${FOAM_VSIX} is not published by foam"
[ "$(vsix_field "${VENDOR}/${FOAM_VSIX}" name)" = "foam-vscode" ] || die "${FOAM_VSIX} is not foam-vscode"
[ "$(vsix_field "${VENDOR}/${FOAM_VSIX}" version)" = "${FOAM_VERSION}" ] || die "${FOAM_VSIX} is not version ${FOAM_VERSION}"
[ "$(vsix_field "${VENDOR}/${CLAUDE_VSIX}" publisher)" = "Anthropic" ] || die "${CLAUDE_VSIX} is not published by Anthropic"
[ "$(vsix_field "${VENDOR}/${CLAUDE_VSIX}" name)" = "claude-code" ] || die "${CLAUDE_VSIX} is not claude-code"
[ "$(vsix_field "${VENDOR}/${CLAUDE_VSIX}" version)" = "${CLAUDE_EXT_VERSION}" ] || die "${CLAUDE_VSIX} is not version ${CLAUDE_EXT_VERSION}"
names="$(unzip -Z1 "${VENDOR}/${CLAUDE_VSIX}")" || die "cannot list ${CLAUDE_VSIX}"
hits="$(printf '%s\n' "${names}" | grep -x 'extension/resources/native-binary/claude' || true)"
[ -n "${hits}" ] || die "${CLAUDE_VSIX} has no extension/resources/native-binary/claude"

# ---- 4. the add-on's own files must all be here ----------------------------------------------
ADDON="${HERE}/vscode-addon"
for f in "install-vscode.sh" "README.md" "wiki-workspace/.vscode/settings.json" \
    "wiki-workspace/.foam/templates/new-note.md"; do
    [ -f "${ADDON}/${f}" ] || die "${ADDON}/${f} is missing"
done

# ---- 5. stage ------------------------------------------------------------------------------
OUT="${OUT:-${SRC}/dist/vscode-addon}"
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
mkdir "${PARTIAL}/app" "${PARTIAL}/extensions"
cp "${VENDOR}/${VSCODE_DMG}" "${PARTIAL}/app/"
cp "${VENDOR}/${FOAM_VSIX}" "${VENDOR}/${CLAUDE_VSIX}" "${PARTIAL}/extensions/"
cp "${ADDON}/install-vscode.sh" "${PARTIAL}/install-vscode.sh"
chmod 755 "${PARTIAL}/install-vscode.sh"
cp "${ADDON}/README.md" "${PARTIAL}/README.md"
rsync -a --exclude='.DS_Store' "${ADDON}/wiki-workspace" "${PARTIAL}/"
stray="$(find "${PARTIAL}" -name '.DS_Store' -print)"
[ -z "${stray}" ] || die "a .DS_Store ended up in the add-on"
cat >"${PARTIAL}/MANIFEST.env" <<EOF
vscode_version=${VSCODE_VERSION}
vscode_team=${VSCODE_TEAM}
foam_version=${FOAM_VERSION}
claude_code_ext_version=${CLAUDE_EXT_VERSION}
claude_team=${CLAUDE_TEAM}
built_utc=${BUILT}
app_dmg=app/${VSCODE_DMG}
foam_vsix=extensions/${FOAM_VSIX}
claude_vsix=extensions/${CLAUDE_VSIX}
EOF
# Every file, relative paths, sorted, SHA256SUMS itself excluded.
(cd "${PARTIAL}" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
(cd "${PARTIAL}" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "SHA256SUMS does not match the staged files"
mv "${PARTIAL}" "${KIT}"
PARTIAL=""
KIT_DIR="${KIT}"
log "add-on folder done: $(du -sh "${KIT}" | awk '{print $1}') in ${OUT}"

# ---- 6. archive -----------------------------------------------------------------------------
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
    echo "  shasum -a 256 -c ${NAME}.tar.gz.sha256 && tar xzf ${NAME}.tar.gz && cd ${NAME} && shasum -a 256 -c SHA256SUMS && ./install-vscode.sh --dry-run"
else
    log "done (--no-tar): the add-on folder ${KIT} is complete with its SHA256SUMS"
fi
