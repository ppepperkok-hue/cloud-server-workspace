#!/usr/bin/env bash
# os-upgrade.sh - apply pending OS package updates detached from the SSH session.
#
# Why detached: a kernel/glibc/openssh update can restart services and drop the SSH
# session mid-transaction. Running under a transient systemd unit keeps dnf alive
# even if the session dies, and always leaves a log behind.
#
# Usage:   bash os-upgrade.sh [logfile]
# Status:  tail the logfile; a trailing "=== DONE rc=N ===" means it finished.
#          The logfile path is also recorded in /root/.dsh-os-upgrade-last.
# Rollback: dnf history list          # find the transaction id of the upgrade
#           dnf history undo <id>     # revert it
#           reboot                    # if a new kernel was installed
# Verify:  rpm -q kernel ; uname -r ; dnf -q check-update | wc -l

set -uo pipefail

LOG="${1:-/root/dnf-upgrade-$(date +%Y%m%d-%H%M%S).log}"
RUNNER=/root/.dsh-os-upgrade.sh
UNIT=dsh-os-upgrade

if pgrep -f 'dnf -y upgrade' >/dev/null 2>&1; then
    echo "FATAL: an upgrade is already running:" >&2
    pgrep -af 'dnf -y upgrade' >&2
    exit 1
fi

echo "pending before: $(dnf -q check-update 2>/dev/null | grep -cE '^[A-Za-z0-9._+-]+\.')"
echo "kernel running: $(uname -r)"
echo "disk before:    $(df -h / | tail -1)"

cat > "$RUNNER" <<'EOS'
#!/bin/bash
LOG="$1"
dnf -y upgrade > "$LOG" 2>&1
rc=$?
echo "EXIT=$rc" >> "$LOG"
echo "=== DONE rc=$rc ===" >> "$LOG"
EOS
chmod 700 "$RUNNER"
: > "$LOG"
printf '%s' "$LOG" > /root/.dsh-os-upgrade-last

systemctl reset-failed "$UNIT" 2>/dev/null || true
systemd-run --unit="$UNIT" --collect /bin/bash "$RUNNER" "$LOG" >/dev/null 2>&1
echo "started detached unit '${UNIT}', logfile=$LOG"

sleep 10
echo "unit state: $(systemctl is-active "$UNIT" 2>&1)"
echo '--- log head ---'
head -6 "$LOG" 2>/dev/null
echo '--- log tail ---'
tail -6 "$LOG" 2>/dev/null
echo
echo "follow with:  tail -f $LOG    (a trailing '=== DONE rc=N ===' marks completion)"
echo "rollback:     dnf history undo <upgrade-id>, then reboot if a new kernel landed"
