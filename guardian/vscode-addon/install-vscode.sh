#!/bin/bash
# ==============================================================================
# VS Code add-on installer (runs on the site Mac, from inside the extracted add-on folder;
# that Mac has no internet and no VS Code. The wiki is already at ~/llm-wiki/wiki and,
# when the Claude Code kit is present, ~/.local/bin/claude-lms reads ~/.config/claude-lms/env.)
#
# Steps: 0 SHA256SUMS + MANIFEST  1 the VS Code app from app/*.dmg  2 the Foam and Claude Code
#        extensions  3 quarantine off the Claude native binary  4 user settings (offline +
#        claudeCode.environmentVariables)  5 the wiki workspace files  6 summary.
#
# Usage:  ./install-vscode.sh [options]
#   --dry-run            print every action, change nothing
#   --no-app             skip step 1 (the VS Code app)
#   --no-extensions      skip step 2 (both extensions)
#   --no-settings        skip step 4 (user settings)
#   --no-wiki            skip step 5 (the wiki workspace files)
#   --pick-models        router mode: pick 1-4 models from <router>/v1/models for the extension
#                        model picker (CLAUDE_LMS_PICKER='id1 id2 ...' is the same without a prompt)
#   --wiki=DIR           wiki folder (default ~/llm-wiki/wiki)
#   --app-dir=DIR        where the app goes (default /Applications; tests use a temp dir)
#   --user-data-dir=DIR  passed to the code CLI; settings then live in <dir>/User/settings.json
#   --extensions-dir=DIR passed to the code CLI (default ~/.vscode/extensions)
# Undo: drag the app to the Trash; code --uninstall-extension <id>; delete the settings entries.
# ==============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY=0
DO_APP=1
DO_EXT=1
DO_SETTINGS=1
DO_WIKI=1
WIKI_OPT=""
APP_DIR="/Applications"
USER_DATA=""
EXT_DIR_OPT=""
PICK_MODEL=0

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY=1 ;;
        --no-app) DO_APP=0 ;;
        --no-extensions) DO_EXT=0 ;;
        --no-settings) DO_SETTINGS=0 ;;
        --no-wiki) DO_WIKI=0 ;;
        --pick-models) PICK_MODEL=1 ;;
        --wiki=*) WIKI_OPT="${arg#--wiki=}" ;;
        --app-dir=*) APP_DIR="${arg#--app-dir=}" ;;
        --user-data-dir=*) USER_DATA="${arg#--user-data-dir=}" ;;
        --extensions-dir=*) EXT_DIR_OPT="${arg#--extensions-dir=}" ;;
        -h|--help) sed -n '3,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
# Same comparison as guardian/install-all.sh: the numeric part only, so 1.146.0 vs 1.99.2 works.
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

APP_NAME="Visual Studio Code.app"
CODE_IN_APP="Contents/Resources/app/bin/code"
CLI_ARGS=()

# An image still attached or a half-copied staging app is never left behind (as install-all.sh).
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

# ---- 0. add-on integrity ---------------------------------------------------------------------
step "0/6 add-on integrity (SHA256SUMS, MANIFEST.env)"
[ -f "${HERE}/SHA256SUMS" ] || die "SHA256SUMS is missing next to this script"
[ -f "${HERE}/MANIFEST.env" ] || die "MANIFEST.env is missing next to this script"
if ! (cd "${HERE}" && shasum -a 256 -c SHA256SUMS >/dev/null); then
    die "SHA256SUMS does not match the add-on files: copy the add-on folder again"
fi
note "SHA256SUMS ok"
for k in vscode_version vscode_team foam_version claude_code_ext_version claude_team \
    app_dmg foam_vsix claude_vsix; do
    [ -n "$(manifest "${k}")" ] || die "MANIFEST.env has no ${k}"
done
VSCODE_VER="$(manifest vscode_version)"
VSCODE_TEAM="$(manifest vscode_team)"
FOAM_VER="$(manifest foam_version)"
CC_EXT_VER="$(manifest claude_code_ext_version)"
CLAUDE_TEAM="$(manifest claude_team)"
APP_DMG="$(manifest app_dmg)"
FOAM_VSIX="$(manifest foam_vsix)"
CLAUDE_VSIX="$(manifest claude_vsix)"

# ---- 1. the VS Code app ----------------------------------------------------------------------
APP_RESULT="skipped (--no-app)"

# Mounts the dmg read-only, checks the app inside against the manifest, copies it with ditto into
# a staging dir under $2, clears quarantine on the staged app only and re-verifies the seal.
copy_app_from_dmg() {
    local dmg="$1" dest="$2" out mnt app ver bid cs
    MNT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vscode-dmg.XXXXXX")"
    out="$(hdiutil attach -readonly -nobrowse -noautoopen -mountrandom "${MNT_ROOT}" "${dmg}")" \
        || die "cannot mount ${dmg}"
    mnt="$(printf '%s\n' "${out}" | tail -1 | awk '{print $NF}')"
    DMG_MNT="${mnt}"
    [ -d "${mnt}/${APP_NAME}" ] || die "${dmg} has no ${APP_NAME}"
    app="${mnt}/${APP_NAME}"
    ver="$(defaults read "${app}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
    [ "${ver}" = "${VSCODE_VER}" ] || die "the app in the dmg is ${ver:-unknown}, the manifest says ${VSCODE_VER}"
    bid="$(defaults read "${app}/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
    [ "${bid}" = "com.microsoft.VSCode" ] || die "the app in the dmg is ${bid:-unknown}, not com.microsoft.VSCode"
    codesign --verify --deep --strict "${app}" || die "the app inside ${dmg} does not verify"
    # Captured, never piped into a short-exit grep: under set -o pipefail that race fails a good signature.
    cs="$(codesign -dv --verbose=2 "${app}" 2>&1)" || die "cannot read the signature of the app inside ${dmg}"
    grep -qx "TeamIdentifier=${VSCODE_TEAM}" <<<"${cs}" || die "the app inside ${dmg} is not signed by team ${VSCODE_TEAM}"
    # Copied next to its final place first, so an interrupted copy never sits where the version check looks.
    STAGE="$(mktemp -d "${dest}/.vscode-install.XXXXXX")"
    ditto "${app}" "${STAGE}/${APP_NAME}"
    hdiutil detach -quiet "${DMG_MNT}" 2>/dev/null || hdiutil detach -quiet -force "${DMG_MNT}" 2>/dev/null || true
    DMG_MNT=""
    rm -rf "${MNT_ROOT:?}"; MNT_ROOT=""
    # A dmg carried in by USB is quarantined, and so is what ditto takes out of it — this app only.
    xattr -dr com.apple.quarantine "${STAGE}/${APP_NAME}"
    codesign --verify --deep --strict "${STAGE}/${APP_NAME}" || die "the copied app does not verify"
}

