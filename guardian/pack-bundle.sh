#!/usr/bin/env bash
# ==============================================================================
# merged bundle folder → files to copy to the target Mac (run on the build Mac)
#
# Writes next to the bundle (or into --out):
#   <name>.tar.xz          the bundle folder, xz-compressed. A clean Mac's /usr/bin/tar reads it (-xJf), so the
#                          target needs nothing installed. Bundle 20261026T070031Z: 10 GB -> 7.0 GB, xz -6 on 12 cores
#                          in 5.5 min, then 5 min to list it back single-threaded.
#   <name>.tar.xz.sha256   checked by install-llm-wiki.sh before it extracts anything
#   install-llm-wiki.sh    the one-step installer (sha256, free space, extract, install-all.sh, LM Studio first
#                          launch, wiki step again)
# Copy all three into one folder on the target Mac and run  bash install-llm-wiki.sh --dry-run  there.
# The archive is listed back with /usr/bin/tar before the .sha256 is written, so a damaged archive never gets one.
# An existing archive or .sha256 is never replaced: move it away first. install-llm-wiki.sh is copied every time
# (it works with any bundle archive), so the folder always has the current one.
#
# Usage:  guardian/pack-bundle.sh BUNDLE_DIR [--out=DIR] [--level=N]
#   --out=DIR    output folder (default: the bundle's parent)
#   --level=N    xz preset 0-9 (default 6; higher saves little on the models and costs much more time)
# Called by build-merged-bundle.sh as its last step.
# ==============================================================================

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE=""
OUT=""
LEVEL=6

for arg in "$@"; do
    case "${arg}" in
        --out=*) OUT="${arg#--out=}" ;;
        --level=*) LEVEL="${arg#--level=}" ;;
        -h|--help) sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: ${arg}" >&2; exit 2 ;;
        *) BUNDLE="${arg}" ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

[ -n "${BUNDLE}" ] || die "usage: $0 BUNDLE_DIR [--out=DIR] [--level=N]"
[ -f "${BUNDLE}/MANIFEST.env" ] && [ -x "${BUNDLE}/install-all.sh" ] \
    || die "${BUNDLE} is not a merged bundle (no MANIFEST.env or install-all.sh)"
case "${LEVEL}" in [0-9]) ;; *) die "--level must be 0-9" ;; esac
BUNDLE="$(cd "${BUNDLE}" && pwd)"
NAME="$(basename "${BUNDLE}")"
PARENT="$(dirname "${BUNDLE}")"
OUT="${OUT:-${PARENT}}"
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
ARCHIVE="${OUT}/${NAME}.tar.xz"
PARTIAL="${ARCHIVE}.partial"
INSTALLER="${HERE}/install-llm-wiki.sh"
[ -f "${INSTALLER}" ] || die "${INSTALLER} is missing"
for f in "${ARCHIVE}" "${ARCHIVE}.sha256" "${PARTIAL}"; do
    if [ -e "${f}" ]; then die "${f} already exists"; fi
done

log "compress ${NAME} (xz -${LEVEL})"
SECONDS=0
# Homebrew's xz uses every core; /usr/bin/tar's built-in xz uses one. Both write a stream /usr/bin/tar can read.
if command -v xz >/dev/null 2>&1; then
    COPYFILE_DISABLE=1 tar -C "${PARENT}" -cf - "${NAME}" | xz -T0 "-${LEVEL}" >"${PARTIAL}"
else
    COPYFILE_DISABLE=1 XZ_OPT="-${LEVEL}" tar -C "${PARENT}" -cJf "${PARTIAL}" "${NAME}"
fi
echo "    $(du -sh "${BUNDLE}" | awk '{print $1}') -> $(ls -lh "${PARTIAL}" | awk '{print $5}') in ${SECONDS}s"

log "list it back with /usr/bin/tar (the target Mac's reader)"
SECONDS=0
want="$(cd "${PARENT}" && find "${NAME}" | wc -l | tr -d ' ')"
got="$(/usr/bin/tar -tJf "${PARTIAL}" | wc -l | tr -d ' ')"
[ "${got}" = "${want}" ] || die "the archive lists ${got} entries, the folder has ${want} (left as ${PARTIAL})"
echo "    ${got} entries in ${SECONDS}s"

mv "${PARTIAL}" "${ARCHIVE}"
(cd "${OUT}" && shasum -a 256 "${NAME}.tar.xz" >"${NAME}.tar.xz.sha256")
cp "${INSTALLER}" "${OUT}/install-llm-wiki.sh"
chmod 755 "${OUT}/install-llm-wiki.sh"

log "done: copy these three files into one folder on the target Mac"
(cd "${OUT}" && ls -lh "${NAME}.tar.xz" "${NAME}.tar.xz.sha256" install-llm-wiki.sh | awk '{print "    " $5 "  " $NF}')
echo "    installer sha256 $(shasum -a 256 "${OUT}/install-llm-wiki.sh" | awk '{print $1}')"
echo "Then on the target Mac:  bash install-llm-wiki.sh --dry-run  &&  bash install-llm-wiki.sh"
