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
#   install-all.sh          guardian install.sh, then wiki-layer/install-wiki.sh, then claude-code/, then
#                           wiki-mcp-kit/, then vscode-addon/, then hop-viewer/ (seven steps)
#   reset-admin-password.sh the offline Open WebUI admin password reset, next to install-all.sh; the installer
#                           does not copy it anywhere, so the site runs it from the extracted bundle folder
#   claude-code/            Claude Code's native binary (Anthropic-signed, checked), install-claude-code.sh and
#                           claude-lms, which runs Claude Code on the Mac's LM Studio with no Anthropic account,
#                           claude-vscode (the VS Code extension's claudeProcessWrapper, reading the same env
#                           file), plus claude-kit/ (the hwpx, docx, xlsx and pptx skills with the python-hwpx
#                           wheel, installed in ~/.claude/skills, and system-prompt.md, the slim system prompt
#                           installed in ~/.config/claude-lms but left off) and llm-router/ (the local Anthropic
#                           proxy over LM Studio and a DGX Spark: router.py, spark-model, install-llm-router.sh,
#                           env.example, README.md — never its tests or spark/, which the Spark installs from
#                           the repo)
#   wiki-mcp-kit/           the shared wiki-mcp HTTP server kit (install-wiki-mcp.sh, run-wiki-mcp.sh,
#                           load-env.sh, README.md and the very wheel built in §3, passed with --wheel so
#                           nothing is built twice): install-all.sh runs it as its 5th step, after the
#                           Claude Code step, so the kit finds the claude CLI it registers in user scope
#   vscode-addon/           the VS Code add-on staged by guardian/pack-vscode-addon.sh --no-tar (the VS Code dmg,
#                           the Foam and Claude Code extensions, install-vscode.sh, wiki-workspace/, SHA256SUMS):
#                           install-all.sh runs it as its 6th step, after the Claude Code step whose claude-lms env
#                           its settings are built from
#   hop-viewer/             the HOP viewer kit staged by guardian/pack-hop-viewer.sh --no-tar (the HOP dmg,
#                           install-hop.sh, SHA256SUMS): install-all.sh runs it as its 7th step, the last one;
#                           it opens .hwp/.hwpx files and registers itself with LaunchServices
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
#   --vscode-vendor=DIR     the three VS Code vendor files (default <repo>/dist/vendor/vscode)
#   --no-vscode-addon       ship no VS Code add-on
#   --hop-vendor=DIR        the HOP viewer vendor dmg (default <repo>/dist/vendor/hop)
#   --no-hop-viewer         ship no HOP viewer
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
# The VS Code add-on ships unless asked not to; an empty vendor dir means pack-vscode-addon.sh's own default.
DO_VSCODE=1
VSCODE_VENDOR=""
# The HOP viewer ships unless asked not to; an empty vendor dir means pack-hop-viewer.sh's own default.
DO_HOP=1
HOP_VENDOR=""
# The wiki's embedding model. The id LM Studio gives a model comes from where its file sits, so the folder is fixed.
EMB_ID="text-embedding-bge-m3"
EMB_UNIT="gpustack/bge-m3-GGUF"
EMB_FILE="bge-m3-Q8_0.gguf"
EMB_SHA256="950f4a8e5e19477a6d3c26d2f162233c20002c601f75e4b002e3239997821167"
EMB_GGUF="${HOME}/.lmstudio/models/${EMB_UNIT}/${EMB_FILE}"
# The python-hwpx wheel the hwpx skill vendors into ~/.claude/skills/hwpx/lib; the bundle ships exactly this one.
HWPX_WHL_SHA256="4b8369414dcbf32036cf9ac7f9dbfe3dd78d0f62230969034e6e6b5085912a62"
# The office skills ship beside hwpx with no wheel: their tools import docx/openpyxl/pptx from the target Mac's
# python. Byte-for-byte the same line as pack-claude-code.sh (tests compare them).
OFFICE_SKILLS="docx xlsx pptx"
# The llm-router ships as its own folder in claude-code/: exactly these five files. Its dev tests and the DGX
# Spark controller (spark/) stay out — the controller is installed on the Spark from the repo, not by this kit.
# Byte-for-byte the same line as pack-claude-code.sh (tests compare them).
LLM_ROUTER_FILES="router.py spark-model install-llm-router.sh env.example README.md"