install_app() {
    local dmg="${HERE}/${APP_DMG}" cur="" running old
    step "1/6 VS Code ${VSCODE_VER} app → ${APP_DIR}"
    [ -f "${dmg}" ] || die "${dmg} is missing"
    if [ -d "${APP_DIR}" ]; then
        [ -w "${APP_DIR}" ] || die "\"${APP_DIR}\" is not writable: pass --app-dir=DIR with a folder you can write to (this installer never uses sudo)"
    elif [ "${DRY}" = 1 ]; then
        note "[dry-run] mkdir -p \"${APP_DIR}\""
    else
        mkdir -p "${APP_DIR}" || die "cannot create ${APP_DIR}"
    fi
    if [ -d "${APP_DIR}/${APP_NAME}" ]; then
        cur="$(defaults read "${APP_DIR}/${APP_NAME}/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
    fi
    if [ -n "${cur}" ]; then
        if version_ge "${cur}" "${VSCODE_VER}"; then
            note "installed ${cur} is the same or newer: kept"
            APP_RESULT="kept installed ${cur} in ${APP_DIR}"
            return 0
        fi
        running="$(pgrep -f "${APP_DIR}/${APP_NAME}/Contents/MacOS/" 2>/dev/null || true)"
        [ -z "${running}" ] || die "VS Code ${cur} is running: quit VS Code first"
    fi
    if [ "${DRY}" = 1 ]; then
        [ -z "${cur}" ] || note "[dry-run] mv \"${APP_DIR}/${APP_NAME}\" aside as \"${APP_NAME}.old-${cur}.app\""
        note "[dry-run] mount ${dmg}, check version/bundle id/seal/team, ditto ${APP_NAME} into \"${APP_DIR}\", clear quarantine, move it into place"
        APP_RESULT="would install ${VSCODE_VER} into ${APP_DIR}"
        return 0
    fi
    copy_app_from_dmg "${dmg}" "${APP_DIR}"
    if [ -n "${cur}" ]; then
        old="${APP_DIR}/${APP_NAME}.old-${cur}.app"
        if [ -e "${old}" ]; then old="${APP_DIR}/${APP_NAME}.old-${cur}-$(date +%Y%m%d%H%M%S).app"; fi
        mv "${APP_DIR}/${APP_NAME}" "${old}"
        note "the older ${cur} was moved aside: ${old}"
    fi
    mv "${STAGE}/${APP_NAME}" "${APP_DIR}/${APP_NAME}"
    rmdir "${STAGE}"; STAGE=""
    note "installed ${VSCODE_VER} to ${APP_DIR}"
    APP_RESULT="installed ${VSCODE_VER} to ${APP_DIR}"
}

# ---- 2. extensions ---------------------------------------------------------------------------
EXT_RESULTS=""
CODE=""

# Case-insensitive: the Claude extension is id Anthropic.claude-code but the CLI may list
# anthropic.claude-code. The lowered list is captured before the loop (the pipefail SIGPIPE race),
# and neither ids nor versions carry spaces, so the word split into the array is safe.
ext_installed_version() {  # $1 = id, $2 = --list-extensions --show-versions output; prints the
    #                    installed version of the id, nothing when the id is not listed
    local id lower line
    id="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    lower="$(printf '%s\n' "$2" | tr '[:upper:]' '[:lower:]')"
    # shellcheck disable=SC2206  # one id@version per line, no spaces in either
    local -a lines=(${lower})
    for line in ${lines[@]+"${lines[@]}"}; do
        case "${line}" in
            "${id}"@*) printf '%s\n' "${line#*@}"; return 0 ;;
        esac
    done
    return 0
}

install_one_ext() {  # $1 = id, $2 = version, $3 = vsix path, $4 = --list-extensions output
    local id="$1" ver="$2" vsix="$3" listed="$4" cur
    cur="$(ext_installed_version "${id}" "${listed}")"
    # A site Mac may already carry a newer extension than this add-on pins (say the Claude Code
    # extension updated itself before auto-update went off): it is kept, never downgraded. Only an
    # absent or older one is installed — --force still covering the older case. Same numeric
    # compare as the app step above ("installed X is the same or newer: kept").
    if [ -n "${cur}" ] && version_ge "${cur}" "${ver}"; then
        note "${id}@${cur} is the same or newer than ${ver}: kept"
        EXT_RESULTS="${EXT_RESULTS}${id}@${cur} kept; "
        return 0
    fi
    [ -f "${vsix}" ] || die "${vsix} is missing"
    env VSCODE_CLI=1 "${CODE}" ${CLI_ARGS[@]+"${CLI_ARGS[@]}"} --install-extension "${vsix}" --force \
        || die "cannot install ${vsix}"
    note "installed ${id}@${ver}"
    EXT_RESULTS="${EXT_RESULTS}${id}@${ver} installed; "
}

# The dry-run half of install_one_ext: the same kept/installed decision, printed as a prediction.
dry_one_ext() {  # $1 = id, $2 = version, $3 = vsix path, $4 = --list-extensions output ("" = unknown)
    local id="$1" ver="$2" vsix="$3" listed="$4" cur
    cur="$(ext_installed_version "${id}" "${listed}")"
    if [ -n "${cur}" ] && version_ge "${cur}" "${ver}"; then
        note "[dry-run] keep ${id}@${cur} (the same or newer than ${ver})"
        EXT_RESULTS="${EXT_RESULTS}${id}@${cur} kept; "
        return 0
    fi
    note "[dry-run] \"${CODE}\" ... --install-extension \"${vsix}\" --force"
    EXT_RESULTS="${EXT_RESULTS}${id}@${ver} would install; "
    return 0
}

