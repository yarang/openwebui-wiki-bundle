#!/bin/bash
# ==============================================================================
# LLM + wiki bundle, one-step install from the archive (run on the target Mac)
#
# Put these three files (made by guardian/pack-bundle.sh) into one folder, e.g. ~/bundles:
#   <name>.tar.xz   <name>.tar.xz.sha256   install-llm-wiki.sh
# then
#   bash install-llm-wiki.sh --dry-run    # checks and extracts, then shows what install-all.sh would do
#   bash install-llm-wiki.sh              # install + start
#
# Steps: archive sha256 → free space → extract next to the archive (/usr/bin/tar, one core: about 5 min for 7 GB) → the
# bundle's install-all.sh (which also installs LM Studio from the bundle's dmg) → LM Studio's first launch →
# wiki-layer/install-wiki.sh again. The last two are the
# README's manual follow-up: LM Studio writes its settings only when it first runs, and only then can the wiki step
# make its server start with the app. On a Mac where LM Studio already ran and :1234 answers, they are skipped.
# An already extracted bundle folder is reused (install.sh checks it against MANIFEST.sha256). Nothing is deleted,
# downloaded, or run with sudo. Written for /bin/bash 3.2.
#
# Usage:  bash install-llm-wiki.sh [--archive=PATH] [--dest=DIR] [--launch-timeout=S] [install-all.sh options]
#   --archive=PATH      archive to install (default: the one llm-wiki-bundle-*.tar.xz next to this script)
#   --dest=DIR          folder to extract into (default: the archive's folder)
#   --launch-timeout=S  how long to wait for LM Studio's first launch (default 180)
#   other options go to install-all.sh, e.g. --webui-host=0.0.0.0, --migrate-from=OLD_BUNDLE, --skip-verify
#   (--skip-verify also skips the archive's sha256)
# ==============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE=""
DEST=""
LAUNCH_TIMEOUT=180
DRY=0
NO_START=0
SKIP_VERIFY=0
ALL_ARGS=()
# The second wiki pass gets the same wiki options, except --migrate-from: the data was copied in the first pass.
WIKI_ARGS=()
# install-all.sh puts the app in ~/Applications when /Applications is not writable.
APP="/Applications/LM Studio.app"
SETTINGS="${HOME}/.lmstudio/settings.json"
LMSTUDIO_URL="http://127.0.0.1:1234/v1"

for arg in "$@"; do
    case "${arg}" in
        --archive=*) ARCHIVE="${arg#--archive=}" ;;
        --dest=*) DEST="${arg#--dest=}" ;;
        --launch-timeout=*) LAUNCH_TIMEOUT="${arg#--launch-timeout=}" ;;
        -h|--help) sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)
            ALL_ARGS+=("${arg}")
            case "${arg}" in
                --dry-run) DRY=1 ;;
                --no-start) NO_START=1 ;;
                --skip-verify) SKIP_VERIFY=1 ;;
                --prefix=*|--embedding-model=*|--wiki-home=*|--mcpo-port=*|--webui-host=*) WIKI_ARGS+=("${arg}") ;;
            esac
            ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
note() { echo "    $*"; }
server_up() { curl -sf -m 2 -o /dev/null "${LMSTUDIO_URL}/models"; }
app_running() { pgrep -f "/LM Studio.app/Contents/MacOS/LM Studio" >/dev/null 2>&1; }

[ "$(uname -s)/$(uname -m)" = "Darwin/arm64" ] || die "this bundle is for Apple silicon macOS"
case "${LAUNCH_TIMEOUT}" in ''|*[!0-9]*) die "--launch-timeout must be a number of seconds" ;; esac

# ---- archive -------------------------------------------------------------------------------
if [ -z "${ARCHIVE}" ]; then
    found=()
    for f in "${HERE}"/llm-wiki-bundle-*.tar.xz; do
        if [ -f "${f}" ]; then found+=("${f}"); fi
    done
    [ "${#found[@]}" -gt 0 ] || die "no llm-wiki-bundle-*.tar.xz next to this script (${HERE}); pass --archive=PATH"
    if [ "${#found[@]}" -gt 1 ]; then
        printf '    %s\n' "${found[@]}" >&2
        die "more than one archive next to this script; pick one with --archive=PATH"
    fi
    ARCHIVE="${found[0]}"
fi
[ -f "${ARCHIVE}" ] || die "${ARCHIVE}: not found"
ARCHIVE="$(cd "$(dirname "${ARCHIVE}")" && pwd)/$(basename "${ARCHIVE}")"
NAME="$(basename "${ARCHIVE}" .tar.xz)"
DEST="${DEST:-$(dirname "${ARCHIVE}")}"
mkdir -p "${DEST}"
DEST="$(cd "${DEST}" && pwd)"
BUNDLE="${DEST}/${NAME}"
STAGE="${DEST}/.${NAME}.extracting"
log "bundle ${NAME}"

if [ -d "${BUNDLE}" ]; then
    [ -x "${BUNDLE}/install-all.sh" ] || die "${BUNDLE} exists but is not a complete bundle; move it away and rerun"
    note "already extracted: ${BUNDLE} (reused; install.sh checks it against MANIFEST.sha256)"