for arg in "$@"; do
    case "${arg}" in
        --tools-from=*) TOOLS_FROM="${arg#--tools-from=}" ;;
        --lmstudio-dmg=*) LMSTUDIO_DMG="${arg#--lmstudio-dmg=}" ;;
        --name=*) NAME="${arg#--name=}" ;;
        --embedding-gguf=*) EMB_GGUF="${arg#--embedding-gguf=}" ;;
        --no-tar) DO_TAR=0 ;;
        --claude-code=*) CLAUDE_BIN="${arg#--claude-code=}" ;;
        --no-claude-code) CLAUDE_BIN="" ;;
        --vscode-vendor=*) VSCODE_VENDOR="${arg#--vscode-vendor=}" ;;
        --no-vscode-addon) DO_VSCODE=0 ;;
        --hop-vendor=*) HOP_VENDOR="${arg#--hop-vendor=}" ;;
        --no-hop-viewer) DO_HOP=0 ;;
        -h|--help) sed -n '3,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
EXCL=(--exclude='.DS_Store' --exclude='__pycache__/' --exclude='*.pyc' --exclude='*.bak' --exclude='*.bak.*' --exclude='.obsidian/')
# VS Code·Foam 로컬 설정은 site Mac 에서 vscode-addon 의 installer 가 wiki 폴더에 만드는 것이라
# 번들 wiki 에는 실리지 않는다. EXCL 은 pack-claude-code.sh 와 바이트 단위로 같아야 하므로
# (시험이 비교한다) 이 rsync 에만 쓰는 별도 배열로 붙인다. 패턴은 rsync 루트 상대로 어느 깊이에나
# .vscode/ .foam/ 디렉터리를 걸러는데, 이 명령이 복사하는 다른 디렉터리에는 그런 이름이 없다.
EXCL_WIKI=(--exclude='.vscode/' --exclude='.foam/')
# 현장 번들 docs/ 에는 로컬 LLM 운영 문서만 실는다. 내부 설계·벤치(DGX Spark·LLM 라우터 설계,
# 벤치 로그)는 docs/internal 에, git 이 추적하지 않는 벤치 잔여물은 docs/bench 에, 공개용
# 설계·시험 기록(LLM 라우터 시험, Spark 벤치 리포트)은 docs/dev 에 남아 있어 셋 다 이
# rsync에서 뺀다(docs/dev 는 공개 대상이지만 현장 번들에는 실지 않는다). 앞의 '/' 는 rsync
# 전송 루트(docs/) 기준으로 고정한다.
EXCL_DOCS=(--exclude='/docs/internal/' --exclude='/docs/bench/' --exclude='/docs/dev/')
rsync -a "${EXCL[@]}" "${EXCL_WIKI[@]}" "${EXCL_DOCS[@]}" "${SRC}/wiki" "${SRC}/ocr" "${SRC}/open-webui-tools" "${SRC}/document-templates" \
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
cp "${HERE}/install-all.sh" "${HERE}/README.md" "${HERE}/reset-admin-password.sh" "${BUNDLE}/"
chmod 755 "${BUNDLE}/install-all.sh" "${BUNDLE}/reset-admin-password.sh"