install_extensions() {
    local listed
    CODE="${APP_DIR}/${APP_NAME}/${CODE_IN_APP}"
    CLI_ARGS=()
    [ -z "${USER_DATA}" ] || CLI_ARGS+=(--user-data-dir "${USER_DATA}")
    [ -z "${EXT_DIR_OPT}" ] || CLI_ARGS+=(--extensions-dir "${EXT_DIR_OPT}")
    step "2/6 extensions: foam.foam-vscode ${FOAM_VER}, Anthropic.claude-code ${CC_EXT_VER}"
    if [ "${DRY}" = 1 ]; then
        note "[dry-run] \"${CODE}\"${USER_DATA:+ --user-data-dir \"${USER_DATA}\"}${EXT_DIR_OPT:+ --extensions-dir \"${EXT_DIR_OPT}\"} --list-extensions --show-versions"
        # --list-extensions only reads, so a dry run runs it for real to say per extension whether
        # it would install or keep — but the CLI scaffolds a missing user-data/extensions dir, so
        # only when the code CLI and both dirs are already there (a dry run changes nothing). With
        # no app on the Mac yet, or fresh dirs, nothing is installed anywhere: both would install.
        listed=""
        if [ -f "${CODE}" ] && [ -d "${EXT_DIR_OPT:-${HOME}/.vscode/extensions}" ] \
            && { [ -z "${USER_DATA}" ] || [ -d "${USER_DATA}" ]; }; then
            listed="$(env VSCODE_CLI=1 "${CODE}" ${CLI_ARGS[@]+"${CLI_ARGS[@]}"} --list-extensions --show-versions 2>/dev/null)" || listed=""
        fi
        dry_one_ext "foam.foam-vscode" "${FOAM_VER}" "${HERE}/${FOAM_VSIX}" "${listed}"
        dry_one_ext "Anthropic.claude-code" "${CC_EXT_VER}" "${HERE}/${CLAUDE_VSIX}" "${listed}"
        return 0
    fi
    [ -f "${CODE}" ] || die "${CODE} is missing: install the app first, or pass --no-extensions"
    listed="$(env VSCODE_CLI=1 "${CODE}" ${CLI_ARGS[@]+"${CLI_ARGS[@]}"} --list-extensions --show-versions 2>/dev/null)" || listed=""
    install_one_ext "foam.foam-vscode" "${FOAM_VER}" "${HERE}/${FOAM_VSIX}" "${listed}"
    install_one_ext "Anthropic.claude-code" "${CC_EXT_VER}" "${HERE}/${CLAUDE_VSIX}" "${listed}"
}

# ---- 3. Claude native binary quarantine ------------------------------------------------------
QUAR_RESULT=""

check_binary_signature() {  # 0 = the binary is Anthropic's claude-code, sealed by the pinned team
    local bin="$1" cs
    codesign --verify --strict "${bin}" || return 1
    cs="$(codesign -dv --verbose=2 "${bin}" 2>&1)" || return 1
    grep -qx 'Identifier=com.anthropic.claude-code' <<<"${cs}" || return 1
    grep -qx "TeamIdentifier=${CLAUDE_TEAM}" <<<"${cs}" || return 1
    return 0
}

clear_claude_quarantine() {
    local ext_root="${EXT_DIR_OPT:-${HOME}/.vscode/extensions}" dirs dir bin
    step "3/6 Claude native binary quarantine (${ext_root})"
    QUAR_RESULT="nothing to do"
    if [ "${DRY}" = 1 ]; then
        note "[dry-run] check the seal on anthropic.claude-code-*/resources/native-binary/claude, then clear com.apple.quarantine on that file if it has one"
        QUAR_RESULT="would check the native binary"
        return 0
    fi
    if [ ! -d "${ext_root}" ]; then
        note "no extensions dir yet: skipped"
        QUAR_RESULT="skipped (no ${ext_root})"
        return 0
    fi
    dirs="$(find "${ext_root}" -maxdepth 1 -type d -iname 'anthropic.claude-code-*' | LC_ALL=C sort || true)"
    if [ -z "${dirs}" ]; then
        note "no anthropic.claude-code-* folder: skipped"
        QUAR_RESULT="skipped (extension folder not found)"
        return 0
    fi
    # shellcheck disable=SC2086  # word split on purpose: find gives one path per line, and the
    # extension folder names carry no spaces (anthropic.claude-code-<version>)
    for dir in ${dirs}; do
        bin="${dir}/resources/native-binary/claude"
        [ -f "${bin}" ] || continue
        if ! check_binary_signature "${bin}"; then
            warn "${bin} does not verify as Anthropic's claude-code (team ${CLAUDE_TEAM}): nothing changed"
            QUAR_RESULT="WARNING: signature check failed on ${bin}"
            continue
        fi
        if xattr -p com.apple.quarantine "${bin}" >/dev/null 2>&1; then
            xattr -d com.apple.quarantine "${bin}" || die "cannot clear quarantine on ${bin}"
            note "cleared com.apple.quarantine on ${bin}"
            QUAR_RESULT="quarantine cleared on ${bin}"
        else
            note "no quarantine on ${bin}"
            QUAR_RESULT="no quarantine on ${bin}"
        fi
    done
}

# ---- 4. user settings ------------------------------------------------------------------------
SETTINGS_RESULT=""
HAVE_CLAUDE=0
ROUTER_BASE=0
WRAPPER_PATH=""
ENV_NAMES=()
ENV_VALUES=()

