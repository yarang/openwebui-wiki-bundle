#!/usr/bin/env bash
# ==============================================================================
# wiki-mcp kit → 하나의 오프라인 꾸러미 (빌드 Mac 에서 실행)
#
# wiki-mcp 를 "공용 HTTP 서버 하나"로 만드는 키트를 만든다: 여기서는 아무것도 내려받지
# 않는다. 휠은 저장소의 wiki-mcp 소스에서 직접 빌드하고(임시 복사본에서 — 빌드 부산물이
# 저장소를 더럽히지 않게), 나머지 파일은 guardian/wiki-mcp-kit/ 와 저장소 루트에서 온다.
#   <name>/install-wiki-mcp.sh  README.md  MANIFEST.env  SHA256SUMS
#   <name>/run-wiki-mcp.sh  load-env.sh   (저장소 루트의 것 — http 서브커맨드 포함)
#   <name>/wheels/wiki_mcp-<ver>-py3-none-any.whl
#   <name>.tar.gz + .sha256  what travels to the site Mac
#
# Usage:  guardian/pack-wiki-mcp-kit.sh [--python=PY] [--wheel=PATH] [--out=DIR] [--name=NAME] [--no-tar]
#   --python=PY  Python for the wheel build; must import setuptools and pip
#                (default: first of python3 python3.12 python3.13 python3.11 that can)
#   --wheel=PATH ship this wiki_mcp-<ver>-py3-none-any.whl instead of building one; its name must
#                match the pyproject.toml version. Skips the Python lookup entirely (build only)
#   --out=DIR    output folder (default <repo>/dist/wiki-mcp-kit)
#   --name=NAME  output name (default wiki-mcp-kit-<wiki_mcp version>; letters, digits, . _ - only)
#   --no-tar     stop after the folder (with SHA256SUMS); no .tar.gz is written
# On the site Mac:  shasum -a 256 -c <name>.tar.gz.sha256 && tar xzf <name>.tar.gz && cd <name> \
#   && shasum -a 256 -c SHA256SUMS && ./install-wiki-mcp.sh --dry-run
# ==============================================================================

set -euo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "${HERE}/.." && pwd)"
BUILT="$(date -u +%Y%m%dT%H%MZ)"

PYTHON_OPT=""
WHEEL_OPT=""
OUT=""
NAME=""
NAME_SET=0
DO_TAR=1

usage() { sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
for arg in "$@"; do
    case "${arg}" in
        --python=*)
            PYTHON_OPT="${arg#--python=}"
            [ -n "${PYTHON_OPT}" ] || { echo "error: --python= needs an interpreter" >&2; exit 2; } ;;
        --wheel=*)
            WHEEL_OPT="${arg#--wheel=}"
            [ -n "${WHEEL_OPT}" ] || { echo "error: --wheel= needs a .whl file" >&2; exit 2; } ;;
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

# ---- 1. 빌드에 쓸 Python ----------------------------------------------------------------------
# 휠 빌드는 --no-build-isolation 이므로 setuptools 가 그 인터프리터 안에 있어야 한다.
# 이 Mac 에서는 python3.11 만 그렇다; 다른 Mac 을 위해 후보를 차례로 본다.
# PY_BIN 은 휠 빌드에만 쓰이므로 --wheel 을 주면 이 단계 전체를 건너뛴다.
PY_BIN=""
PY_TRIED=""
if [ -n "${WHEEL_OPT}" ]; then
    log "wheel: reusing ${WHEEL_OPT} (--wheel: no build, no Python needed)"
elif [ -n "${PYTHON_OPT}" ]; then
    command -v "${PYTHON_OPT}" >/dev/null 2>&1 || die "--python=${PYTHON_OPT} not found on PATH"
    PY_BIN="${PYTHON_OPT}"
    "${PY_BIN}" -c 'import setuptools, pip' >/dev/null 2>&1 \
        || die "${PY_BIN} cannot import setuptools and pip (needed for --no-build-isolation)"
    log "wheel build python: ${PY_BIN}"
else
    for cand in python3 python3.12 python3.13 python3.11; do
        command -v "${cand}" >/dev/null 2>&1 || { PY_TRIED="${PY_TRIED} ${cand}(absent)"; continue; }
        if "${cand}" -c 'import setuptools, pip' >/dev/null 2>&1; then PY_BIN="${cand}"; break; fi
        PY_TRIED="${PY_TRIED} ${cand}(no setuptools)"
    done
    [ -n "${PY_BIN}" ] || die "no Python with setuptools+pip for the wheel build; tried:${PY_TRIED} — pass --python=PY"
    log "wheel build python: ${PY_BIN}"
fi