# ---- 4b. Claude Code ----------------------------------------------------------------------
# The native build is one self-contained binary. A bare Mach-O carries no stapled ticket, so the installer checks the
# seal and Anthropic's team itself; the same check here keeps anything else out of the bundle.
CC_VER=""
# The five llm-router files this block stages (§4b): checked before rm -rf, so a missing source never
# costs the bundle its existing claude-code/. Same for the two files the kit ships beside claude-lms.
if [ -n "${CLAUDE_BIN}" ]; then
    for f in ${LLM_ROUTER_FILES}; do
        [ -f "${HERE}/llm-router/${f}" ] || die "${HERE}/llm-router/${f} is missing"
    done
    for f in "${HERE}/claude-vscode" "${HERE}/claude-kit/system-prompt.md"; do
        [ -f "${f}" ] || die "${f} is missing"
    done
fi
rm -rf "${BUNDLE}/claude-code"
if [ -n "${CLAUDE_BIN}" ]; then
    log "Claude Code"
    [ -e "${CLAUDE_BIN}" ] || die "${CLAUDE_BIN} is missing: pass --claude-code=PATH or --no-claude-code"
    CLAUDE_BIN="$(readlink -f "${CLAUDE_BIN}")"
    codesign --verify --strict "${CLAUDE_BIN}" || die "${CLAUDE_BIN} does not verify"
    # Captured, never piped into a short-exit grep: under set -o pipefail that race fails a good
    # signature about 2 runs in 3 (grep leaves, codesign still has lines to write, SIGPIPE).
    CS_INFO="$(codesign -dv "${CLAUDE_BIN}" 2>&1)" || die "cannot read the signature of ${CLAUDE_BIN}"
    grep -qx 'TeamIdentifier=Q6L2SF6YDW' <<<"${CS_INFO}" || die "${CLAUDE_BIN} is not signed by Anthropic"
    CC_VER="$("${CLAUDE_BIN}" --version | awk '{print $1}')"
    mkdir -p "${BUNDLE}/claude-code"
    cp "${CLAUDE_BIN}" "${BUNDLE}/claude-code/claude"
    cmp -s "${CLAUDE_BIN}" "${BUNDLE}/claude-code/claude" || die "copy of ${CLAUDE_BIN} does not match"
    echo "${CC_VER}" >"${BUNDLE}/claude-code/VERSION"
    cp "${HERE}/install-claude-code.sh" "${HERE}/claude-lms" "${HERE}/claude-vscode" "${BUNDLE}/claude-code/"
    chmod 755 "${BUNDLE}/claude-code/claude" "${BUNDLE}/claude-code/install-claude-code.sh" \
        "${BUNDLE}/claude-code/claude-lms" "${BUNDLE}/claude-code/claude-vscode"
    # The llm-router folder, exactly the five files (no tests/, no spark/): its installer runs on the
    # target Mac only with --with-router, so a Mac without a Spark is unchanged.
    mkdir -p "${BUNDLE}/claude-code/llm-router"
    for f in ${LLM_ROUTER_FILES}; do cp "${HERE}/llm-router/${f}" "${BUNDLE}/claude-code/llm-router/"; done
    chmod 755 "${BUNDLE}/claude-code/llm-router/spark-model" "${BUNDLE}/claude-code/llm-router/install-llm-router.sh"
    # The skills the installer puts in ~/.claude/skills/<name>: their skills and the hwpx wheel, never the dev
    # tests. system-prompt.md goes to ~/.config/claude-lms (left off until CLAUDE_LMS_SYSTEM_PROMPT_FILE).
    mkdir -p "${BUNDLE}/claude-code/claude-kit"
    rsync -a "${EXCL[@]}" "${HERE}/claude-kit/skills" "${HERE}/claude-kit/wheels" "${BUNDLE}/claude-code/claude-kit/"
    cp "${HERE}/claude-kit/system-prompt.md" "${BUNDLE}/claude-code/claude-kit/system-prompt.md"
    [ "$(shasum -a 256 "${BUNDLE}/claude-code/claude-kit/wheels/python_hwpx-6.11.0-py3-none-any.whl" \
        | awk '{print $1}')" = "${HWPX_WHL_SHA256}" ] \
        || die "the python-hwpx wheel shipped in claude-code/claude-kit is not the pinned sha256 ${HWPX_WHL_SHA256}"
    chmod 755 "${BUNDLE}/claude-code/claude-kit/skills/hwpx/scripts/hwpx" \
        "${BUNDLE}/claude-code/claude-kit/skills/hwpx/scripts/skill-guard"
    for s in ${OFFICE_SKILLS}; do chmod 755 "${BUNDLE}/claude-code/claude-kit/skills/${s}/scripts/${s}"; done
    echo "    Claude Code ${CC_VER} ($(ls -lh "${BUNDLE}/claude-code/claude" | awk '{print $5}'))"
