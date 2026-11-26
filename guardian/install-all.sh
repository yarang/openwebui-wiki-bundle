#!/usr/bin/env bash
# ==============================================================================
# LLM + wiki bundle installer: guardian install.sh, LM Studio from its dmg, wiki-layer/install-wiki.sh, then
# claude-code/install-claude-code.sh, then wiki-mcp-kit/install-wiki-mcp.sh, then
# vscode-addon/install-vscode.sh, then hop-viewer/install-hop.sh
#
# The guardian step installs LM Studio's runtimes and models, Python 3.12 and Open WebUI (~/.guardian-llm). The app
# step copies LM Studio.app out of the official dmg in app/ into /Applications (~/Applications when that is not
# writable), as dragging it there would, with the guardian installer's rules: a same or newer installed version is
# kept, an older one is replaced only with --upgrade-app and LM Studio closed, and is renamed, never deleted;
# --upgrade-app stops only an LM Studio service THIS run started (the guardian step can leave one running with
# --run-as-service), never one that was already open, which still dies asking the user to close it. The wiki
# step adds wiki-mcp, mcpo and the watch service, and restarts everything. The Claude Code step installs claude and
# claude-lms (Claude Code on LM Studio, set to the wiki's model) in ~/.local/bin and, by default, the llm-router
# (LM Studio and a Spark behind one Anthropic base URL) with --router-load, so claude-lms goes through it from the
# start; --no-router goes back to direct LM Studio, --with-router installs the router without starting it, and
# --spark-url/--spark-env set the Spark's address (a --spark-url of one URL or a comma list) and
# keys. The wiki-mcp kit step then runs ONE
# shared wiki-mcp HTTP server (the only Chroma writer) and points both mcpo (as a relay, its port and key unchanged)
# and Claude Code's user-scope 'wiki' entry at it; it must run after the Claude Code step, which installs the claude
# CLI the kit registers. The guardian installer always runs with --no-start because it rewrites the Open WebUI
# LaunchAgent that the wiki step then extends. The VS Code step installs the app, the Foam and Claude Code
# extensions, the user settings and the wiki workspace files; it runs after the Claude Code step because its
# settings are built from ~/.config/claude-lms/env that step writes, and it never uses sudo: the app goes into
# /Applications (~/Applications when that is not writable; a copy already in a not-writable /Applications,
# installed by an admin, is kept and only the extensions, settings and wiki files are installed). The HOP
# step installs the .hwp/.hwpx viewer: the app goes into /Applications (~/Applications when that is not
# writable; when an admin already put HOP in a not-writable /Applications that copy is kept and the step
# is skipped), then it is registered with LaunchServices so .hwp/.hwpx files open in HOP; it is the last
# step and independent of the others, and it never uses sudo.
#
# Usage:  ./install-all.sh [options]
#   all:     --dry-run  --no-start  --prefix=DIR  --embedding-model=M
#   app:     --no-app  --upgrade-app
#   guardian: --no-models  --skip-verify  --port=N  --lmstudio-url=URL
#   wiki:    --wiki-home=DIR  --mcpo-port=N  --webui-host=H  --migrate-from=OLD_BUNDLE
#   claude:  --no-claude-code  --no-skills  --no-router  --with-router  --router-load
#            --spark-url=URL  --spark-env=FILE
#   wiki-mcp: --no-wiki-mcp-http  --wiki-mcp-port=N
#   vscode:  --no-vscode  --no-vscode-app  --vscode-app-dir=DIR  --vscode-pick-models
#   hop:     --no-hop  --no-hop-register  --hop-app-dir=DIR
# See ./install.sh --help, wiki-layer/install-wiki.sh --help, claude-code/install-claude-code.sh --help,
# wiki-mcp-kit/install-wiki-mcp.sh --help, vscode-addon/install-vscode.sh --help and
# hop-viewer/install-hop.sh --help.
# Start with --dry-run. Moving data from an old openwebui-wiki bundle: stop its processes, then
#   ./install-all.sh --migrate-from="$HOME"/Desktop/openwebui-wiki-bundle-0.10.2-macos-arm64
# ==============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
G_ARGS=(--no-start)
W_ARGS=()
C_ARGS=()
K_ARGS=()
V_ARGS=()
H_ARGS=()
DO_CLAUDE=1
DO_WIKI_MCP=1
DRY=0
DO_APP=1
UPGRADE_APP=0
DO_VSCODE=1
VSCODE_NO_APP=0
VSCODE_APP_DIR=""
DO_HOP=1
HOP_APP_DIR=""
# The claude step's router mode: with no router option at all the router is installed AND loaded
# (the bundle's default); --no-router, --with-router and --router-load pick the other states, and
# the LAST one on the command line wins.
ROUTER_MODE="load"
# The kit needs the wiki home too; --dry-run with no ${WIKI_HOME}/.env (§5 below) checks against it.
WIKI_HOME="${HOME}/llm-wiki"

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY=1; G_ARGS+=("${arg}"); W_ARGS+=("${arg}"); C_ARGS+=("${arg}"); K_ARGS+=("${arg}"); V_ARGS+=("${arg}"); H_ARGS+=("${arg}") ;;
        --prefix=*|--embedding-model=*) G_ARGS+=("${arg}"); W_ARGS+=("${arg}") ;;
        --no-start) W_ARGS+=("${arg}"); K_ARGS+=("${arg}") ;;
        --no-app) DO_APP=0; G_ARGS+=("${arg}") ;;
        --upgrade-app) UPGRADE_APP=1; G_ARGS+=("${arg}") ;;
        --lmstudio-url=*) G_ARGS+=("${arg}"); C_ARGS+=("${arg}") ;;
        --no-models|--skip-verify|--port=*) G_ARGS+=("${arg}") ;;
        --no-claude-code) DO_CLAUDE=0 ;;
        --no-skills) C_ARGS+=("${arg}") ;;
        --no-router) ROUTER_MODE="none" ;;
        --with-router) ROUTER_MODE="with" ;;
        --router-load) ROUTER_MODE="load" ;;
        --spark-url=*|--spark-env=*) C_ARGS+=("${arg}") ;;
        --wiki-home=*) W_ARGS+=("${arg}"); K_ARGS+=("${arg}"); WIKI_HOME="${arg#--wiki-home=}" ;;
        --mcpo-port=*|--webui-host=*|--migrate-from=*) W_ARGS+=("${arg}") ;;
        --wiki-mcp-port=*) K_ARGS+=("--port=${arg#--wiki-mcp-port=}") ;;
        --no-wiki-mcp-http) DO_WIKI_MCP=0 ;;
        --no-vscode) DO_VSCODE=0 ;;
        --no-vscode-app) VSCODE_NO_APP=1 ;;
        --vscode-app-dir=*) VSCODE_APP_DIR="${arg#--vscode-app-dir=}" ;;
        --vscode-pick-models) V_ARGS+=(--pick-models) ;;
        --no-hop) DO_HOP=0 ;;
        # The viewer's own option is --no-register; the hop- prefix keeps install-all's options apart.
        --no-hop-register) H_ARGS+=(--no-register) ;;
        --hop-app-dir=*)
            HOP_APP_DIR="${arg#--hop-app-dir=}"
            [ -n "${HOP_APP_DIR}" ] || { echo "error: --hop-app-dir= needs a directory" >&2; exit 2; } ;;
        --no-openwebui) echo "error: the wiki layer runs inside the Open WebUI venv; --no-openwebui is not supported here" >&2; exit 2 ;;
        -h|--help) sed -n '3,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

