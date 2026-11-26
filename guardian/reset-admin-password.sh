#!/usr/bin/env bash
# ==============================================================================
# Reset the Open WebUI admin password of a guardian install, offline. Accounts, chats and files are kept.
#
# Run it on the Mac itself, in a terminal (the password is read from the keyboard and never echoed or logged).
# It ships at the root of the merged bundle, next to install-all.sh; run it from the extracted bundle folder.
# Over ssh use -t, and quote the path so ~ is the remote home:
#   ssh -t site-mac 'bash ~/llm-wiki-bundle-YYYYMMDDTHHMMSSZ-macos-arm64/reset-admin-password.sh'
#
# What it does:
#   1. stops the Open WebUI LaunchAgent so nothing writes the DB meanwhile
#   2. backs up webui.db with its -wal/-shm files to webui.db.bak-<time>
#   3. stores a bcrypt hash of the new password and a new session_stamp, as Open WebUI does on a password change,
#      so every browser that was logged in has to log in again
#   4. starts Open WebUI and waits for /health
#
# Usage:  reset-admin-password.sh [options]
#   --email=ADDR     account to reset (default: the only admin; required when there are several)
#   --prefix=DIR     guardian tool directory (default ~/.guardian-llm)
#   --port=N         Open WebUI port for the health check (default 8080)
# ==============================================================================

set -euo pipefail

PREFIX="${HOME}/.guardian-llm"
PORT=8080
EMAIL=""
WEBUI_LABEL="dev.guardian.openwebui"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

for arg in "$@"; do
    case "${arg}" in
        --email=*) EMAIL="${arg#--email=}" ;;
        --prefix=*) PREFIX="${arg#--prefix=}" ;;
        --port=*) PORT="${arg#--port=}" ;;
        -h|--help) sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: ${arg}" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
note() { echo "    $*"; }

PY="${PREFIX}/venv/bin/python"
DATA="${PREFIX}/openwebui-data"
DB="${DATA}/webui.db"
PLIST="${HOME}/Library/LaunchAgents/${WEBUI_LABEL}.plist"
DOMAIN="gui/$(id -u)"

[ -t 0 ] || die "run this in a terminal (over ssh: ssh -t ...); the password is typed, not piped"
[ -x "${PY}" ] || die "no guardian venv at ${PREFIX}/venv"
[ -f "${DB}" ] || die "no Open WebUI DB at ${DB}"

# Read-only lookup first, so a wrong --email fails before the service is touched.
TARGET="$("${PY}" - "${DB}" "${EMAIL}" <<'PY'
import sqlite3, sys
db, email = sys.argv[1], sys.argv[2]
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
if email:
    rows = c.execute("select u.id, u.email, u.role from user u join auth a on a.id = u.id where lower(u.email) = lower(?)", (email,)).fetchall()
else:
    rows = c.execute("select u.id, u.email, u.role from user u join auth a on a.id = u.id where u.role = 'admin'").fetchall()
if len(rows) != 1:
    sys.exit(f"error: {len(rows)} matching account(s); pass --email=ADDR" if rows or not email else f"error: no account {email}")
print("\t".join(rows[0]))
PY
)"
USER_ID="$(printf '%s' "${TARGET}" | cut -f1)"
log "account: $(printf '%s' "${TARGET}" | cut -f2) ($(printf '%s' "${TARGET}" | cut -f3))"

# ---- 1. stop -----------------------------------------------------------------------------
log "stopping Open WebUI"
launchctl bootout "${DOMAIN}/${WEBUI_LABEL}" 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl print "${DOMAIN}/${WEBUI_LABEL}" >/dev/null 2>&1 || break
    sleep 1
done
if pgrep -f "${PREFIX}/venv/bin/open-webui" >/dev/null; then
    die "Open WebUI is still running (started by hand?); stop it and run this again"
fi

# From here on, bring the service back whatever happens.
restart() {
    [ -f "${PLIST}" ] && launchctl bootstrap "${DOMAIN}" "${PLIST}" 2>/dev/null || true
}
trap restart EXIT

# ---- 2. backup ---------------------------------------------------------------------------
log "backup: ${DB}.bak-${STAMP}"
for ext in "" -wal -shm; do
    [ -f "${DB}${ext}" ] && cp -p "${DB}${ext}" "${DB}.bak-${STAMP}${ext}"
done
chmod 600 "${DB}.bak-${STAMP}"*

# ---- 3. new password ---------------------------------------------------------------------
"${PY}" - "${DB}" "${USER_ID}" <<'PY'
import getpass, sqlite3, sys, uuid
import bcrypt

db, user_id = sys.argv[1], sys.argv[2]
for _ in range(3):
    pw = getpass.getpass("new password: ")
    if len(pw) < 8:
        print("    at least 8 characters")
        continue
    if len(pw.encode("utf-8")) > 72:
        print("    at most 72 bytes (bcrypt ignores the rest)")
        continue
    if pw != getpass.getpass("again: "):
        print("    the two entries differ")
        continue
    break
else:
    sys.exit("error: password not changed")

hashed = bcrypt.hashpw(pw.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")
c = sqlite3.connect(db)
with c:
    n = c.execute("update auth set password = ?, session_stamp = ? where id = ?",
                  (hashed, str(uuid.uuid4()), user_id)).rowcount
if n != 1:
    sys.exit(f"error: {n} auth rows updated")
stored = c.execute("select password from auth where id = ?", (user_id,)).fetchone()[0]
if not bcrypt.checkpw(pw.encode("utf-8"), stored.encode("utf-8")):
    sys.exit("error: stored hash does not verify")
print("    password changed; existing logins are signed out")
PY

# ---- 4. start ----------------------------------------------------------------------------
trap - EXIT
log "starting Open WebUI"
restart
for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null; then
        note "Open WebUI answers on 127.0.0.1:${PORT}"
        log "done (backup kept at ${DB}.bak-${STAMP})"
        exit 0
    fi
    sleep 2
done
die "Open WebUI did not answer in 120s; see ${PREFIX}/logs/openwebui.log"
