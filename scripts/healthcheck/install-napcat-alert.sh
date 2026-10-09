#!/usr/bin/env bash
# install-napcat-alert.sh — install the NapCat login monitor on bt-he1k.
#
# Idempotent: safe to re-run. Backs up anything it replaces and prints the
# exact rollback. Does NOT set ADMIN_QQ (that is personal data) — put it in
# /etc/napcat-alert.env (mode 600) before or after installing.
#
# Usage: install-napcat-alert.sh [path-to-check-napcat-login.sh]
#
# Exit codes: 0 = installed, 1 = prerequisite missing.

set -euo pipefail

SRC="${1:-/tmp/check-napcat-login.sh}"
DEST_BIN=/usr/local/bin/check-napcat-login.sh
ENV_FILE=/etc/napcat-alert.env
STATE_DIR=/var/lib/napcat-alert
LOG_FILE=/var/log/napcat-alert.log
CRON_FILE=/etc/cron.d/napcat-alert
LOCK_FILE=/var/lock/napcat-alert.lock
BACKUP_DIR="/root/backups/napcat-alert-$(date +%Y%m%d-%H%M%S)"

[ -f "$SRC" ] || { echo "ERROR: source script not found: $SRC" >&2; exit 1; }

echo "=== backup ==="
mkdir -p "$BACKUP_DIR"
for f in "$DEST_BIN" "$ENV_FILE" "$CRON_FILE"; do
    if [ -f "$f" ]; then
        cp -a "$f" "$BACKUP_DIR/"
        echo "  backed up: $f"
    fi
done
echo "  backup dir: $BACKUP_DIR"

echo
echo "=== install binary ==="
install -m 0755 "$SRC" "$DEST_BIN"
echo "  $DEST_BIN"

echo
echo "=== state dir ==="
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
touch "$LOCK_FILE"
chmod 600 "$LOCK_FILE"
echo "  $STATE_DIR (700), $LOCK_FILE"

echo
echo "=== env file (ADMIN_QQ intentionally not set by this script) ==="
if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" <<'ENVEOF'
# napcat drop-alert settings.
# ADMIN_QQ is personal data: this file must stay mode 600 and out of the repo.
ADMIN_QQ=
# Minutes to stay silent after one alert about the same fault.
SILENCE_MINUTES=30
# Consecutive bad probes required before alerting (anti-flap).
CONFIRM_FAILURES=2
# Where the user goes to re-scan.
WEBUI_HELP=http://127.0.0.1:6100/webui/
# Dead-man's switch: one "still alive" message per day at/after this hour.
# Leave empty to disable (default). Example: 21 = a nightly heartbeat.
HEARTBEAT_HOUR=
ENVEOF
    chmod 600 "$ENV_FILE"
    echo "  created $ENV_FILE — ADMIN_QQ is EMPTY, fill it in"
else
    chmod 600 "$ENV_FILE"
    echo "  kept existing $ENV_FILE (mode forced to 600)"
fi
touch "$LOG_FILE"
chmod 640 "$LOG_FILE"

echo
echo "=== cron ==="
# Every 5 minutes, not every minute: at */1 the script wrote 2 log lines per
# minute (~2900/day) and filled /var/log/cron with 29666 lines that were all
# its own. Detection latency of 5 min is fine for a "the bot went quiet" alert.
# (Changed 2026-10-09; the *script* now self-limits to NAPCAT_ALERT_RUN_TIMEOUT.)
cat > "$CRON_FILE" <<CRONEOF
# NapCat login monitor — alerts via napcat1 when napcat2 drops.
# See docs/runbooks/napcat-drop-alert.md ; script: $DEST_BIN
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
*/5 * * * * root $DEST_BIN >> $LOG_FILE 2>&1
CRONEOF
chmod 0644 "$CRON_FILE"
echo "  $CRON_FILE (every 5 minutes)"

echo
echo "=== self test (dry run, sends nothing) ==="
if ADMIN_QQ_DUMMY=1 "$DEST_BIN" --simulate up --dry-run; then
    echo "  script runs OK"
else
    echo "  WARNING: script exited non-zero on a dry run (ADMIN_QQ may be unset yet)"
fi

cat <<ROLLBACK

=== rollback ===
rm -f $DEST_BIN $CRON_FILE
rm -rf $STATE_DIR
# restore prior versions (if any) from:
#   $BACKUP_DIR
# e.g.  cp -a $BACKUP_DIR/check-napcat-login.sh $DEST_BIN
ROLLBACK