# Decided once, after the whole command line: --no-claude-code (or a bundle without claude-code/)
# never runs the step, so no router flag reaches it either.
case "${ROUTER_MODE}" in
    none) ;;
    with) C_ARGS+=(--with-router) ;;
    load) C_ARGS+=(--router-load) ;;
esac

die() { echo "error: $*" >&2; exit 1; }
note() { echo "    $*"; }
manifest() { sed -n "s/^$1=//p" "${HERE}/MANIFEST.env" | head -1; }
APP_NAME="$(manifest app_name)"
APP_VERSION="$(manifest app_version)"
APP_DMG="$(manifest app_dmg)"

# The MLX engine venv is a venvstacks stack whose layers are linked by absolute path in the sitecustomize.py of the
# app venv: one addsitedir('<path>') line per layer, pointing into the build Mac's home (MANIFEST.env built_home).
# install.sh retargets only pyvenv.cfg and bin/*, so on a Mac with a different user the engine starts but cannot import
# idna and friends. That text is rewritten here right after the guardian step, in pure bash with literal strings only
# (a clean Mac has no python3); it runs on every install, so Macs set up with an older bundle are repaired on the next
# run. The match starts at the opening quote, so a home that ends with the build home (/Data/Users/builder for
# /Users/builder) is not rewritten again on the next run.