# The env file is shell written by install-claude-code.sh (claude-lms sources it the same way),
# so it is sourced inside this subshell, which prints only the keys the settings need.
read_lms_env() {  # $1 = conf path; prints KEY=value lines, nothing when the file is missing
    (
        [ -f "$1" ] || exit 0
        # shellcheck disable=SC1090
        . "$1"
        printf 'MODEL=%s\nURL=%s\nCTX=%s\nROUTER=%s\nLARGE=%s\nFAST=%s\nSUBAGENT=%s\nMAXOUT=%s\nTOKEN=%s\nDENY=%s\nPROMPT=%s\nPICKER=%s\n' \
            "${CLAUDE_LMS_MODEL:-}" "${CLAUDE_LMS_URL:-}" "${CLAUDE_LMS_CONTEXT:-}" "${CLAUDE_LMS_ROUTER:-}" \
            "${CLAUDE_LMS_LARGE:-}" "${CLAUDE_LMS_FAST:-}" "${CLAUDE_LMS_SUBAGENT:-}" "${CLAUDE_LMS_MAX_OUTPUT:-}" \
            "${CLAUDE_LMS_TOKEN:-}" "${CLAUDE_LMS_DISALLOWED_TOOLS:-}" "${CLAUDE_LMS_SYSTEM_PROMPT_FILE:-}" "${CLAUDE_LMS_PICKER:-}"
    )
}
lms_value() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }
# Prints the characters that must not be embedded in a JSON string value (empty = safe).
json_unsafe() { printf '%s' "$1" | grep -o '[[:cntrl:]"\\]' || true; }

# ---- model picker (router mode only) ----------------------------------------------------------
# MODELS_IDS/MODELS_ROUTES hold the list the router served; PICK_IDS/PICK_RT hold the user's picks in
# the picked order. Everything is parsed with /usr/bin/plutil only: an offline site Mac has no
# python3 and no jq.
MODELS_IDS=()
MODELS_ROUTES=()
PICK_IDS=()
PICK_RT=()
PICK_DESCS=()
PICK_INDICES=""
PICK_EMPTY=0
PICK_ERR=""

route_desc() {  # $1 = route value; the short plain-ASCII label for a *_DESCRIPTION env value
    case "$1" in
        spark) printf 'Spark' ;;
        "spark (not loaded)") printf 'Spark (not loaded)' ;;
        local) printf 'local' ;;
        *) printf 'router' ;;
    esac
}

route_menu_label() {  # $1 = route value, $2 = model id; the longer label shown in the menu
    case "$1" in
        spark) printf 'Spark, loaded' ;;
        "spark (not loaded)") printf 'Spark, NOT loaded (spark-model use %s first)' "$2" ;;
        local) printf 'local' ;;
        *) printf 'router' ;;
    esac
}

warn_not_loaded() {  # $1 = id, $2 = route
    if [ "$2" = "spark (not loaded)" ]; then
        # shellcheck disable=SC2016  # single quotes keep the backticks literal; printf expands $1
        warn "$(printf '%s is not loaded on the Spark: run `spark-model use %s` before choosing it in the picker (a switch takes minutes and affects every user)' "$1" "$1")"
    fi
}

# Fetches <router>/v1/models and fills MODELS_IDS/MODELS_ROUTES (duplicates and ids with
# unsupported characters skipped). Returns 1 when the router is unreachable, the body is empty
# or no usable model was parsed.
fetch_model_list() {  # $1 = router base URL
    local router="$1" body i id route dup seen
    MODELS_IDS=()
    MODELS_ROUTES=()
    body="$(curl -fsS -m 5 "${router}/v1/models" 2>/dev/null)" || return 1
    [ -n "${body}" ] || return 1
    # Parsed from the variable via stdin (the trailing "-" makes plutil read stdin): even a
    # --dry-run never leaves a temp file behind.
    i=0
    while id="$(printf '%s' "${body}" | /usr/bin/plutil -extract "data.${i}.id" raw -o - - 2>/dev/null)"; do
        route="$(printf '%s' "${body}" | /usr/bin/plutil -extract "data.${i}.route" raw -o - - 2>/dev/null || true)"
        # A router-served id with any other character (quotes, newline, ; ...) is skipped, and
        # the id itself is never printed — the menu and the hint would carry it verbatim.
        if ! model_id_ok "${id}"; then
            warn "skipping model id with unsupported characters"
            i=$((i + 1))
            continue
        fi
        dup=0
        for seen in ${MODELS_IDS[@]+"${MODELS_IDS[@]}"}; do
            if [ "${seen}" = "${id}" ]; then dup=1; fi
        done
        if [ "${dup}" = 0 ]; then
            MODELS_IDS+=("${id}")
            MODELS_ROUTES+=("${route}")
        fi
        i=$((i + 1))
    done
    [ "${#MODELS_IDS[@]}" -gt 0 ] || return 1
}

model_route() {  # $1 = id; prints the route the router reported, empty when the id is unknown
    local i=0
    while [ "${i}" -lt "${#MODELS_IDS[@]}" ]; do
        if [ "${MODELS_IDS[i]}" = "$1" ]; then printf '%s\n' "${MODELS_ROUTES[i]}"; return 0; fi
        i=$((i + 1))
    done
}