fi

# ---- 4c. wiki-mcp kit ----------------------------------------------------------------------
# The kit install-all.sh runs as its 5th step (one shared wiki-mcp HTTP server, the single Chroma
# writer). §3 already built the wiki-mcp wheel: --wheel ships that very file, so no second build
# and no Python-with-setuptools lookup. pack checks its own sources first (§3 of the pack script),
# so a missing file fails here before the bundle loses the kit it already had.
log "wiki-mcp kit (for install-all.sh step 5)"
rm -rf "${WORK}/wikikit"
"${HERE}/pack-wiki-mcp-kit.sh" --wheel="${WIKI_WHL}" --out="${WORK}/wikikit" \
    --name=wiki-mcp-kit --no-tar >/dev/null \
    || die "pack-wiki-mcp-kit.sh failed for the bundle's wiki-mcp-kit"
[ -d "${WORK}/wikikit/wiki-mcp-kit" ] || die "pack-wiki-mcp-kit.sh staged no wiki-mcp-kit"
rm -rf "${BUNDLE}/wiki-mcp-kit"
mv "${WORK}/wikikit/wiki-mcp-kit" "${BUNDLE}/wiki-mcp-kit"
echo "    wiki-mcp-kit/ (install-all.sh 5th step, wheel $(basename "${WIKI_WHL}"))"

# ---- 4d. VS Code add-on ----------------------------------------------------------------------
# The add-on install-all.sh runs as its 6th step. pack-vscode-addon.sh checks its own vendor files
# (pins, seal, team, the vsix manifests) and stages into WORK first, like §4c: a failed pack never
# costs the bundle the copy it already had, and only a complete staged folder is moved in.
VSCODE_VER=""
CC_EXT_VER=""
FOAM_VER=""
if [ "${DO_VSCODE}" = 1 ]; then
    log "VS Code add-on"
    VS_ARGS=()
    if [ -n "${VSCODE_VENDOR}" ]; then VS_ARGS+=(--vendor="${VSCODE_VENDOR}"); fi
    rm -rf "${WORK}/vscodeaddon"
    "${HERE}/pack-vscode-addon.sh" ${VS_ARGS[@]+"${VS_ARGS[@]}"} --out="${WORK}/vscodeaddon" \
        --name=vscode-addon --no-tar >/dev/null \
        || die "pack-vscode-addon.sh failed for the bundle's vscode-addon (vendor files missing or not matching its pins? pass --vscode-vendor=DIR, or --no-vscode-addon to ship none)"
    [ -d "${WORK}/vscodeaddon/vscode-addon" ] || die "pack-vscode-addon.sh staged no vscode-addon"
    rm -rf "${BUNDLE}/vscode-addon"
    mv "${WORK}/vscodeaddon/vscode-addon" "${BUNDLE}/vscode-addon"
    VSCODE_VER="$(sed -n 's/^vscode_version=//p' "${BUNDLE}/vscode-addon/MANIFEST.env" | head -1)"
    CC_EXT_VER="$(sed -n 's/^claude_code_ext_version=//p' "${BUNDLE}/vscode-addon/MANIFEST.env" | head -1)"
    FOAM_VER="$(sed -n 's/^foam_version=//p' "${BUNDLE}/vscode-addon/MANIFEST.env" | head -1)"
    echo "    vscode-addon/ (install-all.sh 6th step, VS Code ${VSCODE_VER}, Claude Code extension ${CC_EXT_VER})"