# py_sq S: S as the inside of a Python '...' literal (\ and ' backslash-escaped).
py_sq() {
    local s="$1" r="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "${c}" in "\\" | "'") r+="\\${c}" ;; *) r+="${c}" ;; esac
    done
    printf '%s' "${r}"
}

# glob_lit S: S backslash-escaped so ${var//pat/rep} matches it literally (pat is a glob).
glob_lit() {
    local s="$1" r="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "${c}" in "\\" | '*' | '?' | '[') r+="\\${c}" ;; *) r+="${c}" ;; esac
    done
    printf '%s' "${r}"
}

# warn_missing_layers FILE REL: a layer dir under ${HOME}/.lmstudio that FILE points at but the bundle did not ship
# breaks imports the same way: warn only.
warn_missing_layers() {
    local line rest p
    while IFS= read -r line || [ -n "${line}" ]; do
        rest="${line}"
        while :; do
            case "${rest}" in
                *"addsitedir('"*"')"*) ;;
                *) break ;;
            esac
            rest="${rest#*addsitedir(\'}"
            p="${rest%%"')"*}"
            rest="${rest#*"')"}"
            case "${p}" in
                "${HOME}"/.lmstudio/*) [ -d "${p}" ] || note "warning: ${p} (from $2) does not exist" ;;
            esac
        done
    done <"$1"
}

retarget_lmstudio_sitecustomize() {
    local old new needle repl esc f tmp rel line out
    old="$(manifest built_home)"
    new="${HOME}"
    [ -n "${old}" ] || return 0
    [ "${old}" != "${new}" ] || return 0
    needle="'$(py_sq "${old}")/.lmstudio/"
    repl="'$(py_sq "${new}")/.lmstudio/"
    esc="$(glob_lit "${needle}")"
    for f in "${new}"/.lmstudio/extensions/backends/vendor/*/*/lib/python3*/site-packages/sitecustomize.py; do
        [ -f "${f}" ] || continue
        [ ! -L "${f}" ] || continue
        grep -qF "${needle}" "${f}" || continue
        rel="${f#*/.lmstudio/}"
        if [ "${DRY}" = 1 ]; then
            note "[dry-run] would rewrite ${old} -> ${new} in ${rel}"
            continue
        fi
        tmp="${f}.tmp"
        while IFS= read -r line || [ -n "${line}" ]; do
            # esc must match as a pattern. repl is quoted so bash 5.2+ (patsub_replacement) keeps & and \ literal;
            # the assignment stays unquoted because bash 3.2 would keep those quotes in a double-quoted expansion.
            # shellcheck disable=SC2295
            out=${line//${esc}/"${repl}"}
            printf '%s\n' "${out}"
        done <"${f}" >"${tmp}"
        cat "${tmp}" >"${f}"
        rm -f "${tmp}"
        note "MLX engine path: ${old} -> ${new} in ${rel}"
        # The file holds the escaped form when HOME has \ or ': skip the existence check rather than misread it.
        if [ "$(py_sq "${new}")" = "${new}" ]; then warn_missing_layers "${f}" "${rel}"; fi
    done
}

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

