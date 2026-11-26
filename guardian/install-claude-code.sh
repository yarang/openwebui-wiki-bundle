#!/bin/bash
# ==============================================================================
# Claude Code installer (offline): the claude binary in this folder, plus claude-lms, which runs it on LM Studio
#
# Puts the binary where Claude Code's own native installer does (~/.local/share/claude/versions/<version>, linked
# from ~/.local/bin/claude), so `claude update` and a later official install work on it as usual. A same or newer
# claude already installed is kept. claude-lms goes to ~/.local/bin, its settings to ~/.config/claude-lms/env.
# The kit's slim system prompt (claude-kit/system-prompt.md) goes to ~/.config/claude-lms/system-prompt.md but is
# NOT turned on: CLAUDE_LMS_SYSTEM_PROMPT_FILE in the env file does that (a commented hint is written, an existing
# value is kept). claude-vscode — the VS Code extension's claudeProcessWrapper, applying the same settings — goes
# to ~/.local/bin. A kit older than either file installs as before: both are only skipped with a note.
# The hwpx, docx, xlsx and pptx skills from claude-kit/ are installed in ~/.claude/skills/<name>, hwpx vendoring
# python-hwpx from its wheel. With --with-router the llm-router (LM Studio and a DGX Spark behind one Anthropic
# base URL) is installed from llm-router/ by its own installer, and claude-lms is pointed at it; the env also
# gains CLAUDE_LMS_PICKER='spark-large qwen3-coder local-fast qwen3-instruct' when it has none, so the VS Code
# extension's picker offers a working Opus, Sonnet, Haiku and Fable row from the start.
# The folder can be copied to a Mac on its own; install-all.sh runs it as the bundle's last step.
#
# Usage:  ./install-claude-code.sh [options]
#   --model=ID         LM Studio model claude-lms uses (default: the one in ~/.config/claude-lms/env, else the
#                      wiki's WIKI_INGEST_MODEL in ~/llm-wiki/.env, else the first LLM LM Studio lists; a default
#                      naming one id of the gemma alias pair is used as the id this Mac's LM Studio lists)
#   --context=N        least context length claude-lms loads the model with (default 65536)
#   --lmstudio-url=URL LM Studio server (default http://127.0.0.1:1234)
#   --with-router      also install the llm-router from ./llm-router (router.py, spark-model, its env file and
#                      LaunchAgent — not started; fill in ~/.config/llm-router/env yourself)
#   --router-load      --with-router, and bootstrap the LaunchAgent now (waits for /health)
#   --spark-url=URL    the Spark's vLLM URL, or a comma list of them, written into the router env (default
#                      http://spark.local:8000,http://spark.local:8001 — the two vLLM instances
#                      the Spark runs; SPARK_URL keeps the first URL, the switch URL is that host on 8010)
#   --spark-env=FILE   a file holding SPARK_API_KEY/SPARK_SWITCH_TOKEN (aliases VLLM_API_KEY/
#                      SWITCH_TOKEN); those keys are copied into the router env, others ignored
#   --no-skills        do not install the hwpx, docx, xlsx and pptx skills in ~/.claude/skills
#   --no-path          do not add ~/.local/bin to PATH in ~/.zshrc
#   --dry-run          show what would change
# ==============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL=""
CTX=""
URL=""
DO_PATH=1
DO_SKILLS=1
WITH_ROUTER=0
ROUTER_LOAD=0
DRY=0
SPARK_URL_OPT=""
SPARK_ENV_OPT=""
SPARK_API_KEY_VAL=""
SPARK_SWITCH_TOKEN_VAL=""
SPARK_ENV_IGNORED=""

for arg in "$@"; do
    case "${arg}" in
        --model=*) MODEL="${arg#--model=}" ;;
        --context=*) CTX="${arg#--context=}" ;;
        --lmstudio-url=*) URL="${arg#--lmstudio-url=}" ;;
        --no-skills) DO_SKILLS=0 ;;
        --no-path) DO_PATH=0 ;;
        --with-router) WITH_ROUTER=1 ;;
        --router-load) WITH_ROUTER=1; ROUTER_LOAD=1 ;;
        --spark-url=*) SPARK_URL_OPT="${arg#--spark-url=}" ;;
        --spark-env=*) SPARK_ENV_OPT="${arg#--spark-env=}" ;;
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '3,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
note() { echo "    $*"; }
run() { if [ "${DRY}" = 1 ]; then note "[dry-run] $*"; else "$@"; fi; }
# The preflight resolves the skills before "==> Claude Code" ever prints, but what it has to say about them
# (--no-skills, a skipped skill) belongs under step 3's "==> skills" header. Those lines are collected in
# SKILL_NOTES instead of printed, and printed there; the smoke's die prints them too — the one death that
# happens after the notes exist but before the header does.
skill_note() { SKILL_NOTES="${SKILL_NOTES:+${SKILL_NOTES}$'\n'}${1}"; }
print_skill_notes() {
    [ -n "${SKILL_NOTES}" ] || return 0
    while IFS= read -r sn; do
        note "${sn}"
    done <<<"${SKILL_NOTES}"
}

# Anthropic's Developer ID team and the binary's signing identifier.
TEAM="Q6L2SF6YDW"
IDENT="com.anthropic.claude-code"
BIN="${HERE}/claude"
VERSIONS="${HOME}/.local/share/claude/versions"
LINK="${HOME}/.local/bin/claude"
CONF_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/claude-lms"
CONF="${CONF_DIR}/env"
# The skills ship beside this script in claude-kit/skills/; hwpx's python-hwpx wheel is unzipped into its lib/.
KIT="${HERE}/claude-kit"
SKILL_SRC="${KIT}/skills/hwpx"
WHL="${KIT}/wheels/python_hwpx-6.11.0-py3-none-any.whl"
WHL_SHA256="4b8369414dcbf32036cf9ac7f9dbfe3dd78d0f62230969034e6e6b5085912a62"
# The office skills need no wheel, only their module in the python below: docx→docx, xlsx→openpyxl, pptx→pptx.
OFFICE_SKILLS="docx xlsx pptx"
SKILLS="${HOME}/.claude/skills"
BAK_DIR="${HOME}/.claude/skills-backup"
# The skill wrapper runs its python: the guardian venv unless CLAUDE_LMS_PY says otherwise.
PY="${CLAUDE_LMS_PY:-${HOME}/.guardian-llm/venv/bin/python}"

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
    # Pure bash on the captured output — `printf | grep -q` exits at its first match and SIGPIPEs printf under
    # pipefail, rejecting a good binary when codesign's output is large — same idiom as the model membership
    # check below, TEAM/IDENT quoted so they match literally.
    case $'\n'"${info}"$'\n' in *$'\n'"TeamIdentifier=${TEAM}"$'\n'*) ;; *) return 1 ;; esac
    case $'\n'"${info}"$'\n' in *$'\n'"Identifier=${IDENT}"$'\n'*) ;; *) return 1 ;; esac
}