else
    # A re-run on an already merged bundle must not keep an old copy.
    rm -rf "${BUNDLE}/vscode-addon"
    echo "    vscode-addon/: skipped (--no-vscode-addon)"
fi

# ---- 4e. HOP viewer ----------------------------------------------------------------------
# The HOP viewer install-all.sh runs as its 7th step, the last one. pack-hop-viewer.sh checks its own
# vendor dmg (pins, seal, team, the stapled ticket) and stages into WORK first, like §4c and §4d: a
# failed pack never costs the bundle the copy it already had, and only a complete staged folder is
# moved in.
HOP_VER=""
if [ "${DO_HOP}" = 1 ]; then
    log "HOP viewer"
    HOP_ARGS=()
    if [ -n "${HOP_VENDOR}" ]; then HOP_ARGS+=(--vendor="${HOP_VENDOR}"); fi
    rm -rf "${WORK}/hopviewer"
    "${HERE}/pack-hop-viewer.sh" ${HOP_ARGS[@]+"${HOP_ARGS[@]}"} --out="${WORK}/hopviewer" \
        --name=hop-viewer --no-tar >/dev/null \
        || die "pack-hop-viewer.sh failed for the bundle's hop-viewer (vendor dmg missing or not matching its pins? pass --hop-vendor=DIR, or --no-hop-viewer to ship none)"
    [ -d "${WORK}/hopviewer/hop-viewer" ] || die "pack-hop-viewer.sh staged no hop-viewer"
    rm -rf "${BUNDLE}/hop-viewer"
    mv "${WORK}/hopviewer/hop-viewer" "${BUNDLE}/hop-viewer"
    HOP_VER="$(sed -n 's/^hop_version=//p' "${BUNDLE}/hop-viewer/MANIFEST.env" | head -1)"
    echo "    hop-viewer/ (install-all.sh 7th step, HOP ${HOP_VER})"
else
    # A re-run on an already merged bundle must not keep an old copy.
    rm -rf "${BUNDLE}/hop-viewer"
    echo "    hop-viewer/: skipped (--no-hop-viewer)"
fi

# A secret must never ride along, whatever the source tree holds. Third-party wheels and LM Studio
# ship files like certifi's cacert.pem, so the broad patterns (*.pem, *.key, ...) apply only to the
# folders this script assembles from our own sources (claude-code/, wiki-mcp-kit/, vscode-addon/,
# hop-viewer/); the whole bundle gets only names that are ours and always secret or live data.
# Captured, never piped into a short-exit grep: with many matches that pipeline dies of SIGPIPE and
# reads as "no secrets found". It runs after §4b, §4c, §4d and §4e so claude-kit, the wiki-mcp kit,
# the VS Code add-on and the HOP viewer are scanned with everything else.
found="$(find "${BUNDLE}" \( -name '.env' -o -name '.env.*' -o -name '.webui_secret_key' \
    -o -name '.gitea.env' -o -name 'webui.db*' \) -print)" || die "cannot scan ${BUNDLE} for secrets"
[ -z "${found}" ] || die "a secret or data file ended up in the bundle"
# found is empty here unless a scan below just matched (claude-code absent leaves scan 1's empty value).
if [ -d "${BUNDLE}/claude-code" ]; then
    found="$(find "${BUNDLE}/claude-code" \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \
        -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '.webui_secret_key' -o -name '.gitea.env' \
        -o -name 'webui.db*' -o -name '*key*.json' \) -print)" || die "cannot scan ${BUNDLE}/claude-code for secrets"
