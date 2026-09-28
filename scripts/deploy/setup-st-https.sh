#!/usr/bin/env bash
# setup-st-https.sh - add an HTTPS listener for SillyTavern alongside the plain-HTTP one.
#
# Two modes:
#   setup-st-https.sh                       -> generate/reuse a self-signed cert (IP + names)
#   setup-st-https.sh <crt> <key>           -> install a real certificate (e.g. Let's Encrypt)
#
# The self-signed path exists so the 443 door works and can be tested immediately; the
# browser will warn until a real certificate is in place. Because the Tencent security
# group intercepts port-80 HTTP whose Host is an unregistered domain (ADR-0004), only a
# tls-alpn-01 challenge can issue a real certificate here - HTTP-01 cannot.
#
# Usage: setup-st-https.sh [cert-pem] [key-pem]
#
# Rollback: rm /www/server/panel/vhost/nginx/sillytavern-ssl.conf && nginx -s reload

set -uo pipefail

VDIR=/www/server/panel/vhost/nginx
CERTDIR=/www/server/panel/vhost/cert/sillytavern
CRT_SELF="$CERTDIR/fullchain.pem"
KEY_SELF="$CERTDIR/privkey.pem"

CRT="${1:-$CRT_SELF}"
KEY="${2:-$KEY_SELF}"

echo '########## CERTIFICATE ##########'
mkdir -p "$CERTDIR"
if [ "$CRT" = "$CRT_SELF" ] && [ ! -s "$CRT_SELF" ]; then
    echo '  generating a self-signed cert (3650 days)'
    # SAN_IP / SAN_DNS come from the environment so this script carries no real address
    # or hostname (public repo): SAN_IP=<host ip> SAN_DNS=<hostname> setup-st-https.sh
    SAN="IP:${SAN_IP:-127.0.0.1}"
    [ -n "${SAN_DNS:-}" ] && SAN="$SAN,DNS:$SAN_DNS"
    echo "    SAN: $SAN"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -keyout "$KEY_SELF" -out "$CRT_SELF" \
        -subj "/C=CN/O=bt-he1k/CN=bt-he1k" \
        -addext "subjectAltName=$SAN" 2>&1 | sed 's/^/    /'
    chmod 600 "$KEY_SELF"
fi
[ -s "$CRT" ] || { echo "FATAL: no cert at $CRT" >&2; exit 1; }
[ -s "$KEY" ] || { echo "FATAL: no key at $KEY" >&2; exit 1; }
echo "  cert: $CRT"
openssl x509 -in "$CRT" -noout -subject -enddate -ext subjectAltName 2>/dev/null | sed 's/^/    /'

echo
echo '########## VHOST ##########'
cat > "$VDIR/sillytavern-ssl.conf" <<EOS
# HTTPS door for SillyTavern (managed by scripts/deploy/setup-st-https.sh).
#
# Only listens on 443 - the :80 vhost in sillytavern.conf is untouched, so the
# plain-HTTP path keeps working while a real certificate is being sorted out.
server {
    listen 443 ssl;
    http2 on;
    server_name _;

    ssl_certificate     $CRT;
    ssl_certificate_key $KEY;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:STSSL:10m;
    ssl_session_timeout 1h;

    access_log /www/wwwlogs/sillytavern-ssl.access.log;
    error_log  /www/wwwlogs/sillytavern-ssl.error.log;

    client_max_body_size 200m;

    location / {
        proxy_pass http://127.0.0.1:8000;
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
echo "  wrote $VDIR/sillytavern-ssl.conf"

echo
echo '########## RELOAD ##########'
if /www/server/nginx/sbin/nginx -t 2>&1 | sed 's/^/  /'; then
    /www/server/nginx/sbin/nginx -s reload 2>&1 | sed 's/^/  /' || /etc/init.d/nginx reload 2>&1 | sed 's/^/  /'
    echo '  reloaded'
else
    echo 'FATAL: nginx config broken' >&2
    exit 1
fi
sleep 3

echo
echo '########## VERIFY ##########'
echo "  listen 443: $(ss -lntp 2>/dev/null | grep -c ':443 ')"
echo "  no creds  : $(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/)   (401 expected)"
UN=$(grep -A2 '^basicAuthUser:' /opt/sillytavern/config/config.yaml | grep -m1 'username:' | sed 's/.*username: *//; s/"//g')
PW=$(grep -A2 '^basicAuthUser:' /opt/sillytavern/config/config.yaml | grep -m1 'password:' | sed 's/.*password: *//; s/"//g')
echo "  with creds: $(curl -sk -u "$UN:$PW" -o /dev/null -w '%{http_code}' --max-time 10 https://127.0.0.1/)   (200 expected)"
echo "  title     : $(curl -sk -u "$UN:$PW" --max-time 10 https://127.0.0.1/ | grep -oE '<title>[^<]*</title>' | head -1)"
echo "  cert seen : $(echo | openssl s_client -connect 127.0.0.1:443 -servername localhost 2>/dev/null | openssl x509 -noout -subject -issuer 2>/dev/null | tr '\n' ' ')"
echo '  --- plain HTTP still fine? ---'
echo "  http :80  : $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1/)   (401 expected)"

echo
echo 'setup-st-https complete'