# The python module an office skill's tool imports; a skill with no entry here is not one.
office_module() {
    case "${1}" in
        docx) echo "docx" ;;
        xlsx) echo "openpyxl" ;;
        pptx) echo "pptx" ;;
    esac
}

# Bounded import probe: perl's alarm survives exec and cuts a hung python. Only the exact stdout marker counts
# (/usr/bin/true also exits 0), and the probe writes nothing, so --dry-run runs it too.
py_probe() {
    if [ -x /usr/bin/perl ]; then
        /usr/bin/perl -e 'alarm 10; exec @ARGV' "${PY}" -I -c "$1" 2>/dev/null || true
    else
        "${PY}" -I -c "$1" 2>/dev/null || true
    fi
}

# claude-lms sources ~/.config/claude-lms/env as shell, so a line carried into the rewritten file must be
# one complete single-line literal assignment. This prints the number of the first offending line — never
# the line itself, which may hold CLAUDE_LMS_TOKEN — and exits 1 when the file has a CLAUDE_LMS_ assignment
# whose value is not exactly '...' with no ' inside, "..." with no " $ ` or \ inside, or a bare word of
# [A-Za-z0-9_./:@%+,=-] (empty allowed; an optional 'export ' may precede the key, trailing spaces may
# follow the value, and nothing else), or any non-comment line at all with an unbalanced quote — a
# multi-line quoted value could carry a data line that turns into code when the file is sourced. A
# comment line (# after optional blanks) cannot open a quote — an apostrophe in "# don't change" is
# prose — and any multi-line value still has to open on a non-comment line, which this still refuses.
check_conf_literals() {
    LC_ALL=C awk -v sq="'" -v dq='"' '
        {
            if ($0 ~ /^[[:space:]]*#/) next
            if (gsub(sq, sq) % 2 == 1) { print NR; exit 1 }
            if (gsub(dq, dq) % 2 == 1) { print NR; exit 1 }
            if ($0 ~ /^[[:space:]]*(export[[:space:]]+)?CLAUDE_LMS_[A-Z0-9_]+=/) {
                rest = substr($0, index($0, "=") + 1)
                sub(/[[:space:]]+$/, "", rest)
                ok = (rest ~ ("^" sq "[^" sq "]*" sq "$"))
                ok = ok || (rest ~ ("^" dq "[^" dq "`$\\\\]*" dq "$"))
                ok = ok || (rest ~ "^[A-Za-z0-9_./:@%+,=-]*$")
                if (!ok) { print NR; exit 1 }
            }
        }
    ' "$1"
}

# The last LLM_ROUTER_PORT the router's env file says, read the way router.py's _parse_env_file reads it:
# whitespace stripped, a leading 'export ' (one space, exactly — a tab after 'export' is no prefix there,
# so 'export<TAB>LLM_ROUTER_PORT=...' is not the key and falls back to the default) dropped and the rest
# stripped again, split at the first '=', one matching quote pair stripped, later lines winning, CR
# ignored. Empty when the file says nothing usable.
router_port() {
    LC_ALL=C awk -v sq="'" -v dq='"' '
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^#/) next
            sub(/^export [[:space:]]*/, "", line)
            if (line !~ /^LLM_ROUTER_PORT[[:space:]]*=/) next
            v = substr(line, index(line, "=") + 1)
            sub(/^[[:space:]]+/, "", v)
            sub(/[[:space:]]+$/, "", v)
            n = length(v)
            if (n >= 2 && (substr(v, 1, 1) == sq || substr(v, 1, 1) == dq) && substr(v, 1, 1) == substr(v, n, 1)) {
                v = substr(v, 2, n - 2)
            }
            port = v
        }
        END { print port }
    ' "$1"
}

# The last value a CLAUDE_LMS_ key in the env file says, normalized the way the carry rewrites it: leading
# whitespace and an optional 'export ' dropped, the LAST occurrence of the key winning, trailing whitespace
# stripped, then one matching pair of surrounding ' or " quotes removed — so `export KEY='v'` and
# `  KEY="v"` both read back as v. check_conf_literals and the carry parse those shapes, but the old sed
# read (^KEY= only, tr -d of every quote) did not, silently losing such a MODEL or CONTEXT on reinstall.
# Empty when the file says nothing about the key.
conf_value() {
    LC_ALL=C awk -v key="$1" -v sq="'" -v dq='"' '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/^export[[:space:]]+/, "", line)
            if (substr(line, 1, length(key) + 1) != key "=") next
            v = substr(line, length(key) + 2)
            sub(/[[:space:]]+$/, "", v)
            n = length(v)
            if (n >= 2 && (substr(v, 1, 1) == sq || substr(v, 1, 1) == dq) && substr(v, 1, 1) == substr(v, n, 1)) {
                v = substr(v, 2, n - 2)
            }
            val = v
        }
        END { print val }
    ' "$2"
}

# Succeeds when the value can be written into the conf as one '...' literal: claude-lms sources that file as
# shell, so a single quote would close the literal early (the rest of the value would run as code) and a
# control character — a newline from a hand-edited file or a malformed id LM Studio listed — would add whole
# lines to it. Escaping ('\''') is not an option: check_conf_literals refuses any ' inside a '...' line, so
# a file written with escapes would be rejected by the next install. Pure-bash pattern match, no pipe; the
# value itself is never printed by the callers — it may hold control characters.
conf_safe() {
    case "${1}" in
        *\'*|*[[:cntrl:]]*) return 1 ;;
    esac
}

# spark_switch_url URL — the spark-switch controller sits on the same Spark: same scheme and host,
# port 8010. The URL has already been validated (a plain http(s) URL) when this runs.
spark_switch_url() {
    local scheme rest
    case "${1}" in
        https://*) scheme="https"; rest="${1#https://}" ;;
        *) scheme="http"; rest="${1#http://}" ;;
    esac
    rest="${rest%%[/:?]*}"
    printf '%s://%s:8010' "${scheme}" "${rest}"
}

# spark_url_list_ok LIST — every entry of a --spark-url value (one URL or a comma list) must be a
# plain http(s) URL, the same rule a single URL always followed. An empty entry — a trailing or
# doubled comma — dies, so the list never reaches the env file with a hole in it. Dies here, in
# the preflight, before anything is written. The value is only checked, never split: the caller
# keeps it whole as SPARK_URLS and takes its first entry as SPARK_URL.
spark_url_list_ok() {
    local rest="${1}" entry
    while :; do
        entry="${rest%%,*}"
        case "${entry}" in
            http://*|https://*) ;;
            '') die "--spark-url has an empty entry (a trailing or doubled comma): every entry must be a URL" ;;
            *) die "--spark-url must start with http:// or https:// (every entry of the list)" ;;
        esac
        case "${entry}" in
            *\'*|*\"*|*[[:space:]]*|*[[:cntrl:]]*) die "--spark-url must be a plain URL: no quotes, whitespace or control characters" ;;
        esac
        case "${rest}" in
            *,*) rest="${rest#*,}" ;;
            *) break ;;
        esac
    done
}

