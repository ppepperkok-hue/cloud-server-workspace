#!/usr/bin/env bash
# harden-bt-panel.sh - enable BT panel HTTPS (SHA-256 self-signed) and set the panel IP allowlist.
#
# Idempotent: safe to re-run. Regenerates the cert only when missing (set FORCE_SSL=1 to force).
#
# Usage:  bash harden-bt-panel.sh <allowed-ip[,allowed-ip...]|none>
#
# Why not BT's own "enable panel SSL": class/config.py CreateSSL() signs the self-signed
# cert with md5 (cert.sign(key, 'md5')), which modern browsers and OpenSSL 3 reject.
#
# Why limitip.conf: class/public.py check_ip_panel() treats it as an ALLOWLIST - empty or
# absent means "no restriction", non-empty means only the listed IPs (plus 127.0.0.1) may
# reach the panel. Separator is "," and ranges are written as "a.b.c.d-a.b.c.e"; CIDR is
# NOT supported. Recovery if you lock yourself out: run `bt 13` (removes the allowlist).
#
# Rollback: restore the tarballs under /root/backups/bt-panel-harden-* then `/etc/init.d/bt restart`.

set -uo pipefail

P=/www/server/panel
ALLOW="${1:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BK="/root/backups/bt-panel-harden-${STAMP}"

if [ -z "$ALLOW" ]; then
    echo "usage: $0 <allowed-ip[,ip...]|none>" >&2
    exit 2
fi

# safe file reader: never fails when the file is absent
rdf() { if [ -f "$1" ]; then tr -d ' \r\n' < "$1" 2>/dev/null || true; fi; }

PORT="$(rdf "$P/data/port.pl")";   [ -n "$PORT" ]  || PORT=8888
ENTRY="$(rdf "$P/data/admin_path.pl")"
SSL_BEFORE="$( [ -f "$P/data/ssl.pl" ] && echo on || echo off )"
LIMIT_BEFORE="$(rdf "$P/data/limitip.conf")"

echo "== 0. preflight =="
[ -d "$P" ] || { echo "FATAL: BT panel not found at $P" >&2; exit 1; }
echo "port=${PORT} entry=${ENTRY}"
echo "ssl_before=${SSL_BEFORE}"
echo "limitip_before=[${LIMIT_BEFORE}]"

echo "== 1. backup -> $BK =="
mkdir -p "$BK"
tar czf "$BK/panel-data.tgz" -C "$P" data 2>/dev/null || true
tar czf "$BK/panel-ssl.tgz"  -C "$P" ssl  2>/dev/null || true
for f in "$BK/panel-data.tgz" "$BK/panel-ssl.tgz"; do
    if [ ! -s "$f" ]; then echo "FATAL: backup $f is empty/missing, aborting" >&2; exit 1; fi
done
{
    echo "panel=$P"
    echo "port=$PORT"
    echo "entry=$ENTRY"
    echo "ssl_before=$SSL_BEFORE"
    echo "limitip_before=[$LIMIT_BEFORE]"
    echo "restore: tar xzf panel-data.tgz -C $P ; tar xzf panel-ssl.tgz -C $P ; /etc/init.d/bt restart"
} > "$BK/ROLLBACK.txt"
ln -sfn "$BK" /root/backups/bt-panel-harden-LAST
ls -la "$BK"

echo "== 2. panel ssl (sha256 self-signed) =="
if [ "${FORCE_SSL:-0}" = "1" ] || [ ! -s "$P/ssl/privateKey.pem" ] || [ ! -s "$P/ssl/certificate.pem" ]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -sha256 \
        -keyout "$P/ssl/privateKey.pem" \
        -out "$P/ssl/certificate.pem" \
        -subj "/CN=bt-he1k" \
        -addext "subjectAltName=IP:<TEST_HOST_IP>,IP:<TEST_HOST_PRIVATE_IP>,DNS:<TEST_HOST_HOSTNAME>" >/dev/null 2>&1 || true
    echo "generated new self-signed cert"
else
    echo "cert already present, keeping it"
fi
if [ ! -s "$P/ssl/privateKey.pem" ] || [ ! -s "$P/ssl/certificate.pem" ]; then
    echo "FATAL: cert generation failed, not enabling SSL" >&2
    exit 1
fi
chmod 600 "$P/ssl/privateKey.pem"
chmod 644 "$P/ssl/certificate.pem"
touch "$P/ssl/input.pl"
printf 'True' > "$P/data/ssl.pl"

echo "== 3. panel ip allowlist =="
if [ "$ALLOW" = "none" ]; then
    : > "$P/data/limitip.conf"
    echo "allowlist cleared (panel open to any source IP)"
else
    printf '%s' "$ALLOW" > "$P/data/limitip.conf"
    echo "allowlist set to [$ALLOW]"
fi
chmod 600 "$P/data/limitip.conf"

echo "== 4. restart panel =="
/etc/init.d/bt restart 2>&1 | tail -6 || true
sleep 4

echo "== 5. verify (on host) =="
# NOTE: BT panel answers 404 to requests without a browser-like User-Agent
# (anti-scanning gate). Always probe with a browser UA, or you will think the
# panel is broken when it is fine. See ADR-0002.
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'
if ss -lntp 2>/dev/null | grep -q ":${PORT} "; then
    echo "port ${PORT}: LISTENING"
else
    echo "WARN: port ${PORT} not listening"
fi
echo "https_local_127=$(curl -sk -A "$UA" -o /dev/null -w '%{http_code}' --max-time 10 "https://127.0.0.1:${PORT}${ENTRY}" || echo err)"
echo "https_no_ua=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://127.0.0.1:${PORT}${ENTRY}" || echo err)   # expect 404: UA gate, not a fault"
echo "http_local_127=$(curl -s  -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}${ENTRY}"  || echo err)"
echo "ssl_flag=$( [ -f "$P/data/ssl.pl" ] && echo on || echo off )"
echo "limitip_after=[$(rdf "$P/data/limitip.conf")]"
echo "cert: $(openssl x509 -in "$P/ssl/certificate.pem" -noout -subject -enddate 2>/dev/null | tr '\n' ' ')"
echo "== harden complete (backup: $BK) =="