parse_pick_line() {  # $1 = raw input line, $2 = number of models
    # 0 = usable: PICK_EMPTY=1, or PICK_INDICES holds 1-4 distinct in-range numbers
    # 1 = unusable: PICK_ERR says why
    local raw="$1" count="$2" tok n out="" cnt=0 pos
    PICK_EMPTY=0
    PICK_INDICES=""
    PICK_ERR=""
    # The raw line is checked before it is split anywhere: only digits, spaces, tabs and
    # commas. Something the shell could read as a glob (like "[1]") is rejected here, so
    # the word split below has nothing it could expand into file names.
    if printf '%s' "${raw}" | grep -q '[^0-9,[:space:]]'; then
        PICK_ERR="only numbers, separated by spaces, tabs or commas"
        return 1
    fi
    # Split by word splitting, not a here-string read: bash 3.2 backs a here-string with a temp
    # file, and a failed temp file inside this `if`-called function would lose the answer.
    local -a toks=()
    local old_ifs="${IFS}"
    IFS=$', \t'
    # shellcheck disable=SC2206  # raw holds only digits, commas and blanks (checked above)
    toks=( ${raw} )
    IFS="${old_ifs}"
    for tok in ${toks[@]+"${toks[@]}"}; do
        case "${tok}" in
            '') PICK_ERR="an empty number between commas"; return 1 ;;
            *[!0-9]*) PICK_ERR="'${tok}' is not a number"; return 1 ;;
            0[0-9]*) PICK_ERR="'${tok}' has a leading zero"; return 1 ;;
        esac
        # Without leading zeros, more digits than the menu size means out of range. Checking
        # that before $(( )) keeps long strings from wrapping (18446744073709551617 -> 1).
        if [ "${#tok}" -gt "${#count}" ]; then
            PICK_ERR="${tok} is out of range 1-${count}"
            return 1
        fi
        n=$((10#${tok}))
        if [ "${n}" -lt 1 ] || [ "${n}" -gt "${count}" ]; then
            PICK_ERR="${tok} is out of range 1-${count}"
            return 1
        fi
        for pos in ${out}; do
            if [ "${pos}" = "${n}" ]; then PICK_ERR="${tok} is picked twice"; return 1; fi
        done
        cnt=$((cnt + 1))
        if [ "${cnt}" -gt 4 ]; then PICK_ERR="pick at most 4 models"; return 1; fi
        out="${out:+${out} }${n}"
    done
    if [ "${cnt}" = 0 ]; then
        PICK_EMPTY=1
        return 0
    fi
    PICK_INDICES="${out}"
}

print_model_menu() {  # prints one line per model in MODELS_IDS/MODELS_ROUTES
    local i=0 id route
    echo
    echo "Available models (pick 1-4 by number, in the order you want them):"
    while [ "${i}" -lt "${#MODELS_IDS[@]}" ]; do
        id="${MODELS_IDS[i]}"
        route="${MODELS_ROUTES[i]}"
        printf '  %d) %-24s %s\n' "$((i + 1))" "${id}" "$(route_menu_label "${route}" "${id}")"
        i=$((i + 1))
    done
}

choose_model_picks() {  # $1 = router base; fills PICK_IDS/PICK_RT/PICK_DESCS; dies when the user gives up
    local line n id route tries=0
    if ! fetch_model_list "$1"; then
        die "cannot read the model list from $1/v1/models: model picking needs the router running"
    fi
    print_model_menu
    while :; do
        tries=$((tries + 1))
        printf 'Pick 1-4 numbers separated by spaces or commas (empty = keep the defaults): '
        line=""
        # A failed read is EOF, not an answer: only a non-empty partial last line (no trailing
        # newline) is still processed. An explicit empty line (read succeeds with "") keeps the
        # defaults; a bare EOF stops the run — writing defaults silently would hide it.
        if ! read -r line; then
            [ -n "${line}" ] || die "no more input (EOF): no valid model pick: nothing was written"
        fi
        if parse_pick_line "${line}" "${#MODELS_IDS[@]}"; then
            if [ "${PICK_EMPTY}" = 0 ]; then
                # shellcheck disable=SC2086  # PICK_INDICES holds plain numbers, split on purpose
                for n in ${PICK_INDICES}; do
                    id="${MODELS_IDS[n-1]}"
                    route="$(model_route "${id}")"
                    PICK_IDS+=("${id}")
                    PICK_RT+=("${route}")
                    PICK_DESCS+=("$(route_desc "${route}")")
                done
                warn_not_loaded_loop
                # Every id passed model_id_ok in fetch_model_list, so the single quotes in this
                # hint cannot be broken by the ids.
                note "to keep this choice, add to the env file: CLAUDE_LMS_PICKER='${PICK_IDS[*]}'"
            fi
            return 0
        fi
        warn "${PICK_ERR} (attempt ${tries}/3)"
        if [ "${tries}" -ge 3 ]; then
            die "no valid model pick after 3 attempts: nothing was written"
        fi
    done
}

warn_not_loaded_loop() {  # one warning per picked id whose route is "spark (not loaded)"
    local i=0
    while [ "${i}" -lt "${#PICK_IDS[@]}" ]; do
        warn_not_loaded "${PICK_IDS[i]}" "${PICK_RT[i]}"
        i=$((i + 1))
    done
}

# 0 = the id carries only characters that are safe in every place it ends up: inside the
# single-quoted CLAUDE_LMS_PICKER hint, inside the JSON string values of settings.json, and in
# an unquoted word split. Every model id must pass this before it is stored or printed; the
# bad id itself is never echoed (it may hold shell or JSON metacharacters).
model_id_ok() {  # $1 = candidate model id
    case "$1" in
        ''|*[!A-Za-z0-9._:/-]*) return 1 ;;
    esac
    return 0
}

picker_env_ids() {  # $1 = CLAUDE_LMS_PICKER value; prints the ids space separated; 1 = value is ignored
    local tok out="" n=0
    # Validated on the raw value: the split below is unquoted, so a '*' or '?' in the value would
    # expand to the file names of the current folder before any per-id check could reject it.
    case "${1}" in
        *[![:space:]A-Za-z0-9._:/-]*)
            warn "CLAUDE_LMS_PICKER '${1}' has unsupported characters: the whole value is ignored"
            return 1 ;;
    esac
    # shellcheck disable=SC2086  # the value is split on whitespace on purpose
    for tok in ${1}; do
        n=$((n + 1))
        if [ "${n}" -gt 4 ]; then
            warn "CLAUDE_LMS_PICKER has more than 4 ids: the whole value is ignored"
            return 1
        fi
        # Same rule as the router ids: one shared check, so no picker id can ever differ from
        # what fetch_model_list would have accepted.
        if ! model_id_ok "${tok}"; then
            warn "CLAUDE_LMS_PICKER id has unsupported characters: the whole value is ignored"
            return 1
        fi
        out="${out:+${out} }${tok}"
    done
    if [ "${n}" = 0 ]; then
        warn "CLAUDE_LMS_PICKER is empty: the value is ignored"
        return 1
    fi
    printf '%s\n' "${out}"
}

resolve_model_picks() {  # $1 = router base, $2 = CLAUDE_LMS_PICKER value; fills PICK_IDS/PICK_RT/PICK_DESCS
    local router="$1" picker="$2" ids="" id route checked
    if [ "${PICK_MODEL}" = 1 ]; then
        choose_model_picks "${router}"
        return 0
    fi
    if [ -z "${picker}" ]; then return 0; fi
    ids="$(picker_env_ids "${picker}")" || ids=""
    [ -n "${ids}" ] || return 0
    if fetch_model_list "${router}"; then
        checked=1
    else
        checked=0
        note "could not read ${router}/v1/models: the CLAUDE_LMS_PICKER ids are used as given"
    fi
    # shellcheck disable=SC2086  # ids are space separated by picker_env_ids
    for id in ${ids}; do
        route=""
        if [ "${checked}" = 1 ]; then route="$(model_route "${id}")"; fi
        PICK_IDS+=("${id}")
        PICK_RT+=("${route}")
        PICK_DESCS+=("$(route_desc "${route}")")
        if [ "${checked}" = 1 ] && [ -z "${route}" ]; then
            warn "CLAUDE_LMS_PICKER id '${id}' is not in ${router}/v1/models"
        fi
    done
    warn_not_loaded_loop
}