# stop_lm_service_started_here — what --upgrade-app does about an LM Studio main process (pgrep -x) when it has to
# replace the app. An instance THIS run started (not in LM_START_PIDS and running with --run-as-service: the
# guardian step's `lms runtime select` can leave one behind, PPID 1) is stopped here: SIGTERM, 5s, then SIGKILL,
# 10s more, and die when it still will not go, since it ignores quit and SIGTERM. Anything else — it was open when
# this install started (a pid in LM_START_PIDS) or it runs without --run-as-service — belongs to the user and is
# never killed: return 1, the caller dies asking the user to close it. --dry-run never kills and only says what it
# would stop. Returns 0 when the install may go on.
stop_lm_service_started_here() {
    local pids pid args theirs=0 i
    local -a running=() ours=() left=()
    pids="$(pgrep -x "LM Studio" 2>/dev/null || true)"
    [ -n "${pids}" ] || return 0
    while IFS= read -r pid; do
        [ -n "${pid}" ] || continue
        running+=("${pid}")
    done <<<"${pids}"
    for pid in "${running[@]}"; do
        case $'\n'"${LM_START_PIDS}"$'\n' in
            *$'\n'"${pid}"$'\n'*) theirs=1; continue ;;   # open before this install started
        esac
        args="$(ps -o args= -p "${pid}" 2>/dev/null || true)"
        case "${args}" in
            *--run-as-service*) ours+=("${pid}") ;;
            *) theirs=1 ;;
        esac
    done
    [ "${theirs}" = 0 ] || return 1
    [ "${#ours[@]}" -gt 0 ] || return 0
    if [ "${DRY}" = 1 ]; then
        for pid in "${ours[@]}"; do
            note "[dry-run] would stop the LM Studio service this run started (pid ${pid})"
        done
        return 0
    fi
    for pid in "${ours[@]}"; do
        note "stopping the LM Studio service this run started (pid ${pid})"
        kill "${pid}" 2>/dev/null || true
    done
    for i in 1 2 3 4 5; do
        left=()
        for pid in "${ours[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then left+=("${pid}"); fi
        done
        [ "${#left[@]}" -eq 0 ] && break
        sleep 1
    done
    if [ "${#left[@]}" -gt 0 ]; then
        for pid in "${left[@]}"; do
            note "pid ${pid} ignored SIGTERM: sending SIGKILL"
            kill -9 "${pid}" 2>/dev/null || true
        done
        for i in 1 2 3 4 5 6 7 8 9 10; do
            left=()
            for pid in "${ours[@]}"; do
                if kill -0 "${pid}" 2>/dev/null; then left+=("${pid}"); fi
            done
            [ "${#left[@]}" -eq 0 ] && break
            sleep 1
        done
    fi
    if [ "${#left[@]}" -gt 0 ]; then
        die "LM Studio pid ${left[*]} did not stop within 10s of SIGKILL: close it by hand and rerun"
    fi
    return 0
}

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
        # Only an LM Studio this run started may be stopped (stop_lm_service_started_here); one the user opened
        # still means "close it first".
        if ! stop_lm_service_started_here; then
            die "LM Studio is running: close it first"
        fi
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

