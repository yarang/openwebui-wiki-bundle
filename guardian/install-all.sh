#!/usr/bin/env bash
# ==============================================================================
# LLM + wiki bundle installer: guardian install.sh, LM Studio from its dmg, wiki-layer/install-wiki.sh, then
# claude-code/install-claude-code.sh
#
# The guardian step installs LM Studio's runtimes and models, Python 3.12 and Open WebUI (~/.guardian-llm). The app
# step copies LM Studio.app out of the official dmg in app/ into /Applications (~/Applications when that is not
# writable), as dragging it there would, with the guardian installer's rules: a same or newer installed version is
# kept, an older one is replaced only with --upgrade-app and LM Studio closed, and is renamed, never deleted. The wiki
# step adds wiki-mcp, mcpo and the watch service, and restarts everything. The Claude Code step installs claude and
# claude-lms (Claude Code on LM Studio, set to the wiki's model) in ~/.local/bin. The guardian installer always runs
# with --no-start because it rewrites the Open WebUI LaunchAgent that the wiki step then extends.
#
# Usage:  ./install-all.sh [options]
#   all:     --dry-run  --no-start  --prefix=DIR  --embedding-model=M
#   app:     --no-app  --upgrade-app
#   guardian: --no-models  --skip-verify  --port=N  --lmstudio-url=URL
#   wiki:    --wiki-home=DIR  --mcpo-port=N  --webui-host=H  --migrate-from=OLD_BUNDLE
#   claude:  --no-claude-code
# See ./install.sh --help, wiki-layer/install-wiki.sh --help and claude-code/install-claude-code.sh --help.
# Start with --dry-run. Moving data from an old openwebui-wiki bundle: stop its processes, then
#   ./install-all.sh --migrate-from="$HOME"/Desktop/project/openwebui-wiki-bundle-0.10.2-macos-arm64
# ==============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G_ARGS=(--no-start)
W_ARGS=()
C_ARGS=()
DO_CLAUDE=1
DRY=0
DO_APP=1
UPGRADE_APP=0

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY=1; G_ARGS+=("${arg}"); W_ARGS+=("${arg}"); C_ARGS+=("${arg}") ;;
        --prefix=*|--embedding-model=*) G_ARGS+=("${arg}"); W_ARGS+=("${arg}") ;;
        --no-start) W_ARGS+=("${arg}") ;;
        --no-app) DO_APP=0; G_ARGS+=("${arg}") ;;
        --upgrade-app) UPGRADE_APP=1; G_ARGS+=("${arg}") ;;
        --lmstudio-url=*) G_ARGS+=("${arg}"); C_ARGS+=("${arg}") ;;
        --no-models|--skip-verify|--port=*) G_ARGS+=("${arg}") ;;
        --no-claude-code) DO_CLAUDE=0 ;;
        --wiki-home=*|--mcpo-port=*|--webui-host=*|--migrate-from=*) W_ARGS+=("${arg}") ;;
        --no-openwebui) echo "error: the wiki layer runs inside the Open WebUI venv; --no-openwebui is not supported here" >&2; exit 2 ;;
        -h|--help) sed -n '3,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
note() { echo "    $*"; }
manifest() { sed -n "s/^$1=//p" "${HERE}/MANIFEST.env" | head -1; }
APP_NAME="$(manifest app_name)"
APP_VERSION="$(manifest app_version)"
APP_DMG="$(manifest app_dmg)"

# Same comparison as install.sh: the numeric part only, so 0.4.26+4 is 0.4.26.
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

DMG_MNT=""
STAGE=""
# An image still attached would be left mounted; a half-copied app is never moved into place.
cleanup() {
    if [ -n "${DMG_MNT}" ]; then
        hdiutil detach -quiet "${DMG_MNT}" || hdiutil detach -quiet -force "${DMG_MNT}" \
            || echo "warning: ${DMG_MNT} is still attached" >&2
    fi
    if [ -n "${STAGE}" ]; then rm -rf "${STAGE}"; fi
}
trap cleanup EXIT