apply_picker_slots() {  # $1 = default main, $2 = default fast; rewrites the slots and appends new entries
    local m_main="$1" m_fast="$2" msg fable fable_desc
    ENV_VALUES[1]="${PICK_IDS[0]}"   # ANTHROPIC_MODEL
    ENV_VALUES[2]="${PICK_IDS[0]}"   # ANTHROPIC_DEFAULT_OPUS_MODEL
    ENV_NAMES+=(ANTHROPIC_DEFAULT_OPUS_MODEL_NAME)
    ENV_VALUES+=("${PICK_IDS[0]}")
    ENV_NAMES+=(ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION)
    ENV_VALUES+=("${PICK_DESCS[0]}")
    msg="picker: opus=${PICK_IDS[0]}"
    if [ "${#PICK_IDS[@]}" -ge 2 ]; then
        ENV_VALUES[3]="${PICK_IDS[1]}"   # ANTHROPIC_DEFAULT_SONNET_MODEL
        ENV_NAMES+=(ANTHROPIC_DEFAULT_SONNET_MODEL_NAME)
        ENV_VALUES+=("${PICK_IDS[1]}")
        ENV_NAMES+=(ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION)
        ENV_VALUES+=("${PICK_DESCS[1]}")
        msg="${msg} sonnet=${PICK_IDS[1]}"
    else
        msg="${msg} sonnet=${m_main} (default)"
    fi
    if [ "${#PICK_IDS[@]}" -ge 3 ]; then
        ENV_VALUES[4]="${PICK_IDS[2]}"   # ANTHROPIC_DEFAULT_HAIKU_MODEL
        ENV_NAMES+=(ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME)
        ENV_VALUES+=("${PICK_IDS[2]}")
        ENV_NAMES+=(ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION)
        ENV_VALUES+=("${PICK_DESCS[2]}")
        msg="${msg} haiku=${PICK_IDS[2]}"
    else
        # With picks the haiku slot falls back to the fast model, never to the large one.
        ENV_VALUES[4]="${m_fast}"
        msg="${msg} haiku=${m_fast} (default)"
    fi
    # The extension's built-in Fable row sends the Fable model id, which the router does not know,
    # so that row fails when picked. ANTHROPIC_DEFAULT_FABLE_MODEL turns it into a "Custom Fable
    # model" row that works: it carries the 4th pick with 4 picks, the main pick below that — the
    # picker then has no row that cannot work. (ANTHROPIC_CUSTOM_MODEL_OPTION is no longer written.)
    if [ "${#PICK_IDS[@]}" -ge 4 ]; then
        fable="${PICK_IDS[3]}"; fable_desc="${PICK_DESCS[3]}"
    else
        fable="${PICK_IDS[0]}"; fable_desc="${PICK_DESCS[0]}"
    fi
    ENV_NAMES+=(ANTHROPIC_DEFAULT_FABLE_MODEL)
    ENV_VALUES+=("${fable}")
    ENV_NAMES+=(ANTHROPIC_DEFAULT_FABLE_MODEL_NAME)
    ENV_VALUES+=("${fable}")
    ENV_NAMES+=(ANTHROPIC_DEFAULT_FABLE_MODEL_DESCRIPTION)
    ENV_VALUES+=("${fable_desc}")
    msg="${msg} fable=${fable}"
    note "${msg}"
}

# Prints the values that must not go into settings.json verbatim (empty when all are fine):
# values with JSON-unsafe characters, pick ids that miss the shared model-id rule (the line-
# oriented json_unsafe grep cannot see a newline, so ids get the stricter case-pattern check),
# and non-numeric token counts.
claude_env_bad() {  # $1 = base, $2 = main, $3 = fast, $4 = sub, $5 = ctx, $6 = maxout
    local v bad=""
    for v in "$1" "$2" "$3" "$4" ${PICK_DESCS[@]+"${PICK_DESCS[@]}"}; do
        case "$(json_unsafe "${v}")" in ?*) bad="${bad} '${v}'" ;; esac
    done
    for v in ${PICK_IDS[@]+"${PICK_IDS[@]}"}; do
        if ! model_id_ok "${v}"; then bad="${bad} pick id '${v}'"; fi
    done
    case "$5" in ''|*[!0-9]*|0) bad="${bad} context '$5'" ;; esac
    case "$6" in ''|*[!0-9]*|0) bad="${bad} max_output '$6'" ;; esac
    printf '%s\n' "${bad}"
}