fi
[ -z "${found}" ] || die "a secret or data file ended up in the bundle"
if [ -d "${BUNDLE}/wiki-mcp-kit" ]; then
    found="$(find "${BUNDLE}/wiki-mcp-kit" \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \
        -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '.webui_secret_key' -o -name '.gitea.env' \
        -o -name 'webui.db*' -o -name '*key*.json' \) -print)" || die "cannot scan ${BUNDLE}/wiki-mcp-kit for secrets"
fi
[ -z "${found}" ] || die "a secret or data file ended up in the bundle"
if [ -d "${BUNDLE}/vscode-addon" ]; then
    found="$(find "${BUNDLE}/vscode-addon" \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \
        -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '.webui_secret_key' -o -name '.gitea.env' \
        -o -name 'webui.db*' -o -name '*key*.json' \) -print)" || die "cannot scan ${BUNDLE}/vscode-addon for secrets"
fi
[ -z "${found}" ] || die "a secret or data file ended up in the bundle"
if [ -d "${BUNDLE}/hop-viewer" ]; then
    found="$(find "${BUNDLE}/hop-viewer" \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \
        -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '.webui_secret_key' -o -name '.gitea.env' \
        -o -name 'webui.db*' -o -name '*key*.json' \) -print)" || die "cannot scan ${BUNDLE}/hop-viewer for secrets"
fi
[ -z "${found}" ] || die "a secret or data file ended up in the bundle"

# ---- 5. prove the offline install ---------------------------------------------------------
log "offline install test into a fresh venv (pip check)"
"${BPY}" -m venv "${WORK}/venv"
"${WORK}/venv/bin/python" -m pip install --no-index --find-links "${BUNDLE}/wheels" --find-links "${LAYER}/wheels" \
    --quiet --disable-pip-version-check open-webui mcpo wiki-mcp python-docx python-pptx openpyxl
"${WORK}/venv/bin/python" -m pip check --disable-pip-version-check
# The hwpx skill's wheel must run on this venv's lxml: from-md + validate on a copy in WORK, never inside the
# bundle itself (it must not grow a __pycache__).
if [ -n "${CLAUDE_BIN}" ]; then
    mkdir -p "${WORK}/skilltest"
    cp -R "${BUNDLE}/claude-code/claude-kit/skills/hwpx" "${WORK}/skilltest/hwpx"
    chmod 755 "${WORK}/skilltest/hwpx/scripts/hwpx"
    /usr/bin/unzip -qo "${BUNDLE}/claude-code/claude-kit/wheels/python_hwpx-6.11.0-py3-none-any.whl" \
        -d "${WORK}/skilltest/hwpx/lib"
    printf '# 시험\n\n본문\n' >"${WORK}/skilltest/a.md"
    CLAUDE_LMS_PY="${WORK}/venv/bin/python" "${WORK}/skilltest/hwpx/scripts/hwpx" \
        from-md "${WORK}/skilltest/a.md" "${WORK}/skilltest/a.hwpx" >/dev/null \
        || die "python-hwpx from the bundled wheel does not run in the test venv"
    SKILL_LINE1="$(CLAUDE_LMS_PY="${WORK}/venv/bin/python" "${WORK}/skilltest/hwpx/scripts/hwpx" \
        validate "${WORK}/skilltest/a.hwpx" 2>&1 | head -1 || true)"
    case "${SKILL_LINE1}" in
        OK*) ;;
        *) die "the bundled hwpx skill does not validate its own from-md output in the test venv" ;;
    esac
    echo "    hwpx skill: its wheel runs in the test venv (from-md + validate OK)"
    # The office skills import python-docx/openpyxl/python-pptx from the same venv (§3 of the installer installs
    # these very tools). Each copy in WORK is proven from-md + read, never the bundle's own copy — the bundle must
    # not grow a __pycache__. The read's first line is captured, never piped into grep -q (SIGPIPE under pipefail).
    for s in ${OFFICE_SKILLS}; do
        cp -R "${BUNDLE}/claude-code/claude-kit/skills/${s}" "${WORK}/skilltest/${s}"
        chmod 755 "${WORK}/skilltest/${s}/scripts/${s}"
        # xlsx refuses markdown without a table, so the sample carries a GFM table for all three.
        printf '# 시험\n\n## 표\n\n| 항목 | 값 |\n| --- | --- |\n| 가 | 1 |\n' >"${WORK}/skilltest/o.md"
        CLAUDE_LMS_PY="${WORK}/venv/bin/python" "${WORK}/skilltest/${s}/scripts/${s}" \
            from-md "${WORK}/skilltest/o.md" "${WORK}/skilltest/o.${s}" >/dev/null \
            || die "the bundled ${s} skill does not run in the test venv (from-md)"
        OFFICE_LINE1="$(CLAUDE_LMS_PY="${WORK}/venv/bin/python" "${WORK}/skilltest/${s}/scripts/${s}" \
            read "${WORK}/skilltest/o.${s}" 2>&1 | head -1 || true)"
        case "${OFFICE_LINE1}" in
            OK*) ;;
            *) die "the bundled ${s} skill does not read its own from-md output in the test venv" ;;
        esac
    done
    echo "    office skills: docx xlsx pptx run in the test venv (from-md + read OK)"
