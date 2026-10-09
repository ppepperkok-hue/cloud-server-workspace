#!/usr/bin/env bash
# tidy-server.sh - put bt-he1k back in order after a week of ad-hoc work.
#
# Guiding rule: archive, do not destroy, anything that is a unique snapshot.
# The Windows originals of both migrations are gone, so the two tarballs in /root
# are the only pre-migration snapshots left - they get MOVED, not deleted.
#
# How the agent runs it:
#   scp scripts/maintenance/tidy-server.sh root@<TEST_HOST_IP>:/root/tidy-server.sh
#   bash /root/tidy-server.sh --dry-run     # always dry-run first
#   bash /root/tidy-server.sh
#
# First run 2026-10-09 18:54: disk 20G/50% -> 19G/47%, journal 128.7M -> 16.0M,
# /var/log/cron 11.8M -> 0 (all of it was the once-a-minute login monitor).
# Idempotent: every step is existence-guarded, so a second run is a no-op.
#
# Usage: tidy-server.sh [--dry-run]
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1
run() { if [ "$DRY" = 1 ]; then echo "  [dry] $*"; else eval "$@"; fi; }
S() { printf '\n########## %s ##########\n' "$1"; }
STAMP=$(date +%Y%m%d-%H%M%S)
SNAP=/root/backups/migration-snapshots

S '0. BEFORE'
free -m | sed 's/^/  /'
df -h / | tail -1 | sed 's/^/  /'

S '1. migration tarballs -> archive (the Windows originals are gone; these are the last snapshots)'
run "mkdir -p '$SNAP'"
for f in /root/astrbot-data.tar.gz /root/sillytavern-payload.tar.gz; do
    [ -f "$f" ] || continue
    printf '  move %-38s %s -> %s\n' "$(basename $f)" "$(du -h $f | cut -f1)" "$SNAP"
    run "mv '$f' '$SNAP/'"
done
ls -la "$SNAP" 2>/dev/null | sed 's/^/    /'

S '2. one-off scripts and helper files from finished work (all tracked in the repo now)'
dead=(
    /root/setup-cloudflared-tunnel.sh /root/setup-st-https.sh
    /root/switch-port80-to-sillytavern.sh /root/st-set-basicauth.sh
    /root/st-patch-config.py
    /root/.dsh-astrbot-pull.sh /root/.dsh-napcat-pull.sh /root/.dsh-nginx-install.sh
    /root/.dsh-os-upgrade.sh /root/.dsh-st-pull.sh /root/.dsh-st-pull2.sh
    /root/.dsh-astrbot-image /root/.dsh-astrbot-pull-last
    /root/.dsh-napcat-image /root/.dsh-napcat-pull-last
    /root/.dsh-nginx-install-last /root/.dsh-os-upgrade-last
    /root/.dsh-st-image /root/.dsh-st-pull-last
    /root/.dsh-st-pull-last
    /root/tidy-server.sh
    /root/cf-tunnel.json
)
seen=""
for f in "${dead[@]}"; do
    case " $seen " in *" $f "*) continue ;; esac
    seen="$seen $f"
    [ -e "$f" ] || continue
    printf '  remove %s\n' "$f"
    run "rm -f '$f'"
done

S '3. one-shot install / pull logs'
for f in /root/nginx-install-*.log /root/dnf-upgrade-*.log /root/astrbot-pull-*.log \
         /root/napcat-pull-*.log /root/st-pull-*.log /root/st-pull2-*.log; do
    case " $seen " in *" $f "*) continue ;; esac
    seen="$seen $f"
    [ -f "$f" ] || continue
    printf '  remove %-46s %s\n' "$(basename $f)" "$(du -h "$f" | cut -f1)"
    run "rm -f '$f'"
done

S '4. nginx vhost dir - retire the inert files (they never match *.conf, so they are dead weight)'
ARCH=/root/backups/nginx-retired-$STAMP
run "mkdir -p '$ARCH'"
for f in /www/server/panel/vhost/nginx/*.disabled-* \
         /www/server/panel/vhost/nginx/*.disabled-by-agent \
         /www/server/panel/vhost/nginx/*.bak-* ; do
    [ -e "$f" ] || continue
    case " $seen " in *" $f "*) continue ;; esac
    seen="$seen $f"
    printf '  move %s\n' "$(basename "$f")"
    run "mv '$f' '$ARCH/'"
done
echo '  --- what remains (all live) ---'
ls -1 /www/server/panel/vhost/nginx/ | sed 's/^/    /'

S '5. docker - drop the hello-world test images'
run "docker rmi -f hello-world:latest m.daocloud.io/docker.io/library/hello-world:latest >/dev/null 2>&1 || true"
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' | sed 's/^/  /'

S '6. journal - vacuum to 50 MB'
journalctl --disk-usage 2>/dev/null | sed 's/^/  before: /'
run 'journalctl --vacuum-size=50M >/dev/null 2>&1 || true'
journalctl --disk-usage 2>/dev/null | sed 's/^/  after : /'

S '7. the log spam: a login monitor firing every minute'
echo '  --- /var/log sizes before ---'
du -h /var/log/cron /var/log/napcat-alert.log 2>/dev/null | sed 's/^/    /'
if [ -f /etc/cron.d/napcat-alert ] && grep -q '^\*/1' /etc/cron.d/napcat-alert; then
    printf '  change */1 -> */5 in /etc/cron.d/napcat-alert (was 2 log lines per minute, ~2900/day)\n'
    run "cp -a /etc/cron.d/napcat-alert /root/backups/napcat-alert.cron.bak-$STAMP"
    run "sed -i 's#^\\*/1 \\* \\* \\* \\*#*/5 * * * *#' /etc/cron.d/napcat-alert"
    run 'systemctl reload crond 2>/dev/null || service crond reload 2>/dev/null || true'
    grep -E '^\*/' /etc/cron.d/napcat-alert | sed 's/^/    now: /'
else
    echo '  (schedule already longer than 1 minute, or the cron is gone)'
fi
printf '  truncate /var/log/cron and /var/log/napcat-alert.log\n'
run ': > /var/log/cron'
run ': > /var/log/napcat-alert.log'
du -h /var/log/cron /var/log/napcat-alert.log 2>/dev/null | sed 's/^/    after: /'

S '8. AFTER (files)'
df -h / | tail -1 | sed 's/^/  /'
echo '  --- /root now ---'
ls -la --time-style=+%F /root | grep -vE '^total| \.$| \.\.$' | awk '{printf "  %-12s %s\n", $5, $NF}'

echo
echo "tidy-server complete (dry=$DRY)"
