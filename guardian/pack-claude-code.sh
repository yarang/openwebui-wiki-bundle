#!/usr/bin/env bash
# ==============================================================================
# Claude Code alone → a kit to copy to another Mac (run on the build Mac)
#
# Packs the same claude-code/ folder build-merged-bundle.sh §4b puts in the big bundle, but on its
# own — no LM Studio, models or Open WebUI — for a Mac that already has those:
#   <name>/                the kit folder, kept next to the archive for inspection: claude (the
#                          native binary, Anthropic-signed, checked), VERSION, install-claude-code.sh,
#                          claude-lms, claude-vscode (the VS Code extension's claudeProcessWrapper,
#                          reading the same env file), llm-router/ (the local Anthropic proxy:
#                          router.py, spark-model, install-llm-router.sh, env.example, README.md —
#                          never its tests or spark/), claude-kit/ (the hwpx, docx, xlsx and pptx
#                          skills, the python-hwpx wheel and system-prompt.md, never the dev tests)
#                          and SHA256SUMS over every file
#   <name>.tar.gz          the same folder, gzip-compressed; a clean Mac's /usr/bin/tar reads it
#   <name>.tar.gz.sha256   checked on the target Mac before anything is extracted
# The archive is listed back with /usr/bin/tar before the .sha256 is written, so a damaged archive
# never gets one. An existing folder, archive or .sha256 is never replaced: move it away first.
# Nothing secret rides along: .env, .webui_secret_key and key files never get in.
#
# Usage:  guardian/pack-claude-code.sh [--claude-code=PATH] [--out=DIR] [--name=NAME] [--no-tar]
#   --claude-code=PATH    Claude Code binary to ship (default the build Mac's own, ~/.local/bin/claude)
#   --out=DIR             output folder (default: ../dist/claude-code-kit, next to guardian/)
#   --name=NAME           output name (default claude-code-kit-<claude version>-<UTC stamp>-macos-arm64;
#                         letters, digits, . _ - only, and it must start with a letter or digit)
#   --no-tar              stop after the folder (with SHA256SUMS) is complete; no .tar.gz is written
# On the target Mac:  shasum -a 256 -c <name>.tar.gz.sha256 && tar xzf <name>.tar.gz && cd <name> \
#   && shasum -a 256 -c SHA256SUMS && ./install-claude-code.sh --dry-run
# ==============================================================================

set -euo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/.." && pwd)"
CLAUDE_BIN="${HOME}/.local/bin/claude"
OUT=""
NAME=""
NAME_SET=0
DO_TAR=1

for arg in "$@"; do
    case "${arg}" in
        --claude-code=*)
            CLAUDE_BIN="${arg#--claude-code=}"
            [ -n "${CLAUDE_BIN}" ] || { echo "error: --claude-code= needs a path" >&2; exit 2; } ;;
        --out=*)
            OUT="${arg#--out=}"
            [ -n "${OUT}" ] || { echo "error: --out= needs a directory" >&2; exit 2; } ;;
        --name=*) NAME="${arg#--name=}"; NAME_SET=1 ;;
        --no-tar) DO_TAR=0 ;;
        -h|--help) sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: ${arg}" >&2; exit 2 ;;
        *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# The python-hwpx wheel the hwpx skill vendors into ~/.claude/skills/hwpx/lib; the kit ships exactly
# this one. Byte-for-byte the same line as build-merged-bundle.sh (tests compare them).
HWPX_WHL_SHA256="4b8369414dcbf32036cf9ac7f9dbfe3dd78d0f62230969034e6e6b5085912a62"
# The office skills ship beside hwpx with no wheel: their tools import docx/openpyxl/pptx from the target Mac's
# python. Byte-for-byte the same line as build-merged-bundle.sh (tests compare them).
OFFICE_SKILLS="docx xlsx pptx"
# The llm-router ships as its own folder in the kit: exactly these five files. Its dev tests and the DGX Spark
# controller (spark/) stay out — the controller is installed on the Spark from the repo, not by this kit.
# Byte-for-byte the same line as build-merged-bundle.sh (tests compare them).
LLM_ROUTER_FILES="router.py spark-model install-llm-router.sh env.example README.md"
EXCL=(--exclude='.DS_Store' --exclude='__pycache__/' --exclude='*.pyc' --exclude='*.bak' --exclude='*.bak.*' --exclude='.obsidian/')

# ---- 1. everything that can be refused is refused before a single folder is made ------------
# Whole-string match (a line-based grep would pass a name holding a newline, e.g. ok<newline>/../evil).
valid_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; }
if [ "${NAME_SET}" = 1 ]; then
    # An explicitly empty --name= is refused, never quietly replaced by the default name.
    [ -n "${NAME}" ] || die "--name= must not be empty"
    valid_name "${NAME}" || die "--name must be letters, digits, . _ or - and start with a letter or digit: ${NAME}"
fi

