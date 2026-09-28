#!/usr/bin/env bash
# setup-astrbot-nginx.sh - publish the AstrBot WebUI through the host nginx with an IP allowlist.
#
# AstrBot keeps listening on 127.0.0.1:6185 only; nginx terminates the public :80 request
# and drops everyone who is not explicitly allowed. This is what keeps a chatbot admin
# dashboard off the open internet without needing a domain or a certificate.
#
# Usage: bash setup-astrbot-nginx.sh [allowed_ip ...]
#   default allowlist: <OPERATOR_IP> (operator egress IP on 2026-09-28) + 127.0.0.1
#
# Idempotent: rewrites the same vhost file and reloads nginx.
# Rollback: rm /www/server/panel/vhost/nginx/astrbot.conf ; nginx -s reload
#           (a timestamped copy of the whole vhost dir is kept under /root/backups/nginx-*)

set -uo pipefail

VHOST_DIR=/www/server/panel/vhost/nginx
VHOST_FILE="$VHOST_DIR/astrbot.conf"
NGINX_BIN=/www/server/nginx/sbin/nginx
UPSTREAM=127.0.0.1:6185

if [ "$#" -gt 0 ]; then
    ALLOW_IPS=("$@")
else
    ALLOW_IPS=(<OPERATOR_IP>)
fi

[ -d "$VHOST_DIR" ] || { echo "FATAL: BT nginx vhost dir not found: $VHOST_DIR" >&2; exit 1; }

echo '########## BACKUP ##########'
BK="/root/backups/nginx-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
cp -a "$VHOST_DIR" "$BK/vhost-nginx" 2>/dev/null || true
cp -a /www/server/nginx/conf/nginx.conf "$BK/" 2>/dev/null || true
printf '%s\n' "$BK" > /root/backups/nginx-LAST
echo "  backup at $BK"

echo
echo '########## WRITE VHOST ##########'
{
    echo "# AstrBot dashboard reverse proxy (managed by scripts/deploy/setup-astrbot-nginx.sh)."
    echo "#"
    echo "# - AstrBot binds ${UPSTREAM} only and is never published to the internet."
    echo "# - Only the IPs below may reach this vhost; everyone else gets 403."
    echo "# - This file sorts first in vhost/nginx/, so it is the default server on :80."
    echo "#"
    echo "# For HTTPS: give this host a domain, open 443 in the cloud firewall, then add"
    echo "# ssl_certificate / ssl_certificate_key / listen 443 ssl here."
    echo "server {"
    echo "    listen 80;"
    echo "    server_name _;"
    echo ""
    for ip in "${ALLOW_IPS[@]}"; do
        echo "    allow ${ip};"
    done
    echo "    allow 127.0.0.1;"
    echo "    deny all;"
    echo ""
    echo "    access_log /www/wwwlogs/astrbot.access.log;"
    echo "    error_log  /www/wwwlogs/astrbot.error.log;"
    echo ""
    echo "    client_max_body_size 200m;"
    echo ""
    echo "    location / {"
    echo "        proxy_pass http://${UPSTREAM};"
    echo "        proxy_http_version 1.1;"
    echo "        proxy_set_header Upgrade           \$http_upgrade;"
    echo "        proxy_set_header Connection        \"upgrade\";"
    echo "        proxy_set_header Host              \$host;"
    echo "        proxy_set_header X-Real-IP         \$remote_addr;"
    echo "        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;"
    echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
    echo "        proxy_read_timeout 600s;"
    echo "        proxy_send_timeout 600s;"
    echo "        proxy_buffering off;"
    echo "    }"
    echo "}"
} > "$VHOST_FILE"
cat "$VHOST_FILE"

echo
echo '########## TEST + RELOAD ##########'
if ! "$NGINX_BIN" -t 2>&1; then
    echo "FATAL: nginx config test failed, rolling back" >&2
    rm -f "$VHOST_FILE"
    "$NGINX_BIN" -t 2>&1
    exit 1
fi
"$NGINX_BIN" -s reload 2>&1 || /etc/init.d/nginx reload 2>&1
sleep 3

echo
echo '########## VERIFY (on host) ##########'
echo "  http://127.0.0.1/  -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1/ 2>/dev/null)   (expect 200)"
echo "  http://<TEST_HOST_PRIVATE_IP>/  -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://<TEST_HOST_PRIVATE_IP>/ 2>/dev/null)   (expect 403: not in allowlist)"
echo "  upstream direct    -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://${UPSTREAM}/ 2>/dev/null)   (expect 200)"
echo "  astrbot bindings:"
ss -lntp 2>/dev/null | grep -E ':6185|:6199' | sed 's/^/    /'
echo
echo "Next: set dashboard.trust_proxy_headers=true in cmd_config.json (restart AstrBot to apply),"
echo "then check from the operator's machine:  curl -s http://<public-ip>/ | grep -o '<title>[^<]*</title>'"
echo
echo 'setup-astrbot-nginx complete'
