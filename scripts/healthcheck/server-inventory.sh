#!/usr/bin/env bash
# server-inventory.sh - read-only host inventory / reconnaissance.
# Usage:  ssh <host> "bash -s" < server-inventory.sh
#         (on Windows: powershell -File scripts/utils/ssh-bt-he1k.ps1 -ScriptPath <this file>)
#         Keep this file pure ASCII: it is piped over ssh stdin on Windows.
# Safety: READ-ONLY. No package installs, no service restarts, no config writes.
# Exit code: 0 always (best-effort; missing tools are skipped, not fatal).

set -u
export LC_ALL=C

section() { printf '\n########## %s ##########\n' "$1"; }

section SYSTEM
echo "hostname:       $(hostname 2>/dev/null)"
echo "fqdn:           $(hostname -f 2>/dev/null)"
echo "os:             $(grep -hE '^(NAME|VERSION)=' /etc/os-release 2>/dev/null | tr '\n' ' ')"
echo "kernel:         $(uname -r 2>/dev/null)"
echo "arch:           $(uname -m 2>/dev/null)"
echo "boot_time:      $(uptime -s 2>/dev/null)"
echo "uptime:         $(uptime -p 2>/dev/null)"
echo "load:           $(cat /proc/loadavg 2>/dev/null)"
echo "timezone:       $(timedatectl show -p Timezone --value 2>/dev/null)"
echo "ntp_sync:       $(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
echo "now:            $(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
echo "virtualization: $(systemd-detect-virt 2>/dev/null)"

section CPU
lscpu 2>/dev/null | grep -E '^(Architecture|Model name|CPU\(s\)|Thread|Core|Socket|Virtualization|Hypervisor|NUMA)' | sed 's/  */ /g'
echo "nproc:          $(nproc 2>/dev/null)"

section MEMORY
free -m 2>/dev/null
echo "--- swap devices ---"
swapon --show 2>/dev/null

section DISK
df -hT 2>/dev/null
echo "--- inodes ---"
df -i 2>/dev/null
echo "--- block devices ---"
lsblk 2>/dev/null
echo "--- big dirs ---"
du -sh /var/log /var/lib /usr/local /root /opt /home 2>/dev/null
echo "--- /www breakdown (top 12) ---"
du -sh /www 2>/dev/null
du -sh /www/server/* 2>/dev/null | sort -h | tail -12

section NETWORK
ip -4 -o addr show 2>/dev/null
echo "--- routes ---"
ip route 2>/dev/null
echo "--- dns ---"
grep -hvE '^\s*(#|$)' /etc/resolv.conf 2>/dev/null

section SECURITY
echo "selinux:        $(getenforce 2>/dev/null || echo n/a)"
echo "firewalld:      active=$(systemctl is-active firewalld 2>/dev/null) enabled=$(systemctl is-enabled firewalld 2>/dev/null)"
echo "ufw:            active=$(systemctl is-active ufw 2>/dev/null)"
echo "fail2ban:       active=$(systemctl is-active fail2ban 2>/dev/null)"
echo "--- iptables filter rules ---"
iptables -S 2>/dev/null | head -40
echo "--- nftables ruleset (head) ---"
nft list ruleset 2>/dev/null | head -20

section LISTENING
ss -lntup 2>/dev/null

section SERVICES_RUNNING
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | awk '{print $1}' | sort

section SERVICES_ENABLED
systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend 2>/dev/null | awk '{print $1}' | sort

section SERVICES_FAILED
systemctl --failed --no-pager --no-legend 2>/dev/null

section SSH
sshd -T 2>/dev/null | grep -E '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|kbdinteractiveauthentication|challengeresponseauthentication|maxauthtries|allowusers|denyusers|usepam)'
echo "--- root .ssh ---"
ls -la /root/.ssh/ 2>/dev/null
echo "authorized_keys lines: $(grep -c . /root/.ssh/authorized_keys 2>/dev/null || echo 0)"

section BT_PANEL
echo "install_dir:    $( [ -d /www/server/panel ] && echo present || echo absent )"
echo "port:           $(cat /www/server/panel/data/port.pl 2>/dev/null)"
echo "entry:          $(cat /www/server/panel/data/admin_path.pl 2>/dev/null)"
echo "ssl_enabled:    $( [ -f /www/server/panel/data/ssl.pl ] && echo yes || echo no )"
echo "version:        $(grep -m1 -oE "g\.version *= *'[^']+'" /www/server/panel/class/common.py 2>/dev/null)"
echo "--- bt service ---"
/etc/init.d/bt status 2>&1 | head -5
echo "--- /www/server dirs ---"
ls -1 /www/server/ 2>/dev/null
echo "--- /www/wwwroot ---"
ls -la /www/wwwroot/ 2>/dev/null
echo "--- nginx ---"
/www/server/nginx/sbin/nginx -v 2>&1
echo "--- mysql/mariadb ---"
/www/server/mysql/bin/mysqld --version 2>&1 | head -1
echo "--- php versions ---"
ls -1d /www/server/php/*/ 2>/dev/null
echo "--- redis ---"
ls -1 /www/server/redis/ 2>/dev/null | head -3
echo "--- panel ip whitelist ---"
if [ -s /www/server/panel/data/limitip.conf ]; then echo "limitip.conf: $(tr -d ' \r\n' < /www/server/panel/data/limitip.conf)"; else echo "limitip.conf: none (panel open to any source IP)"; fi
echo "--- panel domain bind ---"
if [ -s /www/server/panel/data/domain.conf ]; then cat /www/server/panel/data/domain.conf; else echo "domain.conf: none"; fi
echo "--- panel software manifest ---"
cat /www/server/panel/data/plugin.json 2>/dev/null | head -5