# The VS Code add-on's installer never uses sudo: it dies when its --app-dir exists but is not writable,
# and even with --no-app it looks for the code CLI under --app-dir (default /Applications). This picks
# the folder the way install_app_from_dmg picks one for LM Studio, appending the choice to V_ARGS.
vscode_app_args() {
    local app="Visual Studio Code.app"
    if [ "${VSCODE_NO_APP}" = 1 ]; then
        V_ARGS+=(--no-app)
        # With --no-app the CLI is still looked up under --app-dir (default /Applications).
        if [ -d "${HOME}/Applications/${app}" ] && [ ! -d "/Applications/${app}" ]; then
            V_ARGS+=(--app-dir="${HOME}/Applications")
        fi
        return 0
    fi
    if [ -d "/Applications/${app}" ]; then
        if [ -w "/Applications" ]; then return 0; fi
        # A standard user on a Mac an admin installed VS Code for: that copy is kept as it is.
        V_ARGS+=(--no-app)
        note "VS Code in /Applications is kept (not writable by $(id -un)); only the extensions, settings and wiki files are installed"
        return 0
    fi
    if [ -d "${HOME}/Applications/${app}" ]; then
        V_ARGS+=(--app-dir="${HOME}/Applications")
        return 0
    fi
    if [ -w "/Applications" ]; then return 0; fi
    V_ARGS+=(--app-dir="${HOME}/Applications")
}

# The HOP viewer's installer never uses sudo and has no --no-app: it dies when its --app-dir exists
# but is not writable — even when the same HOP version is already installed there, its writable
# check comes first. So when an admin already put HOP.app in a not-writable /Applications there is
# nothing this account can install and the step is skipped; otherwise the folder is picked the way
# vscode_app_args picks one for VS Code, appending the choice to H_ARGS. Returns 0 when the
# installer should run, 1 when the step is skipped (the note is printed here).
hop_app_args() {
    local app="HOP.app"
    if [ -d "/Applications/${app}" ]; then
        if [ -w "/Applications" ]; then return 0; fi
        note "HOP in /Applications is kept (not writable by $(id -un)); nothing to install for this account"
        return 1
    fi
    if [ -d "${HOME}/Applications/${app}" ]; then
        H_ARGS+=(--app-dir="${HOME}/Applications")
        return 0
    fi
    if [ -w "/Applications" ]; then return 0; fi
    H_ARGS+=(--app-dir="${HOME}/Applications")
    return 0
}

# PIDs of the LM Studio main processes already running when this install started (one per line, empty when none).
# The guardian step can start LM Studio itself: `lms runtime select` launches the app with --run-as-service
# (PPID 1) and that instance ignores quit and SIGTERM. --upgrade-app may stop only an instance THIS run started;
# a pid in this list was open before the install began and is never killed.
LM_START_PIDS="$(pgrep -x "LM Studio" 2>/dev/null || true)"

echo "######## 1/7 guardian: LM Studio runtimes and models, Open WebUI"
"${HERE}/install.sh" "${G_ARGS[@]}"
retarget_lmstudio_sitecustomize
echo
echo "######## 2/7 LM Studio app"
if [ "${DO_APP}" = 0 ]; then
    note "--no-app: skipped"
elif [ -z "${APP_DMG}" ]; then
    note "installed by install.sh (this bundle has no dmg)"
else
    install_app_from_dmg
fi
echo
echo "######## 3/7 wiki layer: wiki-mcp, mcpo, watch"
"${HERE}/wiki-layer/install-wiki.sh" ${W_ARGS[@]+"${W_ARGS[@]}"}
echo
echo "######## 4/7 Claude Code, and claude-lms on LM Studio"
if [ "${DO_CLAUDE}" = 0 ]; then
    note "--no-claude-code: skipped"
elif [ ! -d "${HERE}/claude-code" ]; then
    note "this bundle has no claude-code/: skipped"
else
    # After the wiki step, so claude-lms takes the model ~/llm-wiki/.env names.
    "${HERE}/claude-code/install-claude-code.sh" ${C_ARGS[@]+"${C_ARGS[@]}"}
fi
echo
echo "######## 5/7 shared wiki-mcp HTTP server (one Chroma writer for Open WebUI and Claude Code)"
if [ "${DO_WIKI_MCP}" = 0 ]; then
    note "--no-wiki-mcp-http: skipped (Open WebUI keeps the old way: mcpo spawns wiki-mcp over stdio)"
