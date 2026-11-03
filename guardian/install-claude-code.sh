#!/bin/bash
# ==============================================================================
# Claude Code installer (offline): the claude binary in this folder, plus claude-lms, which runs it on LM Studio
#
# Puts the binary where Claude Code's own native installer does (~/.local/share/claude/versions/<version>, linked
# from ~/.local/bin/claude), so `claude update` and a later official install work on it as usual. A same or newer
# claude already installed is kept. claude-lms goes to ~/.local/bin, its settings to ~/.config/claude-lms/env.
# The folder can be copied to a Mac on its own; install-all.sh runs it as the bundle's last step.
#
# Usage:  ./install-claude-code.sh [options]
#   --model=ID         LM Studio model claude-lms uses (default: the one in ~/.config/claude-lms/env, else the
#                      wiki's WIKI_INGEST_MODEL in ~/llm-wiki/.env, else the first LLM LM Studio lists)
#   --context=N        least context length claude-lms loads the model with (default 65536)
#   --lmstudio-url=URL LM Studio server (default http://127.0.0.1:1234)
#   --no-path          do not add ~/.local/bin to PATH in ~/.zshrc
#   --dry-run          show what would change
# ==============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL=""
CTX=""
URL=""
DO_PATH=1
DRY=0

for arg in "$@"; do
    case "${arg}" in
        --model=*) MODEL="${arg#--model=}" ;;
        --context=*) CTX="${arg#--context=}" ;;
        --lmstudio-url=*) URL="${arg#--lmstudio-url=}" ;;
        --no-path) DO_PATH=0 ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
note() { echo "    $*"; }
run() { if [ "${DRY}" = 1 ]; then note "[dry-run] $*"; else "$@"; fi; }

# Anthropic's Developer ID team and the binary's signing identifier.
TEAM="Q6L2SF6YDW"
IDENT="com.anthropic.claude-code"
BIN="${HERE}/claude"
VERSIONS="${HOME}/.local/share/claude/versions"
LINK="${HOME}/.local/bin/claude"
CONF_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/claude-lms"
CONF="${CONF_DIR}/env"

# Same comparison as install-all.sh: the numeric part only.
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

# A bare Mach-O carries no stapled ticket, so it is checked here rather than by a Gatekeeper lookup that needs the
# internet: the seal must verify and be Anthropic's.
check_binary() {
    local info
    codesign --verify --strict "$1" || return 1
    info="$(codesign -dv "$1" 2>&1)"
    printf '%s\n' "${info}" | grep -qx "TeamIdentifier=${TEAM}" || return 1
    printf '%s\n' "${info}" | grep -qx "Identifier=${IDENT}"
}

[ -f "${BIN}" ] || die "${BIN} is missing"
[ -f "${HERE}/VERSION" ] || die "${HERE}/VERSION is missing"
VER="$(head -1 "${HERE}/VERSION")"
check_binary "${BIN}" || die "${BIN} is not Anthropic's signed Claude Code"

# ---- 1. binary ----------------------------------------------------------------------------
echo "==> Claude Code ${VER}"
cur=""
if [ -L "${LINK}" ]; then
    cur="$(basename "$(readlink "${LINK}")")"
elif [ -e "${LINK}" ]; then
    die "${LINK} exists and is not a link to a native install: move it away first"
fi
if [ -n "${cur}" ] && [ -x "${VERSIONS}/${cur}" ] && version_ge "${cur}" "${VER}"; then
    note "installed ${cur} is the same or newer: kept"
else
    if [ -f "${VERSIONS}/${VER}" ] && cmp -s "${BIN}" "${VERSIONS}/${VER}"; then
        note "${VERSIONS}/${VER} already there"
    else
        run mkdir -p "${VERSIONS}"
        run cp "${BIN}" "${VERSIONS}/${VER}.partial"
        # Copied by USB or the network, the binary is quarantined; it was checked above, so only that flag goes.
        if [ "${DRY}" = 0 ]; then
            xattr -d com.apple.quarantine "${VERSIONS}/${VER}.partial" 2>/dev/null || true
            chmod 755 "${VERSIONS}/${VER}.partial"
            check_binary "${VERSIONS}/${VER}.partial" || die "the copied binary does not verify"
        fi
        run mv "${VERSIONS}/${VER}.partial" "${VERSIONS}/${VER}"
    fi
    run mkdir -p "$(dirname "${LINK}")"
    run ln -sfn "${VERSIONS}/${VER}" "${LINK}"
    note "${LINK} -> ${VERSIONS}/${VER}$([ -n "${cur}" ] && echo " (was ${cur}, kept in ${VERSIONS})")"
fi