# ---- 2. 버전은 pyproject.toml 에서 -------------------------------------------------------------
VER="$(sed -n 's/^version = "\(.*\)"$/\1/p' "${SRC}/wiki-mcp/pyproject.toml" | head -1)"
[ -n "${VER}" ] || die "cannot read the version out of ${SRC}/wiki-mcp/pyproject.toml"
WHEEL_NAME="wiki_mcp-${VER}-py3-none-any.whl"

# Whole-string match (a line-based grep would pass a name holding a newline).
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
if [ "${NAME_SET}" = 1 ]; then
    # An explicitly empty --name= is refused, never quietly replaced by the default name.
    [ -n "${NAME}" ] || die "--name= must not be empty"
    valid_name "${NAME}" || die "--name must be letters, digits, . _ or - only: ${NAME}"
fi
[ -n "${NAME}" ] || NAME="wiki-mcp-kit-${VER}"
valid_name "${NAME}" || die "the default name is not a safe file name: ${NAME}"

# ---- 3. 꾸러미에 들어갈 자체 파일이 모두 있어야 한다 -------------------------------------------
ADDON="${HERE}/wiki-mcp-kit"
for f in "install-wiki-mcp.sh" "README.md"; do
    [ -f "${ADDON}/${f}" ] || die "${ADDON}/${f} is missing"
done
for f in "run-wiki-mcp.sh" "load-env.sh"; do
    [ -f "${SRC}/${f}" ] || die "${SRC}/${f} is missing"
done
[ -f "${SRC}/wiki-mcp/pyproject.toml" ] || die "${SRC}/wiki-mcp/pyproject.toml is missing"

# ---- 4. 스테이지 ------------------------------------------------------------------------------
OUT="${OUT:-${SRC}/dist/wiki-mcp-kit}"
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

PARTIAL=""
KIT_DIR=""
TAR_GZ=""
SHA_FILE=""
VERIFY_TMP=""
BUILD_TMP=""
cleanup() {
    rc=$?
    [ -z "${VERIFY_TMP}" ] || rm -rf "${VERIFY_TMP:?}"
    [ -z "${BUILD_TMP}" ] || rm -rf "${BUILD_TMP:?}"
    if [ "${rc}" -ne 0 ]; then
        [ -z "${PARTIAL}" ] || rm -rf "${PARTIAL:?}"
        [ -z "${SHA_FILE}" ] || rm -f "${SHA_FILE:?}"
        [ -z "${TAR_GZ}" ] || rm -f "${TAR_GZ:?}"
        [ -z "${KIT_DIR}" ] || rm -rf "${KIT_DIR:?}"
    fi
}
trap cleanup EXIT

log "staging ${NAME}"
# Plain mkdir, no -p: a run that loses the race to a second run fails here, before PARTIAL is
# recorded, so its cleanup can never remove the other run's staging folder.
mkdir "${KIT}.partial" || die "cannot create ${KIT}.partial"
PARTIAL="${KIT}.partial"
mkdir "${PARTIAL}/wheels"

# ---- 5. 휠: 임시 복사본에서 빌드, 또는 --wheel 로 받은 파일 복사 ----------------------------------
if [ -n "${WHEEL_OPT}" ]; then
    # 이름까지 보는 건 pyproject.toml 의 버전과 어긋나는 휠이 kit 에 실리는 일을 막는다: MANIFEST.env 의
    # wiki_mcp 는 pyproject 버전을 쓰므로, 다른 이름이면 휠과 매니페스트가 서로 다른 wiki-mcp 를 말하게 된다.
    [ -f "${WHEEL_OPT}" ] || die "no such wheel: ${WHEEL_OPT} (--wheel)"
    [ "$(basename "${WHEEL_OPT}")" = "${WHEEL_NAME}" ] \
        || die "--wheel must be ${WHEEL_NAME} (pyproject.toml says wiki-mcp ${VER}), got $(basename "${WHEEL_OPT}")"
    log "wheel from --wheel: ${WHEEL_OPT}"
    cp "${WHEEL_OPT}" "${PARTIAL}/wheels/${WHEEL_NAME}"
    cmp -s "${WHEEL_OPT}" "${PARTIAL}/wheels/${WHEEL_NAME}" || die "copy of ${WHEEL_OPT} does not match"
