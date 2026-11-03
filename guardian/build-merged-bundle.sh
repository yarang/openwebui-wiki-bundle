#!/usr/bin/env bash
# ==============================================================================
# guardian LLM bundle + wiki layer → one deployable bundle (run on the build Mac)
#
# Input is a bundle made by server-guardian's build-llm-bundle.sh (LM Studio app, runtimes, models, and — unless it
# was built with --no-openwebui — tools/python and the Open WebUI wheels), plus the official LM Studio dmg. This
# script adds:
#   wiki-layer/wheels/      wiki-mcp (built from ./wiki-mcp) and the dependencies the guardian wheels lack,
#                           resolved for macOS arm64 / cp312 under the guardian wheel versions (constraints)
#   wiki-layer/...          install-wiki.sh, run-wiki-mcp.sh, load-env.sh, wiki.env.example, wiki (+templates),
#                           raw/README.md, ocr, open-webui-tools, document-templates, docs,
#                           bundled-models/nomic-ai (LM Studio's embedding model, taken from the dmg's app)
#   lmstudio-home/models/gpustack/bge-m3-GGUF
#                           the wiki's embedding model (LM Studio id text-embedding-bge-m3), copied to ~/.lmstudio
#                           by the guardian installer like the bundle's other models; checked against a pinned sha256
#   install-all.sh          guardian install.sh, then wiki-layer/install-wiki.sh, then claude-code/
#   claude-code/            Claude Code's native binary (Anthropic-signed, checked), install-claude-code.sh and
#                           claude-lms, which runs Claude Code on the Mac's LM Studio with no Anthropic account
#   app/<LM Studio dmg>     in place of app/LM Studio.app. install-all.sh copies the app out of it into Applications
#                           (what dragging it there does), so the target runs the notarized app as it was signed,
#                           never a copy that went through a launch: a launched app has moved its embedding model and
#                           extensions out of itself and its code signature no longer verifies (Gatekeeper calls it
#                           damaged). The dmg's app must verify and carry a stapled ticket, or the build stops.
# Then it proves the wheel set installs offline into a fresh venv of the bundled Python (pip check), rewrites the
# manifests the guardian installer verifies, and packs it with guardian/pack-bundle.sh: <name>.tar.xz + .sha256 and
# install-llm-wiki.sh next to the bundle, the three files to copy to the target Mac.
#
# Usage:  guardian/build-merged-bundle.sh BUNDLE_DIR [options]
#   --tools-from=HOST:DIR   copy tools/ and wheels/ from another guardian bundle (for one built with --no-openwebui)
#   --lmstudio-dmg=PATH     official LM Studio dmg to ship (required, unless the bundle's app/ already holds one)
#   --embedding-gguf=PATH   bge-m3-Q8_0.gguf to ship (default ~/.lmstudio/models/gpustack/bge-m3-GGUF/, where LM
#                           Studio keeps a downloaded one; dist/openwebui-wiki-models-*.tar holds the same file)
#   --claude-code=PATH      Claude Code binary to ship (default the build Mac's own, ~/.local/bin/claude)
#   --no-claude-code        ship no Claude Code
#   --name=NAME            output name (default llm-wiki-bundle-<bundle stamp>-macos-arm64)
#   --no-tar                stop after the directory is complete (pack it later with guardian/pack-bundle.sh)
# Nothing secret is read: .env, .webui_secret_key and data folders are never copied.
# ==============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/.." && pwd)"
BUNDLE=""
TOOLS_FROM=""
LMSTUDIO_DMG=""
NAME=""
DO_TAR=1
CLAUDE_BIN="${HOME}/.local/bin/claude"
# The wiki's embedding model. The id LM Studio gives a model comes from where its file sits, so the folder is fixed.
EMB_ID="text-embedding-bge-m3"
EMB_UNIT="gpustack/bge-m3-GGUF"
EMB_FILE="bge-m3-Q8_0.gguf"
EMB_SHA256="950f4a8e5e19477a6d3c26d2f162233c20002c601f75e4b002e3239997821167"
EMB_GGUF="${HOME}/.lmstudio/models/${EMB_UNIT}/${EMB_FILE}"