# A value copied from the spark env file must be one plain word: empty, whitespace or control
# characters die. The key is named in the error, never the value.
spark_val_ok() {
    case "${1}" in
        ''|*[[:space:]]*|*[[:cntrl:]]*) return 1 ;;
    esac
    return 0
}

# spark_env_read FILE — reads the Spark side's env file the way router_port/conf_value read env
# lines: CR dropped, blank and '#' lines skipped, leading blanks and one 'export ' dropped, split
# at the first '=', surrounding whitespace stripped, one matching quote pair removed, the LAST
# occurrence of a key winning. SPARK_API_KEY and SPARK_SWITCH_TOKEN are what the router env wants;
# VLLM_API_KEY and SWITCH_TOKEN are the same keys under the Spark's own names and lose to a direct
# key. A wanted key whose value is not one plain word dies here — before anything is written —
# naming the key only, never the value. Other keys are ignored; their names are collected (only
# names that are safe to print) for one informational line. A file looser than mode 600 is only
# warned about.
spark_env_read() {
    local f="$1" line rest key val first last ak_d="" ak_a="" tok_d="" tok_a="" mode
    SPARK_API_KEY_VAL=""
    SPARK_SWITCH_TOKEN_VAL=""
    SPARK_ENV_IGNORED=""
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%$'\r'}"
        rest="${line#"${line%%[![:space:]]*}"}"
        case "${rest}" in ''|'#'*) continue ;; esac
        rest="${rest#export }"
        rest="${rest#"${rest%%[![:space:]]*}"}"
        case "${rest}" in *=*) ;; *) continue ;; esac
        key="${rest%%=*}"
        val="${rest#*=}"
        val="${val#"${val%%[![:space:]]*}"}"
        val="${val%"${val##*[![:space:]]}"}"
        if [ "${#val}" -ge 2 ]; then
            first="${val%"${val#?}"}"
            last="${val#"${val%?}"}"
            if [ "${first}" = "${last}" ]; then
                case "${first}" in
                    "'") val="${val#?}"; val="${val%?}" ;;
                    '"') val="${val#?}"; val="${val%?}" ;;
                esac
            fi
        fi
        case "${key}" in
            SPARK_API_KEY|VLLM_API_KEY|SPARK_SWITCH_TOKEN|SWITCH_TOKEN)
                spark_val_ok "${val}" || die "--spark-env: ${key} in ${f} is empty or holds whitespace or a control character" ;;
        esac
        case "${key}" in
            SPARK_API_KEY) ak_d="${val}" ;;
            VLLM_API_KEY) ak_a="${val}" ;;
            SPARK_SWITCH_TOKEN) tok_d="${val}" ;;
            SWITCH_TOKEN) tok_a="${val}" ;;
            *)
                # Only a name that cannot carry anything odd is ever printed.
                case "${key}" in
                    ''|*[!A-Za-z0-9_.-]*) ;;
                    *) case " ${SPARK_ENV_IGNORED} " in *" ${key} "*) ;; *) SPARK_ENV_IGNORED="${SPARK_ENV_IGNORED:+${SPARK_ENV_IGNORED} }${key}" ;; esac ;;
                esac
                ;;
        esac
    done <"${f}"
    SPARK_API_KEY_VAL="${ak_d:-${ak_a}}"
    SPARK_SWITCH_TOKEN_VAL="${tok_d:-${tok_a}}"
    mode="$(stat -f '%Lp' "${f}" 2>/dev/null || true)"
    case "${mode}" in
        ''|*[!0-9]*) ;;
        *) [ $((8#${mode} & 8#077)) -eq 0 ] || note "warning: ${f} is mode ${mode}: spark keys belong in a 600 file" ;;
    esac
    [ -n "${SPARK_ENV_IGNORED}" ] || return 0
    note "spark env ${f}: ignored keys: ${SPARK_ENV_IGNORED}"
}

[ -f "${BIN}" ] || die "${BIN} is missing"
[ -f "${HERE}/VERSION" ] || die "${HERE}/VERSION is missing"
VER="$(head -1 "${HERE}/VERSION")"
check_binary "${BIN}" || die "${BIN} is not Anthropic's signed Claude Code"
# Before anything is written: the skill's wheel is pinned, so a kit holding anything else (broken or tampered
# with) stops the whole install here, claude-lms included.
if [ "${DO_SKILLS}" = 1 ] && [ -d "${SKILL_SRC}" ]; then
    GOT_SHA=""
    if [ -f "${WHL}" ]; then
        GOT_SHA="$(shasum -a 256 "${WHL}" 2>/dev/null | awk '{print $1}' || true)"
    fi
    [ "${GOT_SHA}" = "${WHL_SHA256}" ] || die "${WHL} is missing or its sha256 is not ${WHL_SHA256}"
fi
# Which skills this run installs — resolved here, read-only, in BOTH modes (a dry run needs SELECTED for its
# step-3 notes). The hwpx tool imports lxml.etree, not bare lxml (that hides a broken C extension); an office
# skill imports only its own module. A probe that fails skips that one skill with a warning — never an error,
# the other skills still install — and nothing is written to ~/.claude on that path.
SELECTED=""
SKILL_NOTES=""
if [ "${DO_SKILLS}" = 0 ]; then
    skill_note "--no-skills: skipped"
elif [ ! -d "${KIT}/skills" ]; then
    skill_note "no claude-kit/ in ${HERE}: skills skipped"
else
    if [ -d "${SKILL_SRC}" ] && [ -x "${PY}" ] \
        && [ "$(py_probe 'import lxml.etree; print("lxml-ok")')" = "lxml-ok" ]; then
        SELECTED="hwpx"
    else
        skill_note "warning: ${PY} cannot import lxml (guardian bundle not installed?): hwpx skill skipped"
    fi
    for s in ${OFFICE_SKILLS}; do
        mod="$(office_module "${s}")"
        if [ -d "${KIT}/skills/${s}" ] && [ -x "${PY}" ] \
            && [ "$(py_probe "import ${mod}; print(\"${mod}-ok\")")" = "${mod}-ok" ]; then
            SELECTED="${SELECTED:+${SELECTED} }${s}"
        else
            skill_note "warning: ${PY} cannot import ${mod}: ${s} skill skipped"
        fi
    done
fi
# Same rule for the router: the five files its installer copies must all be here (the installer executable
# among them), and the python the skills use — the one router.py will run on — must import what router.py
# needs. Probed before anything is written, dry run included: a dry run reports what the real run would do,
# and the real run would fail right here. One indulgence: on a clean Mac the venv only appears in
# install-all.sh's step 1, so a dry run may preview without it (a real run still dies there).
ROUTER_INSTALLER="${HERE}/llm-router/install-llm-router.sh"
ROUTER_ENV="${HOME}/.config/llm-router/env"
if [ "${WITH_ROUTER}" = 1 ]; then
    for rf in router.py spark-model install-llm-router.sh env.example README.md; do
        [ -f "${HERE}/llm-router/${rf}" ] || die "${HERE}/llm-router/${rf} is missing: this kit ships no llm-router"
    done
    [ -x "${ROUTER_INSTALLER}" ] || die "${ROUTER_INSTALLER} is not executable: this kit ships no llm-router"
    if [ -x "${PY}" ]; then
        [ "$(py_probe 'import fastapi, httpx, uvicorn; print("router-ok")')" = "router-ok" ] \
            || die "${PY} cannot import fastapi/httpx/uvicorn (router.py needs them); install the router with a python that can (the guardian bundle's venv has them)"
    elif [ "${DRY}" = 1 ]; then
        note "python not there yet (fine for a dry run)"
    else
        die "python not found at ${PY}: the router needs it (CLAUDE_LMS_PY or the guardian venv)"
    fi
fi
# The Spark options, validated before anything is written. Without --with-router they are
# meaningless: each gets one warning line and is dropped — a direct-mode install must not fail
# over an option it would never use, bad value or not. With the router, every entry of
# --spark-url (one URL or a comma list) must be a plain http(s) URL — an empty entry, e.g. a
# trailing comma, dies — and the env file must exist, be readable and parse (spark_env_read dies
# on a key that is not one plain word). The Spark defaults to the pair of vLLM instances it runs
# (:8000 qwen3-instruct, :8001 qwen3-coder): SPARK_URLS holds the whole list, SPARK_URL its
# first entry, and the switch URL follows that first entry: same scheme and host, 8010.
SPARK_URLS="http://spark.local:8000,http://spark.local:8001"
SPARK_URL="http://spark.local:8000"
SPARK_SWITCH_URL="http://spark.local:8010"
if [ "${WITH_ROUTER}" = 0 ]; then
    if [ -n "${SPARK_URL_OPT}" ] || [ -n "${SPARK_ENV_OPT}" ]; then
        note "warning: --spark-url and --spark-env need --with-router: ignored"
        SPARK_URL_OPT=""
        SPARK_ENV_OPT=""
    fi
else
    if [ -n "${SPARK_URL_OPT}" ]; then
        spark_url_list_ok "${SPARK_URL_OPT}"
        SPARK_URLS="${SPARK_URL_OPT}"
        SPARK_URL="${SPARK_URL_OPT%%,*}"
        SPARK_SWITCH_URL="$(spark_switch_url "${SPARK_URL}")"
    fi
    if [ -n "${SPARK_ENV_OPT}" ]; then
        [ -f "${SPARK_ENV_OPT}" ] || die "--spark-env: ${SPARK_ENV_OPT} is not a file"
        [ -r "${SPARK_ENV_OPT}" ] || die "--spark-env: ${SPARK_ENV_OPT} is not readable"
        spark_env_read "${SPARK_ENV_OPT}"
    fi
fi
# And the file step 2 rewrites: its carried lines must be complete single-line literals (checked above),
# or the install is refused here — before anything is written, dry run included — naming the file and the
# offending line number only, never the line's content.
if [ -f "${CONF}" ]; then
    conf_bad=""
    if ! conf_bad="$(check_conf_literals "${CONF}")"; then
        die "${CONF} line ${conf_bad}: not a single-line literal CLAUDE_LMS_ assignment (or an unbalanced quote); fix the file by hand and rerun"
    fi
fi

# Everything claude-lms's settings need is resolved and validated here, before anything is written: a bad
# --context, no model at all, or a model LM Studio does not list refuses the whole install — binary and
# claude-lms included — leaving the machine as it was.
OLD_MODEL=""; OLD_URL=""; OLD_CTX=""
if [ -f "${CONF}" ]; then
    OLD_MODEL="$(conf_value CLAUDE_LMS_MODEL "${CONF}")"
    OLD_URL="$(conf_value CLAUDE_LMS_URL "${CONF}")"
    OLD_CTX="$(conf_value CLAUDE_LMS_CONTEXT "${CONF}")"
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

# model_alias ID — the other id of the gemma alias pair, nothing when ID is not one of the pair. LM Studio names a
# model after where its files sit, so the same bundled gemma is listed as google/gemma-4-e4b on a Mac that got it
# through the LM Studio hub catalog and as gemma-4-e4b-it-mlx where the bundle's installer copied it; a model id
# taken over from the claude-lms conf or the wiki's .env can therefore name the id this Mac does not list. This
# case statement is the one place that knows the pair, and only a value inside it is ever swapped.
model_alias() {
    case "${1}" in
        google/gemma-4-e4b) printf '%s' "gemma-4-e4b-it-mlx" ;;
        gemma-4-e4b-it-mlx) printf '%s' "google/gemma-4-e4b" ;;
    esac
}
IDS="$(list_ids)"
if [ -z "${MODEL}" ]; then
    # The first LLM listed, embedding models skipped, blank records skipped too (an empty id in the listing
    # must not become the model) — one awk over the captured list, no pipe whose reader could SIGPIPE under
    # pipefail.
    MODEL="$(LC_ALL=C awk 'NF && tolower($0) !~ /embed|bge|nomic/ { print; exit }' <<<"${IDS}")"
    src="LM Studio's first LLM"
fi
[ -n "${MODEL}" ] || die "no model to use: pass --model=ID (LM Studio is not answering at ${URL}, or has no LLM)"
# Both settings are final here and nothing has been written yet: one that cannot be a '...' literal refuses
# the whole install — binary and claude-lms included. The message names the setting and where it came from
# (${src} for the model) but never the value itself.
conf_safe "${MODEL}" || die "the model from ${src} has a single quote or a control character in it; pass a plain --model=ID instead"
conf_safe "${URL}" || die "the LM Studio URL (--lmstudio-url or ${CONF}) has a single quote or a control character in it; pass a plain --lmstudio-url=URL instead"
if [ -z "${IDS}" ]; then
    note "warning: LM Studio does not answer at ${URL}; ${MODEL} is not checked"
else
    # Pure bash on the captured list — `printf | grep -qxF` races SIGPIPE under pipefail — with MODEL quoted
    # so it matches literally, glob characters included.
    case $'\n'"${IDS}"$'\n' in
        *$'\n'"${MODEL}"$'\n'*) ;;
        *)
            # A model taken over from the conf or the wiki's .env can be the other side of the gemma alias pair
            # (model_alias above): the same model under the id this Mac's LM Studio lists. Only that pair swaps;
            # an explicit --model is what the user asked for and is refused as before.
            alt=""
            case "${src}" in
                "${CONF}"|WIKI_INGEST_MODEL) alt="$(model_alias "${MODEL}")" ;;
            esac
            if [ -n "${alt}" ]; then
                case $'\n'"${IDS}"$'\n' in
                    *$'\n'"${alt}"$'\n'*)
                        note "${MODEL} is listed as ${alt} on this Mac's LM Studio: using ${alt}"
                        MODEL="${alt}"
                        ;;
                    *) die "LM Studio at ${URL} has no model ${MODEL}; it lists: $(printf '%s' "${IDS}" | tr '\n' ' ')" ;;
                esac
            else
                die "LM Studio at ${URL} has no model ${MODEL}; it lists: $(printf '%s' "${IDS}" | tr '\n' ' ')"
            fi
            ;;
    esac
