#!/usr/bin/env bash
# switch-port80-to-sillytavern.sh - serve SillyTavern on the already-open port 80.
#
# Why port 80: the Tencent Cloud security group only allows 22/80/8888, and a domain
# on 80 gets intercepted (ADR-0004), so the one usable public entry is "port 80 by IP".
# AstrBot keeps its own door (astr.<PUBLIC_DOMAIN> via the Cloudflare tunnel) and the
# SSH tunnel (127.0.0.1:6185).
#
# Why no IP allowlist: phones get a new address on every network, so an allowlist would
# lock them out. Access control is SillyTavern's own basicAuth instead - run
# st-set-basicauth.sh FIRST or this exposes the tavern unauthenticated.
#
# Usage: switch-port80-to-sillytavern.sh [port] [origin-port]
#
# Rollback: /root/backups/nginx-LAST holds the previous vhost set - copy it back and reload.

set -uo pipefail

PORT="${1:-80}"
ORIGIN="${2:-8000}"
VDIR=/www/server/panel/vhost/nginx
STAMP="$(date +%Y%m%d-%H%M%S)"

echo '########## PREFLIGHT ##########'
if ! grep -qE '^basicAuthMode: *true' /opt/sillytavern/config/config.yaml; then
    echo 'FATAL: SillyTavern basicAuthMode is not true.' >&2
    echo '       Run st-set-basicauth.sh first - otherwise this puts the tavern on the open internet with no login.' >&2
    exit 1
fi
echo '  basicAuthMode: true (ok)'
echo "  origin probe : $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$ORIGIN/")  (401 expected with auth on)"

echo
echo '########## BACKUP ##########'
mkdir -p "/root/backups/nginx-$STAMP"
cp -a "$VDIR"/*.conf "/root/backups/nginx-$STAMP/" 2>/dev/null || true
ln -sfn "/root/backups/nginx-$STAMP" /root/backups/nginx-LAST
echo "  saved to /root/backups/nginx-$STAMP"

echo
echo '########## WRITE VHOST ##########'
cat > "$VDIR/sillytavern.conf" <<EOS
# SillyTavern on the open port, addressed by IP.
#
# Managed by scripts/deploy/switch-port80-to-sillytavern.sh.
#
# - SillyTavern binds 127.0.0.1:$ORIGIN only; this vhost is the only public door.
# - No IP allowlist on purpose: phones change address per network. The gate is
#   SillyTavern's own basicAuth (basicAuthMode: true).
# - Plain HTTP: the security group does not allow 443 yet, so the login travels
#   unencrypted. Open 443 + add a cert before treating this as production.
server {
    listen $PORT;
    server_name _;

    access_log /www/wwwlogs/sillytavern.access.log;
    error_log  /www/wwwlogs/sillytavern.error.log;

    client_max_body_size 200m;

    location / {
        proxy_pass http://127.0.0.1:$ORIGIN;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
        proxy_buffering off;
    }
}
EOS
echo "  wrote $VDIR/sillytavern.conf"

if [ -f "$VDIR/astrbot.conf" ]; then
    mv "$VDIR/astrbot.conf" "$VDIR/astrbot.conf.disabled-$STAMP"
    echo '  disabled astrbot.conf (AstrBot now only via its domain / the SSH tunnel)'
fi

echo
echo '########## RELOAD ##########'
if /www/server/nginx/sbin/nginx -t 2>&1 | sed 's/^/  /'; then
    /www/server/nginx/sbin/nginx -s reload 2>&1 | sed 's/^/  /' || /etc/init.d/nginx reload 2>&1 | sed 's/^/  /'
    echo '  reloaded'
else
    echo 'FATAL: nginx config broken, restoring' >&2
    cp -a "/root/backups/nginx-$STAMP"/*.conf "$VDIR"/
    rm -f "$VDIR"/astrbot.conf.disabled-*
    /www/server/nginx/sbin/nginx -s reload
    exit 1
fi
sleep 3

echo
echo '########## VERIFY ##########'
echo "  by IP, no credentials   : $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:$PORT/)  (401 = login required)"
echo "  by IP, with credentials : $(UN=$(grep -A2 '^basicAuthUser:' /opt/sillytavern/config/config.yaml | grep -m1 'username:' | sed 's/.*username: *//; s/"//g'); PW=$(grep -A2 '^basicAuthUser:' /opt/sillytavern/config/config.yaml | grep -m1 'password:' | sed 's/.*password: *//; s/"//g'); curl -s -u "$UN:$PW" -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:$PORT/)  (200 expected)"
echo "  title with credentials  : $(UN=$(grep -A2 '^basicAuthUser:' /opt/sillytavern/config/config.yaml | grep -m1 'username:' | sed 's/.*username: *//; s/"//g'); PW=$(grep -A2 '^basicAuthUser:' /opt/sillytavern/config/config.yaml | grep -m1 'password:' | sed 's/.*password: *//; s/"//g'); curl -s -u "$UN:$PW" --max-time 10 http://127.0.0.1:$PORT/ | grep -oE '<title>[^<]*</title>' | head -1)"
echo '  --- active :80 vhosts ---'
grep -l 'listen 80' "$VDIR"/*.conf 2>/dev/null | sed 's/^/    /'

echo
echo 'switch-port80-to-sillytavern complete'