# ---- 2. claude-lms and its settings -------------------------------------------------------
echo "==> claude-lms"
run cp "${HERE}/claude-lms" "${HOME}/.local/bin/claude-lms"
run chmod 755 "${HOME}/.local/bin/claude-lms"
OLD_MODEL=""; OLD_URL=""; OLD_CTX=""
if [ -f "${CONF}" ]; then
    OLD_MODEL="$(sed -n 's/^CLAUDE_LMS_MODEL=//p' "${CONF}" | tail -1 | tr -d "'\"")"
    OLD_URL="$(sed -n 's/^CLAUDE_LMS_URL=//p' "${CONF}" | tail -1 | tr -d "'\"")"
    OLD_CTX="$(sed -n 's/^CLAUDE_LMS_CONTEXT=//p' "${CONF}" | tail -1 | tr -d "'\"")"
fi
[ -n "${URL}" ] || URL="${OLD_URL:-http://127.0.0.1:1234}"
URL="${URL%/}"
[ -n "${CTX}" ] || CTX="${OLD_CTX:-65536}"
case "${CTX}" in *[!0-9]*|'') die "--context must be a number" ;; esac
# LM Studio names a model after where its files sit, so the id differs between Macs (google/gemma-4-e4b here,
# gemma-4-e4b-it-mlx from the bundle): take the one this Mac's wiki already uses, which also keeps one model loaded.
src="--model"
if [ -z "${MODEL}" ] && [ -n "${OLD_MODEL}" ]; then MODEL="${OLD_MODEL}"; src="${CONF}"; fi
if [ -z "${MODEL}" ] && [ -f "${HOME}/llm-wiki/.env" ]; then
    MODEL="$(sed -n 's/^WIKI_INGEST_MODEL=//p' "${HOME}/llm-wiki/.env" | tail -1 | tr -d "'\"")"
    src="WIKI_INGEST_MODEL"
fi
# Model ids LM Studio lists, one per line (plutil reads JSON: a clean Mac has no python3).
list_ids() {
    local json i=0 id
    json="$(curl -fsS -m 5 "${URL}/v1/models" 2>/dev/null)" || return 0
    while id="$(printf '%s' "${json}" | plutil -extract "data.${i}.id" raw -o - - 2>/dev/null)"; do
        echo "${id}"
        i=$((i + 1))
    done
}
IDS="$(list_ids)"
if [ -z "${MODEL}" ]; then
    MODEL="$(printf '%s\n' "${IDS}" | grep -v -i -E 'embed|bge|nomic' | head -1 || true)"
    src="LM Studio's first LLM"
fi
[ -n "${MODEL}" ] || die "no model to use: pass --model=ID (LM Studio is not answering at ${URL}, or has no LLM)"
if [ -z "${IDS}" ]; then
    note "warning: LM Studio does not answer at ${URL}; ${MODEL} is not checked"
elif ! printf '%s\n' "${IDS}" | grep -qxF "${MODEL}"; then
    die "LM Studio at ${URL} has no model ${MODEL}; it lists: $(printf '%s' "${IDS}" | tr '\n' ' ')"
fi
if [ "${DRY}" = 1 ]; then
    note "[dry-run] ${CONF}: model ${MODEL} (from ${src}), context ${CTX}, ${URL}"
else
    mkdir -p "${CONF_DIR}"
    {
        echo "# claude-lms settings (install-claude-code.sh). The same names in the environment win."
        echo "CLAUDE_LMS_MODEL='${MODEL}'"
        echo "CLAUDE_LMS_URL='${URL}'"
        echo "CLAUDE_LMS_CONTEXT=${CTX}"
    } >"${CONF}.partial"
    mv "${CONF}.partial" "${CONF}"
    note "${CONF}: model ${MODEL} (from ${src}), context ${CTX}, ${URL}"
fi

# ---- 3. PATH -------------------------------------------------------------------------------
# A Mac's zsh does not have ~/.local/bin on PATH; one marked block is added once.
MARK="# >>> claude-code (llm-wiki bundle) >>>"
if [ "${DO_PATH}" = 0 ]; then
    note "--no-path: PATH left alone"
elif grep -qsF "${MARK}" "${HOME}/.zshrc" || grep -qs '^[^#]*\.local/bin' "${HOME}/.zshrc" "${HOME}/.zprofile"; then
    note "~/.local/bin already on PATH in ~/.zshrc or ~/.zprofile"
elif [ "${DRY}" = 1 ]; then
    note "[dry-run] add ~/.local/bin to PATH in ~/.zshrc"
else
    printf '\n%s\nexport PATH="$HOME/.local/bin:$PATH"\n# <<< claude-code (llm-wiki bundle) <<<\n' "${MARK}" >>"${HOME}/.zshrc"
    note "added ~/.local/bin to PATH in ~/.zshrc (new terminals)"
fi
echo "    run: claude-lms        (Claude Code on LM Studio's ${MODEL}; plain claude needs an Anthropic login)"