fi
# The rest of an existing env file is the user's: CLAUDE_LMS_ROUTER, LARGE, FAST, SUBAGENT, TOKEN, ... are
# carried over (MODEL/URL/CONTEXT above are written fresh). The preflight proved every CLAUDE_LMS_ line in
# the file is one complete single-line literal, so only those are carried, written normalized (KEY= with
# the value exactly as found, a leading 'export ' dropped). The last occurrence of each key wins, and the
# kept lines stay in the order of those last occurrences, so a hand-edited or double-written file still
# survives a reinstall.
carry=""
if [ -f "${CONF}" ]; then
    carry="$(LC_ALL=C awk '
        { raw[NR] = $0 }
        END {
            for (i = NR; i >= 1; i--) {
                line = raw[i]
                if (line !~ /^[[:space:]]*(export[[:space:]]+)?CLAUDE_LMS_[A-Z0-9_]+=/) continue
                sub(/^[[:space:]]*(export[[:space:]]+)?/, "", line)
                key = line
                sub(/=.*/, "", key)
                if (key == "CLAUDE_LMS_MODEL" || key == "CLAUDE_LMS_URL" || key == "CLAUDE_LMS_CONTEXT") continue
                if (key in seen) continue
                seen[key] = 1
                sub(/[[:space:]]+$/, "", line)
                out[++n] = line
            }
            for (i = n; i >= 1; i--) print out[i]
        }
    ' "${CONF}")"