build_claude_env() {  # $1 = conf path; sets HAVE_CLAUDE/ENV_NAMES/ENV_VALUES/WRAPPER_PATH
    local vals url router large fast sub ctx maxout model token deny pfile picker base m_main m_fast m_sub bad v w
    vals="$(read_lms_env "$1")"
    url="$(lms_value URL "${vals}")"; url="${url:-http://127.0.0.1:1234}"; url="${url%/}"
    router="$(lms_value ROUTER "${vals}")"; router="${router%/}"
    large="$(lms_value LARGE "${vals}")"; large="${large:-spark-large}"
    fast="$(lms_value FAST "${vals}")"; fast="${fast:-local-fast}"
    sub="$(lms_value SUBAGENT "${vals}")"; sub="${sub:-spark-large}"
    ctx="$(lms_value CTX "${vals}")"; ctx="${ctx:-65536}"
    maxout="$(lms_value MAXOUT "${vals}")"; maxout="${maxout:-16384}"
    model="$(lms_value MODEL "${vals}")"
    token="$(lms_value TOKEN "${vals}")"
    deny="$(lms_value DENY "${vals}")"
    pfile="$(lms_value PROMPT "${vals}")"
    picker="$(lms_value PICKER "${vals}")"
    if [ -n "${router}" ]; then
        base="${router}"; m_main="${large}"; m_fast="${fast}"; m_sub="${sub}"
        ROUTER_BASE=1
        note "router mode: base ${router} (main ${large}, fast ${fast}, subagent ${sub})"
        note "unlike claude-lms, the extension does not fall back to LM Studio when the router is down"
        resolve_model_picks "${router}" "${picker}"
    else
        base="${url}"; m_main="${model}"; m_fast="${model}"; m_sub="${model}"
        if [ "${PICK_MODEL}" = 1 ] || [ -n "${picker}" ]; then
            warn "model picking needs router mode (a CLAUDE_LMS_ROUTER in the env file): --pick-models/CLAUDE_LMS_PICKER is ignored"
        fi
        if [ -z "${model}" ]; then
            warn "no CLAUDE_LMS_MODEL in $1: install the Claude Code kit first or set CLAUDE_LMS_MODEL — the Claude settings are not written (the offline settings still are)"
        fi
    fi
    if [ -n "${token}" ] && [ "${token}" != "lmstudio" ]; then
        if [ -n "${router}" ]; then
            note "the router ignores the client token, so CLAUDE_LMS_TOKEN is not written"
        else
            warn "CLAUDE_LMS_TOKEN is set and is not 'lmstudio': the LM Studio token must be added by hand and is not written by the installer"
        fi
    fi
    if [ -z "${model}" ] && [ -z "${router}" ]; then return 0; fi
    # Anything that cannot go into JSON verbatim skips the whole Claude block, never one key
    # alone. This runs before apply_picker_slots writes the pick ids out.
    bad="$(claude_env_bad "${base}" "${m_main}" "${m_fast}" "${m_sub}" "${ctx}" "${maxout}")"
    if [ -n "${bad}" ]; then
        warn "the Claude settings are skipped, a value cannot go into settings.json:${bad}"
        return 0
    fi
    HAVE_CLAUDE=1
    # The extension's claudeProcessWrapper: install-claude-code.sh puts claude-vscode in ~/.local/bin,
    # where it reads the same env file and adds the same --disallowedTools/--system-prompt-file the
    # CLI's claude-lms does (the extension itself applies neither). Registered only when it is there,
    # as an absolute path — the extension does not expand ~. Same JSON rule as the values above: a
    # HOME that cannot go into settings.json verbatim skips this one key with a warning.
    w="${HOME}/.local/bin/claude-vscode"
    if [ -x "${w}" ]; then
        if [ -n "$(json_unsafe "${w}")" ]; then
            warn "claudeCode.claudeProcessWrapper skipped: the path from \$HOME cannot go into settings.json verbatim"
        else
            WRAPPER_PATH="${w}"
        fi
    fi
    # Said only now that the wrapper decision above is made: these two keys reach the extension
    # exactly when the wrapper is registered (it adds --disallowedTools/--system-prompt-file for
    # the extension, which applies neither by itself). The values are never printed.
    if [ -n "${deny}" ] || [ -n "${pfile}" ]; then
        if [ -n "${WRAPPER_PATH}" ]; then
            if [ -n "${deny}" ]; then
                note "CLAUDE_LMS_DISALLOWED_TOOLS is applied to the extension through claude-vscode"
            fi
            if [ -n "${pfile}" ]; then
                note "CLAUDE_LMS_SYSTEM_PROMPT_FILE is applied to the extension through claude-vscode"
            fi
        else
            if [ -n "${deny}" ]; then
                note "CLAUDE_LMS_DISALLOWED_TOOLS is set, but there is no ${w}: not applied (install the Claude Code kit first)"
            fi
            if [ -n "${pfile}" ]; then
                note "CLAUDE_LMS_SYSTEM_PROMPT_FILE is set, but there is no ${w}: not applied (install the Claude Code kit first)"
            fi
        fi
    fi
    # Values are proven free of ", \ and control characters above, so they go in verbatim.
    # shellcheck disable=SC2034  # ENV_NAMES/ENV_VALUES are consumed by settings_json
    ENV_NAMES=(ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL \
        ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL \
        CLAUDE_CODE_SUBAGENT_MODEL ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_ATTRIBUTION_HEADER \
        CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_AUTOUPDATER CLAUDE_CODE_MAX_CONTEXT_TOKENS \
        CLAUDE_CODE_MAX_OUTPUT_TOKENS ENABLE_CLAUDEAI_MCP_SERVERS)
    # shellcheck disable=SC2034
    ENV_VALUES=("${base}" "${m_main}" "${m_main}" "${m_main}" "${m_main}" "${m_fast}" \
        "${m_sub}" "lmstudio" "0" "1" "1" "${ctx}" "${maxout}" "false")
    if [ "${#PICK_IDS[@]}" -gt 0 ]; then
        apply_picker_slots "${m_main}" "${m_fast}"
    fi
}