fi
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
# The kit (§4c) must ship the same wiki-mcp as the wiki layer's wheels: its shared HTTP server and
# mcpo's stdio fallback would otherwise be two different wiki-mcp versions on one Mac.
KIT_VER="$(sed -n 's/^wiki_mcp=//p' "${BUNDLE}/wiki-mcp-kit/MANIFEST.env" | head -1)"
[ "${KIT_VER}" = "${WIKI_VER}" ] \
    || die "wiki-mcp-kit ships wiki-mcp ${KIT_VER}, but the wiki layer's wheels install ${WIKI_VER}"

# ---- 6. manifests -------------------------------------------------------------------------
log "manifests"
# app_version and min_macos follow the app in the shipped dmg: the guardian installer checks min_macos, and
# install-all.sh compares app_version with an installed LM Studio to decide whether to replace it.
# The VS Code versions were read from vscode-addon/MANIFEST.env in §4d (VSCODE_VER, CC_EXT_VER,
# FOAM_VER); the HOP version comes from hop-viewer/MANIFEST.env in §4e (HOP_VER).
if [ -d "${BUNDLE}/vscode-addon" ]; then
    [ -n "${VSCODE_VER}" ] || die "${BUNDLE}/vscode-addon/MANIFEST.env has no vscode_version"
    [ -n "${CC_EXT_VER}" ] || die "${BUNDLE}/vscode-addon/MANIFEST.env has no claude_code_ext_version"
    [ -n "${FOAM_VER}" ] || die "${BUNDLE}/vscode-addon/MANIFEST.env has no foam_version"
fi
if [ -d "${BUNDLE}/hop-viewer" ]; then
    [ -n "${HOP_VER}" ] || die "${BUNDLE}/hop-viewer/MANIFEST.env has no hop_version"
fi
grep -v -E "^(app_version|min_macos|app_dmg|python|open_webui|mcpo|wiki_mcp|wiki_mcp_kit|embedding_model|claude_code|vscode|vscode_claude_ext|vscode_foam|hop)=|^model=${EMB_UNIT}\$" \
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
    echo "wiki_mcp_kit=${KIT_VER}"
    echo "model=${EMB_UNIT}"
    echo "embedding_model=${EMB_ID}"
    if [ -n "${CC_VER}" ]; then echo "claude_code=${CC_VER}"; fi
    if [ -d "${BUNDLE}/vscode-addon" ]; then
        echo "vscode=${VSCODE_VER}"
        echo "vscode_claude_ext=${CC_EXT_VER}"
        echo "vscode_foam=${FOAM_VER}"
    fi
    if [ -d "${BUNDLE}/hop-viewer" ]; then
        echo "hop=${HOP_VER}"
    fi
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