fi
# The key names alone, for the dry-run line below: a carried value may be CLAUDE_LMS_TOKEN, and no value
# is ever printed. Built from the validated carry with plain bash — no pipe to a reader that could mask
# a failure (pipefail), and nothing here can turn a value into output.
carry_keys=""
if [ -n "${carry}" ]; then
    while IFS= read -r kept; do
        carry_keys="${carry_keys:+${carry_keys}, }${kept%%=*}"
    done <<<"${carry}"
fi
# With the router installed, claude-lms should reach it through one base URL — unless the user already
# chose a router (their line was carried over above and wins as it is). The port is the one the router
# will actually use, read from ~/.config/llm-router/env exactly as router.py reads it (later lines win,
# quotes and 'export ' handled), else 1240 (env.example's own default, so a first install matches what
# the router starts on). Pure bash test on the captured carry — `printf | grep -q` races SIGPIPE under
# pipefail and can drop the router line.
router_line=""
if [ "${WITH_ROUTER}" = 1 ]; then
    case $'\n'"${carry}" in
        *$'\n'CLAUDE_LMS_ROUTER=*) ;;    # the user's own carried router line wins as it is
        *)
            rport=""
            if [ -f "${ROUTER_ENV}" ]; then rport="$(router_port "${ROUTER_ENV}")"; fi
            case "${rport}" in ''|*[!0-9]*) rport=1240 ;; esac
            router_line="CLAUDE_LMS_ROUTER='http://127.0.0.1:${rport}'"
            ;;
    esac
fi

# The VS Code add-on reads CLAUDE_LMS_PICKER for its model picker. With the router installed the
# extension should offer the Spark's models from the start, so the line is added when the user
# has none; a CLAUDE_LMS_PICKER they wrote themselves was carried over above and wins as it is.
# Four ids fill the picker's four rows — Opus spark-large, Sonnet qwen3-coder, Haiku local-fast,
# Fable qwen3-instruct — so no row repeats the first pick and every row works through the router
# even when it is not answering at install time. The value is fixed aliases, so the dry-run line
# below prints it in full.
picker_line=""
if [ "${WITH_ROUTER}" = 1 ]; then
    case $'\n'"${carry}" in
        *$'\n'CLAUDE_LMS_PICKER=*) ;;
        *) picker_line="CLAUDE_LMS_PICKER='spark-large qwen3-coder local-fast qwen3-instruct'" ;;
    esac
fi

# The system prompt installed in step 2 is left OFF: turning it on is the user's call, and the hint
# names the key so it is one uncomment. A CLAUDE_LMS_SYSTEM_PROMPT_FILE the conf already carries
# (set, or cleared on purpose) wins and no hint is written; neither is one when the kit ships no
# system-prompt.md — the file the hint would point at is not installed then.
prompt_hint=""
if [ -f "${KIT}/system-prompt.md" ]; then
    case $'\n'"${carry}" in
        *$'\n'CLAUDE_LMS_SYSTEM_PROMPT_FILE=*) ;;
        *) prompt_hint="# CLAUDE_LMS_SYSTEM_PROMPT_FILE='${CONF_DIR}/system-prompt.md'" ;;
    esac
fi