section WEB_STACK
echo "nginx:   $( [ -x /www/server/nginx/sbin/nginx ] && /www/server/nginx/sbin/nginx -v 2>&1 || echo not-installed )"
echo "mysql:   $( [ -x /www/server/mysql/bin/mysqld ] && /www/server/mysql/bin/mysqld --version 2>&1 | head -1 || echo not-installed )"
echo "apache:  $( [ -x /www/server/httpd/bin/httpd ] && /www/server/httpd/bin/httpd -v 2>&1 | head -1 || echo not-installed )"
echo "php:     $(ls -1d /www/server/php/*/ 2>/dev/null | tr '\n' ' ')"
echo "redis:   $( [ -x /www/server/redis/src/redis-server ] && /www/server/redis/src/redis-server --version 2>&1 | head -1 || echo not-installed )"
echo "--- staged installers in /www/server ---"
ls -la /www/server/*.tar.gz* 2>/dev/null
echo "--- /www/wwwroot sites ---"
ls -1 /www/wwwroot 2>/dev/null

section PACKAGES
echo "pkg_manager:    $(command -v dnf || command -v yum || command -v apt-get || echo none)"
echo "installed_pkgs: $(rpm -qa 2>/dev/null | wc -l)"
UPD=$(timeout 90 dnf -q check-update 2>/dev/null)
echo "pending_updates: $(printf '%s\n' "$UPD" | grep -cE '^[A-Za-z0-9._+-]+\.')"
echo "--- sample (max 15) ---"
printf '%s\n' "$UPD" | head -15
echo "--- last kernel / boot ---"
rpm -q kernel 2>/dev/null | tail -3
echo "reboot_required: $( [ -f /var/run/reboot-required ] && echo yes || echo no )"

section CRON
echo "--- root crontab ---"
crontab -l 2>/dev/null
echo "--- /etc/cron.d ---"
ls -1 /etc/cron.d/ 2>/dev/null
echo "--- /var/spool/cron ---"
ls -1 /var/spool/cron/ 2>/dev/null
echo "--- panel cron (bt) ---"
ls -1 /www/server/cron/ 2>/dev/null | head -10

section USERS
awk -F: '$3>=1000 && $3<65534 {print $1" uid="$3" shell="$7}' /etc/passwd 2>/dev/null
echo "--- recent logins ---"
last -n 8 2>/dev/null | head -10

section TOP_MEM
ps aux --sort=-%mem 2>/dev/null | head -11

section TOP_CPU
ps aux --sort=-%cpu 2>/dev/null | head -8

section KERNEL_ERRORS
dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -15

section JOURNAL_ERRORS
journalctl -p err -b --no-pager 2>/dev/null | tail -15

section DOCKER
if command -v docker >/dev/null 2>&1; then
  docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | head -20
  echo "docker_containers: $(docker ps -aq 2>/dev/null | wc -l)"
else
  echo "docker: not installed"
fi

section DONE
echo "inventory complete"