[ -e "${CLAUDE_BIN}" ] || die "${CLAUDE_BIN} is missing: pass --claude-code=PATH"
CLAUDE_BIN="$(readlink -f "${CLAUDE_BIN}")"
[ -f "${CLAUDE_BIN}" ] && [ -x "${CLAUDE_BIN}" ] || die "${CLAUDE_BIN} is not an executable file"
codesign --verify --strict "${CLAUDE_BIN}" || die "${CLAUDE_BIN} does not verify"
# Captured, never piped into a short-exit grep: under set -o pipefail that race fails a good
# signature about 2 runs in 3 (grep leaves, codesign still has lines to write, SIGPIPE).
CS_INFO="$(codesign -dv "${CLAUDE_BIN}" 2>&1)" || die "cannot read the signature of ${CLAUDE_BIN}"
grep -qx 'TeamIdentifier=Q6L2SF6YDW' <<<"${CS_INFO}" || die "${CLAUDE_BIN} is not signed by Anthropic"
grep -qx 'Identifier=com.anthropic.claude-code' <<<"${CS_INFO}" || die "${CLAUDE_BIN} is not Claude Code"
VER_OUT="$("${CLAUDE_BIN}" --version 2>&1)" || die "cannot read the version of ${CLAUDE_BIN}"
CC_VER="$(awk 'NR==1{print $1; exit}' <<<"${VER_OUT}")"
[[ "${CC_VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die "no x.y.z version out of ${CLAUDE_BIN}: '${CC_VER}'"

[ -n "${NAME}" ] || NAME="claude-code-kit-${CC_VER}-$(date -u +%Y%m%dT%H%MZ)-macos-arm64"
valid_name "${NAME}" || die "the default name from claude --version ('${CC_VER}') is not a safe file name"

# Everything the kit ships must already be here, and the wheel must be the pinned one.
WHL="claude-kit/wheels/python_hwpx-6.11.0-py3-none-any.whl"
for f in "${HERE}/install-claude-code.sh" "${HERE}/claude-lms" "${HERE}/claude-vscode" \
    "${HERE}/claude-kit/system-prompt.md" \
    "${HERE}/claude-kit/skills/hwpx/scripts/hwpx" "${HERE}/claude-kit/skills/hwpx/scripts/skill-guard" \
    "${HERE}/${WHL}"; do
    [ -f "${f}" ] || die "${f} is missing"
done
# Each office skill is three files — SKILL.md, its wrapper, its tool — and no wheel.
for s in ${OFFICE_SKILLS}; do
    for f in "${HERE}/claude-kit/skills/${s}/SKILL.md" "${HERE}/claude-kit/skills/${s}/scripts/${s}" \
        "${HERE}/claude-kit/skills/${s}/scripts/${s}_tool.py"; do
        [ -f "${f}" ] || die "${f} is missing"
    done
done
# The router folder the kit ships: the five files install-claude-code.sh --with-router installs, and no more.
for f in ${LLM_ROUTER_FILES}; do
    [ -f "${HERE}/llm-router/${f}" ] || die "${HERE}/llm-router/${f} is missing"
done
[ "$(shasum -a 256 "${HERE}/${WHL}" | awk '{print $1}')" = "${HWPX_WHL_SHA256}" ] \
    || die "claude-kit/wheels holds a python-hwpx wheel that is not the pinned sha256 ${HWPX_WHL_SHA256}"

OUT="${OUT:-${SRC}/dist/claude-code-kit}"
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

# Whatever this run staged is removed on failure; nothing else is ever removed. Each path below is
# recorded only once this run has created it, so a run that loses a race never deletes another run's
# work, and a failure of step 3 leaves nothing of this run behind at all.
PARTIAL=""
KIT_DIR=""
TAR_GZ=""
SHA_FILE=""
VERIFY_TMP=""
cleanup() {
    rc=$?
    if [ -n "${VERIFY_TMP}" ]; then rm -rf "${VERIFY_TMP:?}"; fi
    if [ "${rc}" -ne 0 ]; then
        if [ -n "${PARTIAL}" ]; then rm -rf "${PARTIAL:?}"; fi
        if [ -n "${SHA_FILE}" ]; then rm -f "${SHA_FILE:?}"; fi
        if [ -n "${TAR_GZ}" ]; then rm -f "${TAR_GZ:?}"; fi
        if [ -n "${KIT_DIR}" ]; then rm -rf "${KIT_DIR:?}"; fi
    fi
}
trap cleanup EXIT

# ---- 2. stage the kit (same contents and checks as build-merged-bundle.sh §4b) --------------
log "Claude Code ${CC_VER} → ${NAME}"
# Plain mkdir, no -p: a run that loses the race to a second run fails here, before PARTIAL is
# recorded, so its cleanup can never remove the other run's staging folder.
mkdir "${KIT}.partial" || die "cannot create ${KIT}.partial"
PARTIAL="${KIT}.partial"
cp "${CLAUDE_BIN}" "${PARTIAL}/claude"
cmp -s "${CLAUDE_BIN}" "${PARTIAL}/claude" || die "copy of ${CLAUDE_BIN} does not match"
echo "${CC_VER}" >"${PARTIAL}/VERSION"
cp "${HERE}/install-claude-code.sh" "${HERE}/claude-lms" "${HERE}/claude-vscode" "${PARTIAL}/"
chmod 755 "${PARTIAL}/claude" "${PARTIAL}/install-claude-code.sh" "${PARTIAL}/claude-lms" "${PARTIAL}/claude-vscode"
# The llm-router folder, exactly the five files (no tests/, no spark/): its own installer runs from here on the
# target Mac only with --with-router, so a Mac without a Spark is unchanged.
mkdir -p "${PARTIAL}/llm-router"
for f in ${LLM_ROUTER_FILES}; do cp "${HERE}/llm-router/${f}" "${PARTIAL}/llm-router/"; done
chmod 755 "${PARTIAL}/llm-router/spark-model" "${PARTIAL}/llm-router/install-llm-router.sh"
# The skills the installer puts in ~/.claude/skills/<name>: their skills and the hwpx wheel, never the dev tests.
# system-prompt.md is installed by the same step into ~/.config/claude-lms (left off until
# CLAUDE_LMS_SYSTEM_PROMPT_FILE says otherwise).
mkdir -p "${PARTIAL}/claude-kit"
rsync -a "${EXCL[@]}" "${HERE}/claude-kit/skills" "${HERE}/claude-kit/wheels" "${PARTIAL}/claude-kit/"
cp "${HERE}/claude-kit/system-prompt.md" "${PARTIAL}/claude-kit/system-prompt.md"
# rsync -a preserves symlinks: on the target Mac a link out of the kit dangles, and chmod on it
# would change whatever it points to. None may be staged — before any chmod and before SHA256SUMS.
links="$(find "${PARTIAL}" -type l -print)" || die "cannot scan ${PARTIAL} for symlinks"
[ -z "${links}" ] || die "a symlink ended up in the kit: $(head -3 <<<"${links}")"
[ "$(shasum -a 256 "${PARTIAL}/${WHL}" | awk '{print $1}')" = "${HWPX_WHL_SHA256}" ] \
    || die "the python-hwpx wheel shipped in the kit is not the pinned sha256 ${HWPX_WHL_SHA256}"
chmod 755 "${PARTIAL}/claude-kit/skills/hwpx/scripts/hwpx" "${PARTIAL}/claude-kit/skills/hwpx/scripts/skill-guard"
for s in ${OFFICE_SKILLS}; do chmod 755 "${PARTIAL}/claude-kit/skills/${s}/scripts/${s}"; done

# A secret must never ride along, whatever the source tree holds. Captured, never piped into a
# short-exit grep: with many matches that pipeline dies of SIGPIPE and reads as "no secrets found".
found="$(find "${PARTIAL}" \( -name '.env' -o -name '.env.*' -o -name '*.pem' -o -name '*.key' \
    -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name '.webui_secret_key' -o -name '.gitea.env' \
    -o -name 'webui.db*' -o -name '*key*.json' \) -print)" || die "cannot scan ${PARTIAL} for secrets"
[ -z "${found}" ] || die "a secret or data file ended up in the kit"

(cd "${PARTIAL}" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
(cd "${PARTIAL}" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "SHA256SUMS does not match the staged files"
mv "${PARTIAL}" "${KIT}"
PARTIAL=""
KIT_DIR="${KIT}"
echo "    kit folder done: $(du -sh "${KIT}" | awk '{print $1}') in ${OUT}"

# ---- 3. archive ------------------------------------------------------------------------------
if [ "${DO_TAR}" = 1 ]; then
    log "archive ${NAME}.tar.gz"
    TARB="${KIT}.tar.gz.partial"
    [ ! -e "${TARB}" ] || die "${TARB} already exists"
    PARTIAL="${TARB}"
    COPYFILE_DISABLE=1 /usr/bin/tar -C "${OUT}" -czf "${TARB}" "${NAME}"
    want="$(cd "${OUT}" && find "${NAME}" | wc -l | tr -d ' ')"
    got="$(/usr/bin/tar -tzf "${TARB}" | wc -l | tr -d ' ')"
    [ "${got}" = "${want}" ] || die "the archive lists ${got} entries, the folder has ${want}"
    # Prove what a clean Mac would unpack: extract into a fresh folder and verify SHA256SUMS there;
    # the file list must match SHA256SUMS exactly, so a stray .DS_Store or ._ resource fork fails
    # here and never reaches the target Mac. Only then does the archive get its .sha256.
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
fi

# ---- 4. what to do on the target Mac ---------------------------------------------------------
if [ "${DO_TAR}" = 1 ]; then
    log "done: copy ${NAME}.tar.gz and ${NAME}.tar.gz.sha256 into one folder on the target Mac"
    (cd "${OUT}" && ls -lh "${NAME}.tar.gz" "${NAME}.tar.gz.sha256" | awk '{print "    " $5 "  " $NF}')
    echo "    sha256 $(awk '{print $1}' "${KIT}.tar.gz.sha256")"
    echo "Then on the target Mac:"
    echo "  shasum -a 256 -c ${NAME}.tar.gz.sha256 && tar xzf ${NAME}.tar.gz && cd ${NAME} && shasum -a 256 -c SHA256SUMS && ./install-claude-code.sh --dry-run"
else
    log "done (--no-tar): the kit folder ${KIT} is complete with its SHA256SUMS"
fi