# The skills' staging and smoke, last check of the preflight: with everything else proven, each selected
# skill is copied into one TMPDIR folder, finished (wheel unzipped, wrappers executable) and proven to run
# with this python — write and re-read a document — while nothing has been written yet (the binary and
# claude-lms below have not run), so a failure here really does leave the machine as it was. Real runs only:
# a dry run writes nothing, so it stages nothing either — its skill notes (step 3) come from SELECTED above.
if [ "${DRY}" = 0 ] && [ -n "${SELECTED}" ]; then
    T="$(mktemp -d "${TMPDIR:-/tmp}/claude-lms-skills.XXXXXX")"
    # Removes only the staging folder: no ~/.claude path exists yet, nothing has been written.
    trap 'rm -rf "${T:?}"' EXIT
    for s in ${SELECTED}; do
        STAGE="${T}/${s}"
        cp -R "${KIT}/skills/${s}" "${STAGE}"
        find "${STAGE}" \( -name __pycache__ -o -name .DS_Store \) -prune -exec rm -rf {} +
        if [ "${s}" = hwpx ]; then
            /usr/bin/unzip -qo "${WHL}" -d "${STAGE}/lib"
            chmod 755 "${STAGE}/scripts/hwpx"
            chmod 755 "${STAGE}/scripts/skill-guard"
        else
            chmod 755 "${STAGE}/scripts/${s}"
        fi
        xattr -dr com.apple.quarantine "${STAGE}" 2>/dev/null || true
    done
    # Smoke: every staged copy must write and re-read a document with this python before anything of the
    # user's moves. They all run first — one failing skill means no skill at all is installed, hwpx included.
    for s in ${SELECTED}; do
        SMOKED=0
        LINE1=""
        if [ "${s}" = hwpx ]; then
            CHECK="validate"
            if printf '# 시험\n\n본문\n' >"${T}/a.md" \
                && CLAUDE_LMS_PY="${PY}" "${T}/hwpx/scripts/hwpx" from-md "${T}/a.md" "${T}/a.hwpx" >"${T}/hwpx.log" 2>&1; then
                LINE1="$(CLAUDE_LMS_PY="${PY}" "${T}/hwpx/scripts/hwpx" validate "${T}/a.hwpx" 2>&1 | head -1 || true)"
                case "${LINE1}" in
                    OK*) SMOKED=1 ;;
                esac
            fi
        else
            CHECK="read"
            # xlsx refuses markdown without a table, so the sample carries a GFM table for all three.
            printf '# 시험\n\n## 표\n\n| 항목 | 값 |\n| --- | --- |\n| 가 | 1 |\n' >"${T}/s.md"
            if CLAUDE_LMS_PY="${PY}" "${T}/${s}/scripts/${s}" from-md "${T}/s.md" "${T}/s.${s}" >"${T}/${s}.log" 2>&1; then
                LINE1="$(CLAUDE_LMS_PY="${PY}" "${T}/${s}/scripts/${s}" read "${T}/s.${s}" 2>&1 | head -1 || true)"
                case "${LINE1}" in
                    OK*) SMOKED=1 ;;
                esac
            fi
        fi
        find "${T}/${s}" \( -name __pycache__ -o -name .DS_Store \) -prune -exec rm -rf {} +
        if [ "${SMOKED}" != 1 ]; then
            # The held-back skill notes would die with this die, unread: the user still gets them here, and
            # then the tool's own words say why, before the log goes with T.
            print_skill_notes
            tail -n 20 "${T}/${s}.log" 2>/dev/null | sed 's/^/    /' >&2 || true
            if [ -n "${LINE1}" ]; then
                printf '    %s\n' "${LINE1}" >&2
            fi
            rm -rf "${T:?}"
            die "the ${s} skill does not run with ${PY} (a staged copy failed from-md/${CHECK}); nothing was changed"
        fi
    done
fi

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
# The kit's slim system prompt, installed beside the env file but never turned on (the conf's hint
# line names the switch). A different file already there is the user's own: kept aside as
# system-prompt.md.bak-<timestamp>, then replaced — the same one-file rule the skills follow. A kit
# without it (older than this file) installs as before.
install_system_prompt() {
    if [ ! -f "${KIT}/system-prompt.md" ]; then
        note "no system-prompt.md in ${KIT}: skipped"
        return 0
    fi
    if [ -f "${CONF_DIR}/system-prompt.md" ] && cmp -s "${KIT}/system-prompt.md" "${CONF_DIR}/system-prompt.md"; then
        note "${CONF_DIR}/system-prompt.md already up to date"
        return 0
    fi
    if [ -e "${CONF_DIR}/system-prompt.md" ] || [ -L "${CONF_DIR}/system-prompt.md" ]; then
        BAK="${CONF_DIR}/system-prompt.md.bak-$(date +%Y%m%d-%H%M%S)"
        if [ -e "${BAK}" ] || [ -L "${BAK}" ]; then BAK="${CONF_DIR}/system-prompt.md.bak-$(date +%Y%m%d-%H%M%S)-$$"; fi
        run mv "${CONF_DIR}/system-prompt.md" "${BAK}"
        [ "${DRY}" = 1 ] || note "previous copy kept as ${BAK}"
    fi
    run cp "${KIT}/system-prompt.md" "${CONF_DIR}/system-prompt.md"
    run chmod 644 "${CONF_DIR}/system-prompt.md"
}
echo "==> claude-lms"
run cp "${HERE}/claude-lms" "${HOME}/.local/bin/claude-lms"
run chmod 755 "${HOME}/.local/bin/claude-lms"
# The VS Code extension's claudeProcessWrapper (install-vscode.sh points the extension at it): it
# reads the same env file and adds the same --disallowedTools/--system-prompt-file. A kit older than
# this file installs as before.
if [ -f "${HERE}/claude-vscode" ]; then
    run cp "${HERE}/claude-vscode" "${HOME}/.local/bin/claude-vscode"
    run chmod 755 "${HOME}/.local/bin/claude-vscode"
else
    note "no claude-vscode in ${HERE}: skipped"
fi
if [ "${DRY}" = 1 ]; then
    note "[dry-run] ${CONF}: model ${MODEL} (from ${src}), context ${CTX}, ${URL}"
    [ -z "${carry_keys}" ] || note "[dry-run] keep ${carry_keys}"
    [ -z "${router_line}" ] || note "[dry-run] add ${router_line}"
    [ -z "${picker_line}" ] || note "[dry-run] add ${picker_line}"
    [ -z "${prompt_hint}" ] || note "[dry-run] add ${prompt_hint}"
    install_system_prompt
else
    mkdir -p "${CONF_DIR}"
    install_system_prompt
    # The file holds CLAUDE_LMS_TOKEN, so the replacement is born 600 and alone: mktemp makes a fresh
    # 0600 file (O_EXCL, unique name) in CONF_DIR, every line of content goes into it with one
    # redirect under umask 077, and only the finished file is moved into place — whatever the caller's
    # umask is. No fixed-name partial exists for a concurrent run to delete (making >> recreate it
    # world-readable) or to swap for a symlink; a stale .partial from an older version is ignored.
    CONF_TMP="$(mktemp "${CONF_DIR}/.env.XXXXXX")"
    ( umask 077; {
        echo "# claude-lms settings (install-claude-code.sh). The same names in the environment win."
        echo "CLAUDE_LMS_MODEL='${MODEL}'"
        echo "CLAUDE_LMS_URL='${URL}'"
        echo "CLAUDE_LMS_CONTEXT=${CTX}"
        [ -z "${carry}" ] || printf '%s\n' "${carry}"
        [ -z "${router_line}" ] || printf '%s\n' "${router_line}"
        [ -z "${picker_line}" ] || printf '%s\n' "${picker_line}"
        [ -z "${prompt_hint}" ] || printf '%s\n' "${prompt_hint}"
    } >"${CONF_TMP}" ) || { rm -f "${CONF_TMP}"; die "could not write ${CONF}"; }
    mv -f "${CONF_TMP}" "${CONF}"
    note "${CONF}: model ${MODEL} (from ${src}), context ${CTX}, ${URL}"
fi