for arg in "$@"; do
    case "${arg}" in
        --tools-from=*) TOOLS_FROM="${arg#--tools-from=}" ;;
        --lmstudio-dmg=*) LMSTUDIO_DMG="${arg#--lmstudio-dmg=}" ;;
        --name=*) NAME="${arg#--name=}" ;;
        --embedding-gguf=*) EMB_GGUF="${arg#--embedding-gguf=}" ;;
        --no-tar) DO_TAR=0 ;;
        --claude-code=*) CLAUDE_BIN="${arg#--claude-code=}" ;;
        --no-claude-code) CLAUDE_BIN="" ;;
        -h|--help) sed -n '3,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: ${arg}" >&2; exit 2 ;;
        *) BUNDLE="${arg}" ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[ -n "${BUNDLE}" ] || die "usage: $0 BUNDLE_DIR --lmstudio-dmg=PATH [--tools-from=HOST:DIR] [--name=NAME] [--no-tar]"
[ -f "${BUNDLE}/MANIFEST.env" ] || die "${BUNDLE} is not a guardian bundle (no MANIFEST.env)"
BUNDLE="$(cd "${BUNDLE}" && pwd)"
LAYER="${BUNDLE}/wiki-layer"
manifest() { sed -n "s/^$1=//p" "${BUNDLE}/MANIFEST.env" | head -1; }
APP_NAME="$(manifest app_name)"
APP="${BUNDLE}/app/${APP_NAME:?MANIFEST.env has no app_name}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/merge-bundle.XXXXXX")"
DMG_MNT="${WORK}/dmg"
DMG_ATTACHED=0
detach_dmg() {
    [ "${DMG_ATTACHED}" = 1 ] || return 0
    hdiutil detach -quiet "${DMG_MNT}" || hdiutil detach -quiet -force "${DMG_MNT}" || return 1
    DMG_ATTACHED=0
}
# An image still attached stays under WORK, and rm would walk into it.
cleanup() {
    detach_dmg || echo "warning: ${DMG_MNT} is still attached; detach it and remove ${WORK}" >&2
    [ "${DMG_ATTACHED}" = 1 ] || rm -rf "${WORK}"
}
trap cleanup EXIT
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
# A seal that does not verify is what Gatekeeper reports as "damaged" on the target Mac.
check_seal() { codesign --verify --deep --strict "$1" 2>"${WORK}/codesign.err" || { cat "${WORK}/codesign.err" >&2; return 1; }; }

# ---- 1. LM Studio dmg ---------------------------------------------------------------------
# Rebuilding a merged bundle: the dmg it already ships is used again.
if [ -z "${LMSTUDIO_DMG}" ] && [ -n "$(manifest app_dmg)" ]; then LMSTUDIO_DMG="${BUNDLE}/app/$(manifest app_dmg)"; fi
[ -n "${LMSTUDIO_DMG}" ] || die "pass --lmstudio-dmg=PATH: the official LM Studio dmg (LM-Studio-<version>-arm64.dmg)"
[ -f "${LMSTUDIO_DMG}" ] || die "no such dmg: ${LMSTUDIO_DMG}"
LMSTUDIO_DMG="$(cd "$(dirname "${LMSTUDIO_DMG}")" && pwd)/$(basename "${LMSTUDIO_DMG}")"
DMG_NAME="$(basename "${LMSTUDIO_DMG}")"
log "LM Studio from ${DMG_NAME}"
mkdir -p "${DMG_MNT}"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "${DMG_MNT}" "${LMSTUDIO_DMG}" \
    || die "cannot mount ${LMSTUDIO_DMG}"