else
    # pip wheel 은 소스 디렉터리 안에 build/ 와 *.egg-info 를 남긴다. 저장소 트리를 더럽히지
    # 않게 pyproject.toml + README.md + src/ 만 임시 폴더로 복사해 거기서 빌드한다.
    BUILD_TMP="$(mktemp -d "${TMPDIR:-/tmp}/wikikit-build.XXXXXX")"
    mkdir "${BUILD_TMP}/wiki-mcp"
    cp "${SRC}/wiki-mcp/pyproject.toml" "${SRC}/wiki-mcp/README.md" "${BUILD_TMP}/wiki-mcp/"
    cp -R "${SRC}/wiki-mcp/src" "${BUILD_TMP}/wiki-mcp/src"
    find "${BUILD_TMP}" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
    # 저장소에 남은 낡은 *.egg-info 의 SOURCES.txt 가 새 파일(auth.py 등)을 빠뜨리게 할 수 있어 복사본에서 지운다.
    find "${BUILD_TMP}" -name '*.egg-info' -type d -prune -exec rm -rf {} + 2>/dev/null || true
    log "building ${WHEEL_NAME} (setuptools via ${PY_BIN})"
    ( cd "${BUILD_TMP}" && "${PY_BIN}" -m pip wheel --no-deps --no-build-isolation --quiet \
        --disable-pip-version-check -w "${PARTIAL}/wheels" ./wiki-mcp ) \
        || die "pip wheel failed on ./wiki-mcp"
    rm -rf "${BUILD_TMP:?}"
    BUILD_TMP=""
fi
[ -f "${PARTIAL}/wheels/${WHEEL_NAME}" ] || die "the build produced no ${WHEEL_NAME}"
n_wheels="$(find "${PARTIAL}/wheels" -type f | wc -l | tr -d ' ')"
[ "${n_wheels}" = "1" ] || die "the wheels/ folder holds ${n_wheels} files, expected exactly 1 (${WHEEL_NAME})"
# 꾸러미가 실어 가는 빌드가 http 서버와 Bearer 인증을 포함하는지 여기서 확인한다.
# 목록을 먼저 변수에 받는다: pipefail 아래 `unzip -l | grep -q` 는 grep 이 일찍 끝나면
# unzip 이 SIGPIPE(141)로 죽어 파일이 있어도 간헐적으로 실패한다.
wheel_list="$(unzip -l "${PARTIAL}/wheels/${WHEEL_NAME}")" || die "cannot list ${WHEEL_NAME}"
grep -q " wiki_mcp/auth\.py$" <<<"${wheel_list}" \
    || die "${WHEEL_NAME} does not contain wiki_mcp/auth.py"
grep -q " wiki_mcp/server\.py$" <<<"${wheel_list}" \
    || die "${WHEEL_NAME} does not contain wiki_mcp/server.py"

# ---- 6. 나머지 파일 + 문법 검사 -----------------------------------------------------------------
cp "${ADDON}/install-wiki-mcp.sh" "${PARTIAL}/install-wiki-mcp.sh"
chmod 755 "${PARTIAL}/install-wiki-mcp.sh"
cp "${ADDON}/README.md" "${PARTIAL}/README.md"
cp "${SRC}/run-wiki-mcp.sh" "${PARTIAL}/run-wiki-mcp.sh"
chmod 755 "${PARTIAL}/run-wiki-mcp.sh"
cp "${SRC}/load-env.sh" "${PARTIAL}/load-env.sh"
for s in install-wiki-mcp.sh run-wiki-mcp.sh load-env.sh; do
    bash -n "${PARTIAL}/${s}" || die "${s} does not parse (bash -n)"
done
stray="$(find "${PARTIAL}" -name '.DS_Store' -print)"
[ -z "${stray}" ] || die "a .DS_Store ended up in the kit"

GIT_COMMIT="$(git -C "${SRC}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
cat >"${PARTIAL}/MANIFEST.env" <<EOF
kit=wiki-mcp-kit
wiki_mcp=${VER}
wheel=wheels/${WHEEL_NAME}
mcp_port=8765
mcp_path=/mcp
label=dev.guardian.wiki-mcp
git_commit=${GIT_COMMIT}
built_utc=${BUILT}
EOF
# Every file, relative paths, sorted, SHA256SUMS itself excluded.
(cd "${PARTIAL}" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > SHA256SUMS)
(cd "${PARTIAL}" && shasum -a 256 -c SHA256SUMS >/dev/null) || die "SHA256SUMS does not match the staged files"
mv "${PARTIAL}" "${KIT}"
PARTIAL=""
KIT_DIR="${KIT}"
log "kit folder done: $(du -sh "${KIT}" | awk '{print $1}') in ${OUT}"

# ---- 7. 아카이브 ------------------------------------------------------------------------------
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
    echo "  shasum -a 256 -c ${NAME}.tar.gz.sha256 && tar xzf ${NAME}.tar.gz && cd ${NAME} && shasum -a 256 -c SHA256SUMS && ./install-wiki-mcp.sh --dry-run"
else
    log "done (--no-tar): the kit folder ${KIT} is complete with its SHA256SUMS"
fi