# ---- 3. skills ------------------------------------------------------------------------------
# Each SKILL.md calls its tool at ~/.claude/skills/<name>/scripts/<name>, so that is the one place the skills are
# installed. Anything else in ~/.claude/skills (other skills) is never touched.
echo "==> skills"
# The preflight's skill lines (--no-skills, skipped skills) print here, under the header they are about,
# before the SELECTED-driven notes below.
print_skill_notes
# Which skills this run installs (SELECTED) was resolved in the preflight above — and on a real run each
# selected skill was already staged into T and smoke-proven there, also in the preflight, before the binary
# and claude-lms were written. All that is left here is the move into ~/.claude/skills itself.
if [ "${DO_SKILLS}" = 1 ] && [ -d "${KIT}/skills" ]; then
    if [ -z "${SELECTED}" ]; then
        note "no skill can run with ${PY}: nothing installed"
    elif [ "${DRY}" = 1 ]; then
        note "[dry-run] skills are smoke-tested only on a real run (staged under TMPDIR before anything is written)"
        for s in ${SELECTED}; do
            if [ "${s}" = hwpx ]; then
                note "[dry-run] install the hwpx skill in ${SKILLS}/hwpx (python-hwpx from ${WHL##*/})"
            else
                note "[dry-run] install the ${s} skill in ${SKILLS}/${s}"
            fi
        done
    else
        # A crashed run may have left partials; they never become the install. All four are cleared here — the
        # staged copies in T were proven in the preflight, so from here on ~/.claude only ever loses stale
        # files or gains whole, proven skills. Each skill's copy moves in by one rename within ~/.claude's
        # volume, so an interrupted run cannot leave a half-written skill.
        for s in hwpx ${OFFICE_SKILLS}; do rm -rf "${HOME:?}/.claude/.claude-lms-${s}.partial"; done
        trap 'rm -rf "${T:?}" "${HOME:?}/.claude/.claude-lms-hwpx.partial" "${HOME:?}/.claude/.claude-lms-docx.partial" \
"${HOME:?}/.claude/.claude-lms-xlsx.partial" "${HOME:?}/.claude/.claude-lms-pptx.partial"' EXIT
        # Only now, with every staged copy proven, does ~/.claude gain anything. Skills install in a fixed order
        # (hwpx first): an unchanged one is left alone, a changed one is replaced.
        for s in ${SELECTED}; do
            DEST="${SKILLS}/${s}"
            STAGE="${T}/${s}"
            PART="${HOME}/.claude/.claude-lms-${s}.partial"
            if [ -d "${DEST}" ] && [ ! -L "${DEST}" ] && [ -x "${DEST}/scripts/${s}" ] \
                && diff -rq -x __pycache__ -x .DS_Store "${DEST}" "${STAGE}" >/dev/null 2>&1; then
                note "${DEST} already up to date"
            else
                # mv across volumes degrades to copy+delete, so the finished copy sits beside DEST first (same
                # volume) and only the last mv, a plain rename, writes into skills/.
                mkdir -p "${HOME}/.claude"
                cp -R "${STAGE}" "${PART}"
                if [ "${s}" = hwpx ]; then
                    # A stray bare `import hwpx` must not plant __pycache__ inside the install, yet the tree stays
                    # plain user data (rm -rf works, mode bits keep owner-write): an ACL denies creating entries
                    # in lib's dirs. That is only extra hardening: a volume without ACLs (FAT/exFAT, some network
                    # mounts) loses it, not the install.
                    find "${PART}/lib" -type d -exec chmod +a "owner deny add_file,add_subdirectory" {} + 2>/dev/null \
                        || note "lib ACL not supported on this volume: skipped"
                fi
                if [ -e "${DEST}" ] || [ -L "${DEST}" ]; then
                    # Outside skills/, or Claude Code would see two ${s} skills; a link moves as a link, target
                    # untouched.
                    mkdir -p "${BAK_DIR}"
                    BAK="${BAK_DIR}/${s}.$(date +%Y%m%d-%H%M%S).$$"
                    mv "${DEST}" "${BAK}"
                    note "previous copy moved to ${BAK}"
                fi
                mkdir -p "${SKILLS}"
                mv "${PART}" "${DEST}"
                note "installed ${DEST}"
            fi
        done
        rm -rf "${T:?}"
        trap - EXIT
    fi
fi

# ---- 3b. llm-router ------------------------------------------------------------------------
# Its own installer does the work (router.py, spark-model, the env file, the LaunchAgent — started
# only with --router-load) with the same python the skills use. A non-zero exit stops this install
# (set -e). Without --with-router nothing here runs, so a Mac without a Spark is unchanged. One
# thing the router's installer cannot know: on a first install its env file comes from env.example
# with the template's LOCAL_URL/LOCAL_MODEL, while this run already resolved both (they were just
# written as CLAUDE_LMS_URL / CLAUDE_LMS_MODEL). So the installer first runs WITHOUT --load, a file
# this run created then gets LOCAL_URL/LOCAL_MODEL rewritten to that pair — and the template's
# commented SPARK_URL/SPARK_URLS/SPARK_SWITCH_URL lines activated to this run's Spark URLs, plus
# the keys --spark-env read — and only after that, once the env the router will actually read is
# final, does --router-load bootstrap the agent as a second installer run (idempotent: same files,
# the env kept because it now exists); loading first would start the router on env.example's
# values until its next restart. A file that existed before is the user's (SPARK_API_KEY
# included) and is rewritten only for the keys this run was told to set (--spark-url's three URL
# keys, --spark-env's two keys); with neither it is never touched at all. The file is never
# printed, and every rewrite
# goes file-to-file through a 600 mktemp'd temp in the same folder, same as every other settings
# write. Values reach awk through the environment (ENVIRON): -v would eat backslash escapes.
echo "==> llm-router"
if [ "${WITH_ROUTER}" = 0 ]; then
    note "llm-router: skipped (--with-router to install)"