DMG_ATTACHED=1
DMG_APP="${DMG_MNT}/${APP_NAME}"
[ -d "${DMG_APP}" ] || die "the dmg has no ${APP_NAME}"
check_seal "${DMG_APP}" || die "the dmg's app does not verify: not an official LM Studio dmg?"
# Notarized and stapled means Gatekeeper can accept it on a Mac with no internet.
xcrun stapler validate -q "${DMG_APP}" || die "the dmg's app has no stapled notarization ticket"
APP_VER="$(plist "${DMG_APP}" CFBundleShortVersionString)" || die "${APP_NAME} has no CFBundleShortVersionString"
APP_MIN="$(plist "${DMG_APP}" LSMinimumSystemVersion)" || die "${APP_NAME} has no LSMinimumSystemVersion"
# LM Studio moves its bundled nomic model out of the app into ~/.lmstudio/.internal on first launch. install-wiki.sh
# puts this copy there itself, so the model is in place before the app first starts and the wiki never waits on it.
NOMIC="${DMG_APP}/Contents/Resources/app/.webpack/bin/bundled-models/nomic-ai"
ls "${NOMIC}"/*/*.gguf >/dev/null 2>&1 || die "${APP_NAME} in the dmg has no bundled nomic model"
ditto "${NOMIC}" "${WORK}/nomic-ai"
detach_dmg || die "cannot detach ${DMG_MNT}"
echo "    ${APP_NAME} ${APP_VER} (macOS ${APP_MIN}+), signature verifies, ticket stapled"

# The dmg goes in, the app and any other dmg come out: app/ must hold exactly what install-all.sh installs.
mkdir -p "${BUNDLE}/app"
if [ "${LMSTUDIO_DMG}" != "${BUNDLE}/app/${DMG_NAME}" ]; then
    cp "${LMSTUDIO_DMG}" "${BUNDLE}/app/${DMG_NAME}.partial"
    cmp -s "${LMSTUDIO_DMG}" "${BUNDLE}/app/${DMG_NAME}.partial" || die "copy of ${DMG_NAME} does not match"
    mv "${BUNDLE}/app/${DMG_NAME}.partial" "${BUNDLE}/app/${DMG_NAME}"
fi
for f in "${BUNDLE}"/app/* "${BUNDLE}"/app/.[!.]*; do
    if [ -e "${f}" ] && [ "${f}" != "${BUNDLE}/app/${DMG_NAME}" ]; then rm -rf "${f}"; fi
done
[ "$(ls -A "${BUNDLE}/app")" = "${DMG_NAME}" ] || die "app/ holds more than ${DMG_NAME}"
echo "    app/${DMG_NAME} ($(ls -lh "${BUNDLE}/app/${DMG_NAME}" | awk '{print $5}')) in place of app/${APP_NAME}"

# ---- 2. Python and Open WebUI wheels ------------------------------------------------------
if [ ! -x "${BUNDLE}/tools/python/bin/python3.12" ]; then
    [ -n "${TOOLS_FROM}" ] || die "${BUNDLE} has no tools/python (built with --no-openwebui): pass --tools-from=HOST:DIR"
    log "tools/ and wheels/ from ${TOOLS_FROM}"
    rsync -a --stats "${TOOLS_FROM%/}/tools" "${TOOLS_FROM%/}/wheels" "${BUNDLE}/" | { grep -E '^(Number of files|Total file size)' || true; }
fi
BPY="${BUNDLE}/tools/python/bin/python3.12"
"${BPY}" -c 'import sys; assert sys.version_info[:2] == (3, 12)' || die "bundled Python is not 3.12"
ls "${BUNDLE}"/wheels/open_webui-*.whl >/dev/null 2>&1 || die "no open_webui wheel in ${BUNDLE}/wheels"

# ---- 3. wiki-mcp wheels -------------------------------------------------------------------
log "wiki-mcp wheel and its missing dependencies"
rm -rf "${LAYER}"
mkdir -p "${LAYER}/wheels" "${WORK}/dl"
"${BPY}" -m pip wheel --no-deps --quiet --disable-pip-version-check -w "${LAYER}/wheels" "${SRC}/wiki-mcp" \
    || die "building the wiki-mcp wheel failed (setuptools must be importable by the bundled Python)"
WIKI_WHL="$(ls "${LAYER}"/wheels/wiki_mcp-*.whl)"

# Shared dependencies (pydantic, starlette, chromadb, ...) must resolve to the versions Open WebUI ships with.
for w in "${BUNDLE}"/wheels/*.whl; do
    b="$(basename "${w}")"
    echo "$(echo "${b}" | cut -d- -f1 | tr '_' '-')==$(echo "${b}" | cut -d- -f2)"
done | sort -u >"${WORK}/constraints.txt"

"${BPY}" -m pip download "${WIKI_WHL}" python-docx python-pptx openpyxl -c "${WORK}/constraints.txt" \
    --only-binary=:all: --python-version 3.12 --implementation cp --abi cp312 \
    --platform macosx_26_0_arm64 --platform macosx_15_0_arm64 --platform macosx_14_0_arm64 \
    --platform macosx_13_0_arm64 --platform macosx_12_0_arm64 --platform macosx_11_0_arm64 \
    --platform macosx_10_9_universal2 --platform macosx_11_0_universal2 \
    -d "${WORK}/dl" --quiet --disable-pip-version-check
added=0
for w in "${WORK}"/dl/*.whl; do
    b="$(basename "${w}")"
    case "${b}" in wiki_mcp-*) continue ;; esac
    if [ ! -f "${BUNDLE}/wheels/${b}" ]; then cp "${w}" "${LAYER}/wheels/"; added=$((added + 1)); fi
done
echo "    $(basename "${WIKI_WHL}") + ${added} dependency wheel(s) not in the guardian set"

# ---- 4. wiki layer files ------------------------------------------------------------------
log "wiki layer files"
cp "${HERE}/install-wiki.sh" "${HERE}/wiki.env.example" "${SRC}/run-wiki-mcp.sh" "${SRC}/load-env.sh" "${LAYER}/"
chmod 755 "${LAYER}/install-wiki.sh" "${LAYER}/run-wiki-mcp.sh"
EXCL=(--exclude='.DS_Store' --exclude='__pycache__/' --exclude='*.pyc' --exclude='*.bak' --exclude='*.bak.*')
rsync -a "${EXCL[@]}" "${SRC}/wiki" "${SRC}/ocr" "${SRC}/open-webui-tools" "${SRC}/document-templates" \
    "${SRC}/docs" "${LAYER}/"
mkdir -p "${LAYER}/raw"
cp "${SRC}/raw/README.md" "${LAYER}/raw/"
[ -x "${LAYER}/ocr/vision-ocr" ] || die "ocr/vision-ocr missing: build it with swiftc -O -o ocr/vision-ocr ocr/vision_ocr.swift"
# The nomic model taken out of the dmg's app in step 1.
mkdir -p "${LAYER}/bundled-models"
ditto "${WORK}/nomic-ai" "${LAYER}/bundled-models/nomic-ai"
# nomic finds little in Korean notes (top-1 3/14 vs bge-m3 14/14 on test-mac), so the wiki embeds with bge-m3. Ship the
# GGUF: LM Studio lists an MLX conversion of it as an LLM, not as an embedding model.
log "bge-m3 embedding model (${EMB_ID})"
EMB_DEST="${BUNDLE}/lmstudio-home/models/${EMB_UNIT}/${EMB_FILE}"
sha_ok() { [ -f "$1" ] && [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "${EMB_SHA256}" ]; }
if sha_ok "${EMB_DEST}"; then
    echo "    already in the bundle"
else
    sha_ok "${EMB_GGUF}" || die "${EMB_GGUF}: missing or not the pinned bge-m3 Q8 file (sha256 ${EMB_SHA256}); pass --embedding-gguf=PATH"
    mkdir -p "$(dirname "${EMB_DEST}")"
    cp "${EMB_GGUF}" "${EMB_DEST}"
    sha_ok "${EMB_DEST}" || die "copy of ${EMB_FILE} does not match"
fi
cp "${HERE}/install-all.sh" "${HERE}/README.md" "${BUNDLE}/"
chmod 755 "${BUNDLE}/install-all.sh"
# A secret must never ride along, whatever the source tree holds.
if find "${BUNDLE}" \( -name '.env' -o -name '.webui_secret_key' -o -name '.gitea.env' -o -name 'webui.db*' \) \
    -print | grep -q .; then
    die "a secret or data file ended up in the bundle"
fi

# ---- 4b. Claude Code ----------------------------------------------------------------------
# The native build is one self-contained binary. A bare Mach-O carries no stapled ticket, so the installer checks the
# seal and Anthropic's team itself; the same check here keeps anything else out of the bundle.
CC_VER=""
rm -rf "${BUNDLE}/claude-code"
if [ -n "${CLAUDE_BIN}" ]; then
    log "Claude Code"
    [ -e "${CLAUDE_BIN}" ] || die "${CLAUDE_BIN} is missing: pass --claude-code=PATH or --no-claude-code"
    CLAUDE_BIN="$(readlink -f "${CLAUDE_BIN}")"
    codesign --verify --strict "${CLAUDE_BIN}" || die "${CLAUDE_BIN} does not verify"
    codesign -dv "${CLAUDE_BIN}" 2>&1 | grep -qx 'TeamIdentifier=Q6L2SF6YDW' \
        || die "${CLAUDE_BIN} is not signed by Anthropic"
    CC_VER="$("${CLAUDE_BIN}" --version | awk '{print $1}')"
    mkdir -p "${BUNDLE}/claude-code"
    cp "${CLAUDE_BIN}" "${BUNDLE}/claude-code/claude"
    cmp -s "${CLAUDE_BIN}" "${BUNDLE}/claude-code/claude" || die "copy of ${CLAUDE_BIN} does not match"
    echo "${CC_VER}" >"${BUNDLE}/claude-code/VERSION"
    cp "${HERE}/install-claude-code.sh" "${HERE}/claude-lms" "${BUNDLE}/claude-code/"
    chmod 755 "${BUNDLE}/claude-code/claude" "${BUNDLE}/claude-code/install-claude-code.sh" \
        "${BUNDLE}/claude-code/claude-lms"
    echo "    Claude Code ${CC_VER} ($(ls -lh "${BUNDLE}/claude-code/claude" | awk '{print $5}'))"
fi

# ---- 5. prove the offline install ---------------------------------------------------------
log "offline install test into a fresh venv (pip check)"
"${BPY}" -m venv "${WORK}/venv"
"${WORK}/venv/bin/python" -m pip install --no-index --find-links "${BUNDLE}/wheels" --find-links "${LAYER}/wheels" \
    --quiet --disable-pip-version-check open-webui mcpo wiki-mcp python-docx python-pptx openpyxl
"${WORK}/venv/bin/python" -m pip check --disable-pip-version-check
# wiki_mcp.server indexes on import: point it at an empty wiki in WORK, with embeddings off.
mkdir -p "${WORK}/wiki"
WIKI_PATH="${WORK}/wiki" WIKI_DATA_DIR="${WORK}/wiki-data" EMBEDDING_DISABLED=1 \
    "${WORK}/venv/bin/python" -c 'import wiki_mcp.server, docx, pptx, openpyxl, frontmatter, rank_bm25' >/dev/null \
    || die "wiki-mcp does not import in the test venv"
OW_VER="$("${WORK}/venv/bin/python" -c 'from importlib.metadata import version; print(version("open-webui"))')"
WIKI_VER="$("${WORK}/venv/bin/python" -c 'from importlib.metadata import version; print(version("wiki-mcp"))')"
MCPO_VER="$("${WORK}/venv/bin/python" -c 'from importlib.metadata import version; print(version("mcpo"))')"
PY_VER="$("${BPY}" --version | awk '{print $2}')"
echo "    open-webui ${OW_VER}, mcpo ${MCPO_VER}, wiki-mcp ${WIKI_VER}, python ${PY_VER}"

# ---- 6. manifests -------------------------------------------------------------------------
log "manifests"
# app_version and min_macos follow the app in the shipped dmg: the guardian installer checks min_macos, and
# install-all.sh compares app_version with an installed LM Studio to decide whether to replace it.
grep -v -E "^(app_version|min_macos|app_dmg|python|open_webui|mcpo|wiki_mcp|embedding_model|claude_code)=|^model=${EMB_UNIT}\$" \
    "${BUNDLE}/MANIFEST.env" \
    >"${WORK}/manifest.env"
{
    cat "${WORK}/manifest.env"
    echo "app_version=${APP_VER}"
    echo "min_macos=${APP_MIN}"
    echo "app_dmg=${DMG_NAME}"
    echo "python=${PY_VER}"
    echo "open_webui=${OW_VER}"
    echo "mcpo=${MCPO_VER}"
    echo "wiki_mcp=${WIKI_VER}"
    echo "model=${EMB_UNIT}"
    echo "embedding_model=${EMB_ID}"
    if [ -n "${CC_VER}" ]; then echo "claude_code=${CC_VER}"; fi
} >"${BUNDLE}/MANIFEST.env"
# MANIFEST.json is itself in MANIFEST.sha256, so it is written first; its file count is the list's length.
touch "${BUNDLE}/MANIFEST.json"
NFILES="$(cd "${BUNDLE}" && find . -type f ! -name MANIFEST.sha256 | wc -l | tr -d ' ')"
"${BPY}" - "${BUNDLE}" "${NFILES}" <<'PY'
import json, sys
b, nfiles = sys.argv[1], int(sys.argv[2])
env = {}
with open(b + "/MANIFEST.env") as f:
    for line in f:
        k, _, v = line.rstrip("\n").partition("=")
        env.setdefault(k, []).append(v)
out = {k: (v if k in ("runtime", "model") else v[0]) for k, v in env.items()}
out["files"] = nfiles
with open(b + "/MANIFEST.json", "w") as f:
    json.dump(out, f, indent=2, ensure_ascii=False)
PY
# Same commands as build-llm-bundle.sh, so the guardian installer's checksum pass covers the wiki layer too.
(cd "${BUNDLE}" && find . -type f ! -name MANIFEST.sha256 -print0 | xargs -0 -n 64 -P 4 shasum -a 256 \
    | sed 's#  \./#  #' | LC_ALL=C sort -k2 >MANIFEST.sha256)
(cd "${BUNDLE}" && grep -E '  MANIFEST\.(env|json)$' MANIFEST.sha256 | shasum -a 256 -c --quiet) \
    || die "MANIFEST.sha256 does not match the manifests it was written with"
[ "$(wc -l <"${BUNDLE}/MANIFEST.sha256" | tr -d ' ')" = "${NFILES}" ] \
    || die "MANIFEST.json's file count differs from MANIFEST.sha256"

# ---- 7. archive ---------------------------------------------------------------------------
[ -n "${NAME}" ] || NAME="llm-wiki-bundle-$(manifest created_utc)-macos-arm64"
if [ "$(basename "${BUNDLE}")" != "${NAME}" ]; then
    [ -e "$(dirname "${BUNDLE}")/${NAME}" ] && die "$(dirname "${BUNDLE}")/${NAME} already exists"
    mv "${BUNDLE}" "$(dirname "${BUNDLE}")/${NAME}"
    BUNDLE="$(dirname "${BUNDLE}")/${NAME}"
fi
du -sh "${BUNDLE}" | awk '{print "    size: " $1}'
log "bundle folder done: ${BUNDLE}"
if [ "${DO_TAR}" = 1 ]; then
    "${HERE}/pack-bundle.sh" "${BUNDLE}"
else
    echo "Pack it later: guardian/pack-bundle.sh ${BUNDLE}"
fi