install_app_from_dmg() {
    local dmg="${HERE}/app/${APP_DMG}" dest="/Applications" cur="" mnt
    echo "==> ${APP_NAME} ${APP_VERSION} from app/${APP_DMG}"
    [ -f "${dmg}" ] || die "${dmg} is missing"
    [ -w "${dest}" ] || dest="${HOME}/Applications"
    if [ -d "/Applications/${APP_NAME}" ]; then dest="/Applications"; fi
    if [ -d "${HOME}/Applications/${APP_NAME}" ]; then dest="${HOME}/Applications"; fi
    if [ -d "${dest}/${APP_NAME}" ]; then
        cur="$(defaults read "${dest}/${APP_NAME}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
    fi
    if [ -n "${cur}" ]; then
        if version_ge "${cur}" "${APP_VERSION}"; then
            note "installed ${cur} in ${dest} is the same or newer: kept"
            return 0
        fi
        if [ "${UPGRADE_APP}" != 1 ]; then
            note "installed ${cur} in ${dest} is older; kept (use --upgrade-app to replace it, with LM Studio closed)"
            return 0
        fi
        pgrep -x "LM Studio" >/dev/null 2>&1 && die "LM Studio is running: close it first"
    fi
    if [ "${DRY}" = 1 ]; then
        [ -z "${cur}" ] || note "[dry-run] mv \"${dest}/${APP_NAME}\" \"${dest}/${APP_NAME}.old-${cur}\""
        note "[dry-run] mount app/${APP_DMG}, ditto ${APP_NAME} into ${dest}, xattr -dr com.apple.quarantine"
        return 0
    fi
    mkdir -p "${dest}"
    mnt="$(mktemp -d "${TMPDIR:-/tmp}/lmstudio-dmg.XXXXXX")"
    hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "${mnt}" "${dmg}" || die "cannot mount ${dmg}"
    DMG_MNT="${mnt}"
    [ -d "${mnt}/${APP_NAME}" ] || die "app/${APP_DMG} has no ${APP_NAME}"
    # Copied next to its final place first, so an interrupted copy never sits where the version check looks.
    STAGE="$(mktemp -d "${dest}/.lmstudio-install.XXXXXX")"
    ditto "${mnt}/${APP_NAME}" "${STAGE}/${APP_NAME}"
    hdiutil detach -quiet "${mnt}" || hdiutil detach -quiet -force "${mnt}" || die "cannot detach ${mnt}"
    DMG_MNT=""
    rmdir "${mnt}" 2>/dev/null || true
    # A dmg copied by USB or the network is quarantined, and so is what ditto takes out of it.
    xattr -dr com.apple.quarantine "${STAGE}/${APP_NAME}"
    # What Gatekeeper checks on the first launch: a seal that does not verify is the "damaged" dialog.
    codesign --verify --deep --strict "${STAGE}/${APP_NAME}" || die "the copied ${APP_NAME} does not verify"
    if [ -n "${cur}" ]; then mv "${dest}/${APP_NAME}" "${dest}/${APP_NAME}.old-${cur}"; fi
    mv "${STAGE}/${APP_NAME}" "${dest}/${APP_NAME}"
    rmdir "${STAGE}"
    STAGE=""
    note "installed to ${dest}$([ -n "${cur}" ] && echo " (${cur} kept as ${APP_NAME}.old-${cur})")"
}

# A bundle that still ships the app itself (no app_dmg) leaves it to install.sh.
if [ -n "${APP_DMG}" ]; then G_ARGS+=(--no-app); fi

echo "######## 1/4 guardian: LM Studio runtimes and models, Open WebUI"
"${HERE}/install.sh" "${G_ARGS[@]}"
echo
echo "######## 2/4 LM Studio app"
if [ "${DO_APP}" = 0 ]; then
    note "--no-app: skipped"
elif [ -z "${APP_DMG}" ]; then
    note "installed by install.sh (this bundle has no dmg)"
else
    install_app_from_dmg
fi
echo
echo "######## 3/4 wiki layer: wiki-mcp, mcpo, watch"
"${HERE}/wiki-layer/install-wiki.sh" ${W_ARGS[@]+"${W_ARGS[@]}"}
echo
echo "######## 4/4 Claude Code, and claude-lms on LM Studio"
if [ "${DO_CLAUDE}" = 0 ]; then
    note "--no-claude-code: skipped"
elif [ ! -d "${HERE}/claude-code" ]; then
    note "this bundle has no claude-code/: skipped"
else
    # After the wiki step, so claude-lms takes the model ~/llm-wiki/.env names.
    "${HERE}/claude-code/install-claude-code.sh" ${C_ARGS[@]+"${C_ARGS[@]}"}
fi