settings_json() {  # prints the JSONC object (2-space indent)
    local i n comma
    printf '{\n'
    printf '  "telemetry.telemetryLevel": "off",\n'
    printf '  "update.mode": "none",\n'
    printf '  "update.showReleaseNotes": false,\n'
    printf '  "extensions.autoUpdate": false,\n'
    printf '  "extensions.autoCheckUpdates": false,\n'
    printf '  "extensions.ignoreRecommendations": true,\n'
    printf '  "workbench.enableExperiments": false,\n'
    printf '  "workbench.settings.enableNaturalLanguageSearch": false,\n'
    printf '  "npm.fetchOnlinePackageInfo": false,\n'
    printf '  "json.schemaDownload.enable": false,\n'
    printf '  "typescript.disableAutomaticTypeAcquisition": true,\n'
    printf '  "git.autofetch": false,\n'
    if [ "${HAVE_CLAUDE}" = 1 ]; then
        printf '  "claudeCode.disableLoginPrompt": true,\n'
        if [ -n "${WRAPPER_PATH}" ]; then
            printf '  "claudeCode.claudeProcessWrapper": "%s",\n' "${WRAPPER_PATH}"
        fi
        printf '  "claudeCode.environmentVariables": [\n'
        i=0; n=${#ENV_NAMES[@]}
        while [ "${i}" -lt "${n}" ]; do
            if [ "$((i + 1))" -lt "${n}" ]; then comma=','; else comma=''; fi
            printf '    {"name": "%s", "value": "%s"}%s\n' "${ENV_NAMES[$i]}" "${ENV_VALUES[$i]}" "${comma}"
            i=$((i + 1))
        done
        printf '  ]\n'
    fi
    printf '}\n'
}

do_settings() {
    local conf="${XDG_CONFIG_HOME:-${HOME}/.config}/claude-lms/env" settings_dir settings existing compact old_base
    if [ -n "${USER_DATA}" ]; then settings_dir="${USER_DATA}/User"
    else settings_dir="${HOME}/Library/Application Support/Code/User"; fi
    settings="${settings_dir}/settings.json"
    step "4/6 user settings (${settings})"
    build_claude_env "${conf}"
    existing=""
    if [ -f "${settings}" ]; then existing="$(cat "${settings}" 2>/dev/null || true)"; fi
    compact="$(printf '%s' "${existing}" | tr -d '[:space:]')"
    if [ ! -f "${settings}" ] || [ -z "${compact}" ] || [ "${compact}" = "{}" ]; then
        # Nothing there (or an empty object): the add-on settings go straight in.
        if [ "${DRY}" = 1 ]; then
            note "[dry-run] write ${settings} with the settings below (mode 600)"
            settings_json | sed 's/^/      /'
        else
            mkdir -p "${settings_dir}"
            settings_json >"${settings}"
            chmod 600 "${settings}"
        fi
        SETTINGS_RESULT="written to ${settings}"
    else
        # A user file with content is JSONC and is never rewritten: a side file carries the entries.
        if [ "${DRY}" = 1 ]; then
            note "[dry-run] ${settings} has content: write the side file ${settings_dir}/settings.vscode-addon.jsonc with the settings below"
            settings_json | sed 's/^/      /'
        else
            mkdir -p "${settings_dir}"
            settings_json >"${settings_dir}/settings.vscode-addon.jsonc"
            chmod 600 "${settings_dir}/settings.vscode-addon.jsonc"
        fi
        case "${existing}" in
            *claudeCode.environmentVariables*)
                # What the user's settings point Claude Code at, read with sed from the captured
                # text (no pipe whose reader could SIGPIPE under pipefail); empty when their file
                # has no such entry. Router mode pointing at a different base (e.g. LM Studio
                # direct) is the one case that deserves more than a note: the extension would
                # keep bypassing the router, so the side file's entries should replace them.
                old_base="$(printf '%s\n' "${existing}" | sed -n 's/.*"name": "ANTHROPIC_BASE_URL", "value": "\([^"]*\)".*/\1/p')"
                old_base="${old_base%%$'\n'*}"
                if [ "${HAVE_CLAUDE}" = 1 ] && [ "${ROUTER_BASE}" = 1 ] && [ -n "${old_base}" ] && [ "${old_base}" != "${ENV_VALUES[0]}" ]; then
                    warn "the existing settings.json points Claude Code at ${old_base} (LM Studio direct mode) while this run goes through the router: replace its claudeCode.environmentVariables entries with the side file's so the model picker and the fallbacks match"
                else
                    note "existing Claude settings found — compare with the side file"
                fi
                ;;
        esac
        note "paste the entries into settings.json yourself: Command Palette (Cmd+Shift+P) → \"Preferences: Open User Settings (JSON)\""
        SETTINGS_RESULT="side file ${settings_dir}/settings.vscode-addon.jsonc (settings.json not touched)"
    fi
    [ "${HAVE_CLAUDE}" = 1 ] || note "claudeCode.environmentVariables: not written this run"
}

# ---- 5. wiki workspace -----------------------------------------------------------------------
WIKI_RESULT=""

place_wiki_file() {  # $1 = path inside wiki-workspace/, $2 = target path in the wiki
    local src="${HERE}/wiki-workspace/$1" dst="$2"
    [ -f "${src}" ] || die "${src} is missing from the add-on"
    if [ -e "${dst}" ]; then
        run cp "${src}" "${dst}.vscode-addon"
        note "${dst} exists: the add-on copy is beside it as ${dst}.vscode-addon"
    else
        run mkdir -p "$(dirname "${dst}")"
        run cp "${src}" "${dst}"
        note "wrote ${dst}"
    fi
}

do_wiki() {
    local wiki="${WIKI_OPT:-${HOME}/llm-wiki/wiki}"
    step "5/6 wiki workspace (${wiki})"
    if [ ! -d "${wiki}" ]; then
        warn "${wiki} does not exist: skipped (pass --wiki=DIR when the wiki lives elsewhere)"
        WIKI_RESULT="skipped (no ${wiki})"
        return 0
    fi
    place_wiki_file ".vscode/settings.json" "${wiki}/.vscode/settings.json"
    place_wiki_file ".foam/templates/new-note.md" "${wiki}/.foam/templates/new-note.md"
    WIKI_RESULT="workspace files placed in ${wiki}"
}

# ---- 6. summary ------------------------------------------------------------------------------
summary() {
    local wiki="${WIKI_OPT:-${HOME}/llm-wiki/wiki}"
    step "6/6 summary"
    note "app:        ${APP_RESULT}"
    note "extensions: ${EXT_RESULTS:-skipped}"
    note "binary:     ${QUAR_RESULT:-skipped}"
    note "settings:   ${SETTINGS_RESULT:-skipped}"
    note "wiki:       ${WIKI_RESULT:-skipped}"
    note "code CLI:   ${APP_DIR}/${APP_NAME}/${CODE_IN_APP}"
    echo
    note "next: open the wiki folder with"
    note "  \"${APP_DIR}/${APP_NAME}/${CODE_IN_APP}\" \"${wiki}\""
    note "the first open asks \"Do you trust the authors of the files in this folder?\" → Trust (Restricted Mode keeps the Claude extension off)"
    note "the Claude panel is the spark icon in the editor title bar / activity bar"
}

if [ "${DRY}" = 1 ]; then echo "VS Code add-on installer — dry run (nothing is changed)"; fi
if [ "${DO_APP}" = 1 ]; then install_app; fi
if [ "${DO_EXT}" = 1 ]; then install_extensions; fi
if [ "${DO_EXT}" = 1 ]; then clear_claude_quarantine; fi
if [ "${DO_SETTINGS}" = 1 ]; then do_settings; fi
if [ "${DO_WIKI}" = 1 ]; then do_wiki; fi
summary