elif [ ! -d "${HERE}/wiki-mcp-kit" ]; then
    # Bundles from before the kit was shipped.
    note "this bundle has no wiki-mcp-kit/: skipped"
else
    # After the Claude Code step: it installs the claude CLI this step registers (user scope).
    if [ "${DO_CLAUDE}" = 0 ] || [ ! -d "${HERE}/claude-code" ]; then K_ARGS+=(--no-claude); fi
    if [ "${DRY}" = 1 ] && [ ! -f "${WIKI_HOME}/.env" ]; then
        # The wiki layer was not really installed (this is a dry run), and the kit refuses to run
        # without ${WIKI_HOME}/.env even with --dry-run: show what would run instead of dying.
        DRY_KIT_ARGS=""
        if [ "${#K_ARGS[@]}" -gt 0 ]; then DRY_KIT_ARGS=" ${K_ARGS[*]}"; fi
        note "[dry-run] wiki-mcp-kit/install-wiki-mcp.sh${DRY_KIT_ARGS}"
    else
        "${HERE}/wiki-mcp-kit/install-wiki-mcp.sh" ${K_ARGS[@]+"${K_ARGS[@]}"} \
            || die "the wiki-mcp kit failed; it rolls itself back, so Open WebUI still works the old way (mcpo spawns wiki-mcp over stdio). See ${WIKI_HOME}/logs/http.log; once fixed, rerun just wiki-mcp-kit/install-wiki-mcp.sh"
    fi
fi
echo
echo "######## 6/7 VS Code add-on: the app, Foam and Claude Code extensions, settings"
if [ "${DO_VSCODE}" = 0 ]; then
    note "--no-vscode: skipped"
elif [ ! -d "${HERE}/vscode-addon" ]; then
    # Bundles from before the add-on was shipped.
    note "this bundle has no vscode-addon/: skipped"
else
    # After the Claude Code step: the user settings are built from the ~/.config/claude-lms/env it writes,
    # and the wiki step has made the folder --wiki points at (it only warns when it is missing).
    V_ARGS+=(--wiki="${WIKI_HOME}/wiki")
    if [ -n "${VSCODE_APP_DIR}" ]; then
        V_ARGS+=(--app-dir="${VSCODE_APP_DIR}")
        if [ "${VSCODE_NO_APP}" = 1 ]; then V_ARGS+=(--no-app); fi
    else
        vscode_app_args
    fi
    "${HERE}/vscode-addon/install-vscode.sh" ${V_ARGS[@]+"${V_ARGS[@]}"} \
        || die "the VS Code add-on failed; everything before it is installed and working. Once fixed (e.g. quit VS Code), rerun just vscode-addon/install-vscode.sh"
fi
echo
echo "######## 7/7 HOP viewer: opens .hwp/.hwpx files (HOP app, LaunchServices)"
if [ "${DO_HOP}" = 0 ]; then
    note "--no-hop: skipped"
elif [ ! -d "${HERE}/hop-viewer" ]; then
    # Bundles from before the HOP viewer was shipped.
    note "this bundle has no hop-viewer/: skipped"
elif [ -n "${HOP_APP_DIR}" ]; then
    H_ARGS+=(--app-dir="${HOP_APP_DIR}")
    "${HERE}/hop-viewer/install-hop.sh" ${H_ARGS[@]+"${H_ARGS[@]}"} \
        || die "the HOP viewer failed; everything before it is installed and working. Once fixed (e.g. quit HOP), rerun just hop-viewer/install-hop.sh"
elif hop_app_args; then
    "${HERE}/hop-viewer/install-hop.sh" ${H_ARGS[@]+"${H_ARGS[@]}"} \
        || die "the HOP viewer failed; everything before it is installed and working. Once fixed (e.g. quit HOP), rerun just hop-viewer/install-hop.sh"
fi