else
    ROUTER_ENV_EXISTED=0
    if [ -f "${ROUTER_ENV}" ]; then ROUTER_ENV_EXISTED=1; fi
    # The keys this run writes into the router env, in order; a key the file does not carry is
    # appended at the end. UP_SHOW is the dry-run line: URLs and key names only, never a secret.
    UP_KEYS=""
    UP_SHOW=""
    if [ "${ROUTER_ENV_EXISTED}" = 0 ]; then
        UP_KEYS="LOCAL_URL LOCAL_MODEL SPARK_URL SPARK_URLS SPARK_SWITCH_URL"
        UP_SHOW="LOCAL_URL=${URL}, LOCAL_MODEL=${MODEL}, SPARK_URL=${SPARK_URL}, SPARK_URLS=${SPARK_URLS}, SPARK_SWITCH_URL=${SPARK_SWITCH_URL}"
    elif [ -n "${SPARK_URL_OPT}" ]; then
        UP_KEYS="SPARK_URL SPARK_URLS SPARK_SWITCH_URL"
        UP_SHOW="SPARK_URL=${SPARK_URL}, SPARK_URLS=${SPARK_URLS}, SPARK_SWITCH_URL=${SPARK_SWITCH_URL}"
    fi
    if [ -n "${SPARK_API_KEY_VAL}" ]; then
        UP_KEYS="${UP_KEYS:+${UP_KEYS} }SPARK_API_KEY"
        UP_SHOW="${UP_SHOW:+${UP_SHOW}, }SPARK_API_KEY from ${SPARK_ENV_OPT}"
    fi
    if [ -n "${SPARK_SWITCH_TOKEN_VAL}" ]; then
        UP_KEYS="${UP_KEYS:+${UP_KEYS} }SPARK_SWITCH_TOKEN"
        UP_SHOW="${UP_SHOW:+${UP_SHOW}, }SPARK_SWITCH_TOKEN from ${SPARK_ENV_OPT}"
    fi
    ROUTER_TPL=""
    if [ "${ROUTER_ENV_EXISTED}" = 0 ]; then ROUTER_TPL="1"; fi
    R_ARGS=(--python="${PY}")
    if [ "${DRY}" = 1 ]; then
        # One call previews both passes: same files, and the rewrite happens before --load would run.
        if [ "${ROUTER_LOAD}" = 1 ]; then R_ARGS+=(--load --dry-run); else R_ARGS+=(--dry-run); fi
        "${ROUTER_INSTALLER}" ${R_ARGS[@]+"${R_ARGS[@]}"}
        if [ -n "${UP_KEYS}" ]; then
            note "[dry-run] would set ${UP_SHOW} in ${ROUTER_ENV}"
        fi
    else
        "${ROUTER_INSTALLER}" ${R_ARGS[@]+"${R_ARGS[@]}"}
        if [ -n "${UP_KEYS}" ] && [ -f "${ROUTER_ENV}" ]; then
            ROUTER_TMP="$(mktemp "${HOME}/.config/llm-router/.env.XXXXXX")"
            # RE_TEMPLATE says the file came from env.example this run, so a commented '#KEY='
            # template line is activated for a key that has no active line yet. The '=' is part
            # of every pattern, so '#SPARK_URL=' never matches the '#SPARK_URLS=' line nor the
            # other way round — the two keys stay distinct however long their shared prefix is.
            # Every active 'KEY=' line is rewritten in place; keys the file does not carry are
            # appended at the end, in UP_KEYS order.
            ( umask 077; \
                RE_LOCAL_URL="${URL}" RE_LOCAL_MODEL="${MODEL}" RE_SPARK_URL="${SPARK_URL}" \
                RE_SPARK_URLS="${SPARK_URLS}" RE_SPARK_SWITCH_URL="${SPARK_SWITCH_URL}" \
                RE_SPARK_API_KEY="${SPARK_API_KEY_VAL}" \
                RE_SPARK_SWITCH_TOKEN="${SPARK_SWITCH_TOKEN_VAL}" UP_KEYS="${UP_KEYS}" \
                RE_TEMPLATE="${ROUTER_TPL}" \
                LC_ALL=C awk '
                    BEGIN { n = split(ENVIRON["UP_KEYS"], keys, " ") }
                    {
                        line = $0
                        for (i = 1; i <= n; i++) {
                            k = keys[i]
                            if (line ~ ("^[[:space:]]*(export[[:space:]]+)?" k "[[:space:]]*=")) {
                                print k "=" ENVIRON["RE_" k]
                                seen[k] = 1
                                next
                            }
                            if (ENVIRON["RE_TEMPLATE"] != "" && !seen[k] && line ~ ("^[[:space:]]*#" k "=")) {
                                print k "=" ENVIRON["RE_" k]
                                seen[k] = 1
                                next
                            }
                        }
                        print line
                    }
                    END {
                        for (i = 1; i <= n; i++) {
                            k = keys[i]
                            if (!seen[k]) print k "=" ENVIRON["RE_" k]
                        }
                    }
                ' "${ROUTER_ENV}" >"${ROUTER_TMP}" ) \
                || { rm -f "${ROUTER_TMP}"; die "could not rewrite ${ROUTER_ENV}"; }
            mv -f "${ROUTER_TMP}" "${ROUTER_ENV}"
            if [ "${ROUTER_ENV_EXISTED}" = 0 ]; then
                note "router env: LOCAL_URL=${URL}, LOCAL_MODEL=${MODEL}, SPARK_URL=${SPARK_URL}, SPARK_URLS=${SPARK_URLS}, SPARK_SWITCH_URL=${SPARK_SWITCH_URL} (this install's URL, model and Spark)"
            else
                note "router env: set ${UP_KEYS} in ${ROUTER_ENV}"
                if [ "${ROUTER_LOAD}" = 0 ]; then
                    note "llm-router: restart the router to apply (launchctl kickstart -k gui/$(id -u)/dev.guardian.llm-router, or rerun with --router-load)"
                fi
            fi
            [ -z "${SPARK_API_KEY_VAL}" ] || note "router env: set SPARK_API_KEY from ${SPARK_ENV_OPT}"
            [ -z "${SPARK_SWITCH_TOKEN_VAL}" ] || note "router env: set SPARK_SWITCH_TOKEN from ${SPARK_ENV_OPT}"
        fi
        if [ "${ROUTER_LOAD}" = 1 ]; then
            "${ROUTER_INSTALLER}" ${R_ARGS[@]+"${R_ARGS[@]}"} --load
        fi
    fi
fi

# ---- 4. PATH -------------------------------------------------------------------------------
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
if [ "${WITH_ROUTER}" = 1 ]; then
    if [ "${DRY}" = 1 ]; then
        echo "    llm-router: fill in SPARK_URL, SPARK_URLS and SPARK_API_KEY in ~/.config/llm-router/env (mode 600) before spark-large works"
    else
        # What the env the router will read actually holds, read back with the same parser that
        # reads CLAUDE_LMS_ keys: key names only — SPARK_API_KEY and SPARK_SWITCH_TOKEN are
        # secrets, so nothing read back from that file is ever printed.
        for rk in SPARK_URL SPARK_URLS SPARK_API_KEY SPARK_SWITCH_TOKEN; do
            rv=""
            if [ -f "${ROUTER_ENV}" ]; then rv="$(conf_value "${rk}" "${ROUTER_ENV}")"; fi
            if [ -n "${rv}" ]; then
                echo "    llm-router: ${rk} is set"
            else
                echo "    llm-router: ${rk} is empty: pass --spark-env=FILE (the Spark's env file) or edit ~/.config/llm-router/env (mode 600)"
            fi
        done
    fi
    if [ "${ROUTER_LOAD}" = 0 ]; then
        echo "    llm-router: start it with launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.guardian.llm-router.plist (or rerun with --router-load)"
    fi
    echo "    spark-model status    (what the Spark is serving through the router)"
fi
