#!/usr/bin/env bash
# final-state.sh - after the tidy-up: what the box looks like now.
set -uo pipefail
S() { printf '\n########## %s ##########\n' "$1"; }

S 'MEMORY / DISK'
free -m | sed 's/^/  /'
df -h / | tail -1 | sed 's/^/  /'
journalctl --disk-usage 2>/dev/null | sed 's/^/  /'

S 'CONTAINERS'
docker ps --format '  {{.Names}} | {{.Status}}' 2>/dev/null
docker stats --no-stream --format '  {{.Name}}  {{.MemUsage}}' 2>/dev/null

S 'NAP CAT QQ LOGIN STATE (both need a fresh QR scan)'
for c in napcat1 napcat2; do
    echo "  --- $c ---"
    docker logs --tail 60 "$c" 2>&1 | grep -E '二维码|登录态|快速登录|登录成功|已登录' | tail -3 | cut -c1-120 | sed 's/^/    /'
done

S 'ASTRBOT ADAPTERS'
docker logs --since 30m astrbot 2>&1 | grep -E '适配器已连接|Loading IM platform adapter' | tail -6 | cut -c1-130 | sed 's/^/  /'

S 'SERVICES + CUSTOM UNITS'
systemctl --failed --no-pager --no-legend 2>/dev/null | sed 's/^/  FAILED /'
for s in sshd bt nginx docker cloudflared crond; do
    printf '  %-12s %s\n' "$s" "$(systemctl is-active $s 2>/dev/null)"
done

S 'EXPOSED PORTS'
ss -lntp 2>/dev/null | awk 'NR>1 && $4 !~ /^127\.|^\[::1\]/ {print "  "$4"  "substr($0, index($0,"users:"))}' | cut -c1-110

S 'CRON'
grep -H '^\*/' /etc/cron.d/* 2>/dev/null | cut -c1-120 | sed 's/^/  /'

S 'NGINX VHOSTS (live only)'
ls -1 /www/server/panel/vhost/nginx/ | sed 's/^/  /'

S 'PLACEHOLDER HEALTH CHECK (are we leaking real values into tracked files?)'
cd /tmp && rm -rf _redactcheck && mkdir _redactcheck && cd _redactcheck
tar --exclude='./secrets' --exclude='./logs' --exclude='./tmp' --exclude='./.git' \
    -cf - -C /root/cloud-server-workspace . 2>/dev/null | tar -xf - 2>/dev/null || true
echo '  (skipped - workspace files are synced from the Windows side)'

echo
echo 'final-state complete'