else
    if [ -e "${STAGE}" ]; then
        die "${STAGE} is left from an interrupted extraction; move it away (or delete it) and rerun"
    fi
    if [ "${SKIP_VERIFY}" = 1 ]; then
        note "--skip-verify: archive sha256 not checked"
    else
        [ -f "${ARCHIVE}.sha256" ] || die "${ARCHIVE}.sha256 is missing: copy it next to the archive"
        log "check sha256 of $(basename "${ARCHIVE}") ($(ls -lh "${ARCHIVE}" | awk '{print $5}'))"
        (cd "$(dirname "${ARCHIVE}")" && shasum -a 256 -c "$(basename "${ARCHIVE}").sha256") \
            || die "the archive does not match its .sha256: copy it again"
    fi

    # The folder is about 1.3x the archive, and install.sh copies the app, models and Python out of it into
    # /Applications, ~/.lmstudio and ~/.guardian-llm: about the same again. 2.5x the archive plus 2 GB covers both.
    need_kb=$(( $(ls -l "${ARCHIVE}" | awk '{print $5}') / 1024 * 5 / 2 + 2 * 1024 * 1024 ))
    free_kb="$(df -k "${DEST}" | awk 'NR==2 {print $4}')"
    [ "${free_kb}" -ge "${need_kb}" ] \
        || die "not enough free space on ${DEST}: $(( free_kb / 1024 / 1024 )) GB free, about $(( need_kb / 1024 / 1024 )) GB needed"
    note "free space: $(( free_kb / 1024 / 1024 )) GB (about $(( need_kb / 1024 / 1024 )) GB needed)"

    log "extract into ${DEST}"
    SECONDS=0
    mkdir "${STAGE}"
    /usr/bin/tar -xJf "${ARCHIVE}" -C "${STAGE}" || die "extraction failed; ${STAGE} is left for inspection"
    [ -x "${STAGE}/${NAME}/install-all.sh" ] || die "the archive has no ${NAME}/install-all.sh (left in ${STAGE})"
    mv "${STAGE}/${NAME}" "${BUNDLE}"
    rmdir "${STAGE}" || note "warning: ${STAGE} is not empty; left as it is"
    note "extracted in ${SECONDS}s"
fi

# ---- install -------------------------------------------------------------------------------
# Whether LM Studio had run before decides if the follow-up is needed; install-all.sh does not launch it.
HAD_SETTINGS=0
if [ -f "${SETTINGS}" ]; then HAD_SETTINGS=1; fi

log "install-all.sh ${ALL_ARGS[*]+${ALL_ARGS[*]}}"
"${BUNDLE}/install-all.sh" ${ALL_ARGS[@]+"${ALL_ARGS[@]}"}

if [ "${DRY}" = 1 ]; then
    echo
    log "dry run: nothing installed (the bundle stays extracted in ${BUNDLE})"
    note "afterwards LM Studio would be opened once and wiki-layer/install-wiki.sh run again"
    exit 0
fi
if [ "${NO_START}" = 1 ]; then
    log "--no-start: LM Studio is not opened. Later: open \"${APP}\", then cd \"${BUNDLE}/wiki-layer\" && ./install-wiki.sh"
    exit 0
fi

# ---- LM Studio first launch + wiki step again ---------------------------------------------
echo
log "LM Studio first launch"
if [ ! -d "${APP}" ] && [ -d "${HOME}/Applications/LM Studio.app" ]; then APP="${HOME}/Applications/LM Studio.app"; fi
if [ ! -d "${APP}" ]; then
    note "${APP} is not installed (--no-app?): the wiki searches with BM25 only until LM Studio serves :1234"
    exit 0
fi
if [ "${HAD_SETTINGS}" = 1 ] && server_up; then
    note "LM Studio had run before and its server answers: nothing more to do"
else
    # The full path: open -a "LM Studio" can pick another copy of the app (an old bundle, a backup folder).
    open "${APP}"
    waited=0
    while [ ! -f "${SETTINGS}" ] || ! app_running; do
        if [ "${waited}" -ge "${LAUNCH_TIMEOUT}" ]; then
            note "LM Studio did not finish starting within ${LAUNCH_TIMEOUT}s. A Gatekeeper dialog may be waiting"
            note "on this Mac's screen: answer it (Open), then run"
            note "  cd \"${BUNDLE}/wiki-layer\" && ./install-wiki.sh"
            exit 3
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done
    # settings.json is written early in the launch; give the app a moment so it does not overwrite the wiki
    # step's change with its own first save.
    sleep 5
    note "LM Studio is running (${waited}s)"
    echo
    log "wiki step again (LM Studio server starts with the app from now on)"
    "${BUNDLE}/wiki-layer/install-wiki.sh" ${WIKI_ARGS[@]+"${WIKI_ARGS[@]}"}
fi

echo
if server_up; then
    log "done: LM Studio :1234 answers"
else
    log "done, but LM Studio's server does not answer on :1234: turn it on in the app's Developer tab"
fi
note "Open WebUI: http://127.0.0.1:8080 (create the admin account first)"
note "logs: ~/llm-wiki/logs/mcpo.log, ~/llm-wiki/logs/watch.log"
note "the extracted folder ${BUNDLE} and the archive can be removed once everything works"
