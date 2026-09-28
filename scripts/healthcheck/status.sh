#!/usr/bin/env bash
# status.sh - read-only health snapshot of bt-he1k (the whole stack as of 2026-09-28).
set -uo pipefail
section() { printf '\n########## %s ##########\n' "$1"; }

section HOST
echo "hostname : $(hostname)"
echo "kernel   : $(uname -r)"
echo "uptime   : $(uptime -p)   (since $(uptime -s))"
echo "load     : $(cat /proc/loadavg | cut -d' ' -f1-3)"
echo "time     : $(date '+%F %T %Z')"
echo "failed   : $(systemctl --failed --no-pager --no-legend 2>/dev/null | wc -l) units"

section RESOURCES
echo '--- cpu ---'
echo "  cores: $(nproc)   model: $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ //')"
echo '--- memory ---'
free -m | sed 's/^/  /'
echo '--- disk ---'
df -hT | grep -vE 'tmpfs|devtmpfs' | sed 's/^/  /'
echo "--- big dirs ---"
du -sh /www /www/server/panel /www/server/nginx /opt/astrbot /opt/sillytavern /var/lib/docker /var/log /root 2>/dev/null | sed 's/^/  /'
echo "--- backups ---"
du -sh /root/backups 2>/dev/null | sed 's/^/  /'

section SERVICES
for s in sshd bt nginx docker containerd postfix crond chronyd; do
    printf '  %-12s active=%-10s enabled=%s\n' "$s" \
        "$(systemctl is-active $s 2>&1 | head -1)" \
        "$(systemctl is-enabled $s 2>&1 | head -1)"
done

section CONTAINERS
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1 | sed 's/^/  /'
echo '--- restarts / health / oom ---'
for c in astrbot napcat1 napcat2 sillytavern; do
    printf '  %-11s status=%-9s health=%-9s restarts=%s oom=%s\n' "$c" \
        "$(docker inspect -f '{{.State.Status}}' $c 2>&1)" \
        "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' $c 2>&1)" \
        "$(docker inspect -f '{{.RestartCount}}' $c 2>&1)" \
        "$(docker inspect -f '{{.State.OOMKilled}}' $c 2>&1)"
done
echo '--- live usage ---'
docker stats --no-stream --format '  {{.Name}}  cpu={{.CPUPerc}}  mem={{.MemUsage}}' 2>&1
echo '--- images ---'
docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' 2>&1

section LISTENERS
ss -lntp 2>/dev/null | tail -n +2 | sed 's/^/  /'

section ASTRBOT
echo "  version   : $(docker logs astrbot 2>&1 | grep -aoE 'AstrBot v[0-9.]+' | head -1)"
echo "  plugins   : $(docker logs astrbot 2>&1 | grep -acE 'Plugin [a-z_0-9]+ \([^)]*\) by .*:') loaded / $(docker logs astrbot 2>&1 | grep -ac 'Failed to import plugin') failed"
echo "  adapters  : $(docker logs astrbot 2>&1 | grep -ac 'adapter:107') connected / $(docker logs astrbot 2>&1 | grep -ac '被关闭\|已断开') disconnected"
echo "  webui     : $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:6185/ 2>/dev/null)"
echo '  --- recent errors ---'
docker logs --since 60m astrbot 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -aiE '\[ERRO\]|traceback|error' | tail -6 | cut -c1-160 | sed 's/^/    /' || echo '    (none in the last hour)'

section NAPCAT
for i in 1 2; do
    uin=$(ls /opt/astrbot/napcat$i/config/ 2>/dev/null | grep -oE 'napcat_[0-9]+\.json' | grep -oE '[0-9]+' | head -1)
    ws=$(grep -aoE '"url": *"[^"]*"' /opt/astrbot/napcat$i/config/onebot11.json 2>/dev/null | head -1)
    printf '  napcat%s  account=%s  ws=%s  webui=%s\n' "$i" "${uin:-none}" "${ws:-none}" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 http://127.0.0.1:$((6098+i))/webui/ 2>/dev/null)"
done
echo "  crash dumps: $(docker logs napcat1 2>&1 | grep -ac 'NativeCrashHandler') (cosmetic, present since first boot)"

section SILLYTAVERN
echo "  version : $(docker exec sillytavern sh -c 'node -e "console.log(require(\"/home/node/app/package.json\").version)"' 2>/dev/null || echo '?')"
echo "  http    : $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:8000/ 2>/dev/null)"
echo "  title   : $(curl -s --max-time 8 http://127.0.0.1:8000/ 2>/dev/null | grep -oE '<title>[^<]*</title>' | head -1)"
echo "  data    : $(du -sh /opt/sillytavern/data 2>/dev/null | cut -f1)  characters=$(ls -1 /opt/sillytavern/data/default-user/characters 2>/dev/null | wc -l)  chats=$(ls -1 /opt/sillytavern/data/default-user/chats 2>/dev/null | wc -l)"
echo "  ext     : $(ls -1 /opt/sillytavern/extensions 2>/dev/null | tr '\n' ' ')"
echo '  --- recent errors ---'
docker logs --since 60m sillytavern 2>&1 | grep -aiE 'error|blocked|exception' | tail -5 | cut -c1-150 | sed 's/^/    /' || echo '    (none in the last hour)'

section BT_PANEL
echo "  version : $(grep -m1 -oE "g\.version *= *'[^']+'" /www/server/panel/class/common.py 2>/dev/null)"
echo "  service : $(/etc/init.d/bt status 2>&1 | head -2 | tr '\n' ' ')"
echo "  ssl     : $( [ -f /www/server/panel/data/ssl.pl ] && echo on || echo off )   limitip: $( [ -s /www/server/panel/data/limitip.conf ] && echo set || echo none )"
echo "  http    : $(curl -sk -A 'Mozilla/5.0' -o /dev/null -w '%{http_code}' --max-time 8 https://127.0.0.1:8888/ 2>/dev/null) (no-UA+path is 404 by design)"

section SECURITY_POSTURE
echo "  selinux     : $(getenforce 2>/dev/null)"
echo "  firewalld   : active=$(systemctl is-active firewalld 2>&1) enabled=$(systemctl is-enabled firewalld 2>&1)"
echo "  fail2ban    : active=$(systemctl is-active fail2ban 2>&1)"
echo "  sshd        : $(sshd -T 2>/dev/null | grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|port)' | tr '\n' ' ')"
echo '  --- yunjing iptables chain ---'
iptables -L YJ-FIREWALL-INPUT -n 2>/dev/null | tail -n +2 | sed 's/^/    /'
echo '  --- recent accepted ssh ---'
grep -a 'Accepted' /var/log/secure 2>/dev/null | tail -2 | cut -c1-140 | sed 's/^/    /'
echo '  --- failed ssh attempts (last 24h) ---'
grep -ac 'Failed password\|Invalid user' /var/log/secure 2>/dev/null | sed 's/^/    /'

section PATCHES
echo "  running kernel : $(uname -r)"
echo "  installed      : $(rpm -q kernel 2>/dev/null | tr '\n' ' ')"
echo "  pending pkgs   : $(dnf -q check-update 2>/dev/null | grep -cE '^[A-Za-z0-9._+-]+\.')"
echo "  reboot needed  : $(dnf needs-restarting -r >/dev/null 2>&1 && echo no || echo YES)"

section STATUS_DONE
echo 'status snapshot complete'
