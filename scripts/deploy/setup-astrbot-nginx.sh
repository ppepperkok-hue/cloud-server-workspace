#!/usr/bin/env bash
# setup-astrbot-nginx.sh - publish the AstrBot WebUI through the host nginx with an IP allowlist.
#
# AstrBot keeps listening on 127.0.0.1:6185 only; nginx terminates the public :80 request
# and drops everyone who is not explicitly allowed. This is what keeps a chatbot admin
# dashboard off the open internet without needing a domain or a certificate.
#
# Usage: bash setup-astrbot-nginx.sh [--dry-run] [allowed_ip ...]
#   allowed_ip   IPv4 / IPv6 address or CIDR range (203.0.113.7, 198.51.100.0/24, 2001:db8::/48)
#   no argument  read ASTROBOT_ALLOW_IPS instead (comma- or space-separated, same syntax)
#   127.0.0.1    always allowed on top of the entries above
#
# There is no built-in default entry: this repo is public, so the operator's egress IP
# (<OPERATOR_IP> on 2026-09-28) is stored nowhere here and must be supplied at run time.
# A missing or malformed entry aborts the script before anything on the host is touched.
#
# Idempotent: rewrites the same vhost file and reloads nginx.
# Dry run:    bash setup-astrbot-nginx.sh --dry-run <allowed_ip ...>   (renders, writes nothing)
# Rollback: rm /www/server/panel/vhost/nginx/astrbot.conf ; nginx -s reload
#           (a timestamped copy of the whole vhost dir is kept under /root/backups/nginx-*)

set -uo pipefail

VHOST_DIR=/www/server/panel/vhost/nginx
VHOST_FILE="$VHOST_DIR/astrbot.conf"
NGINX_BIN=/www/server/nginx/sbin/nginx
UPSTREAM=127.0.0.1:6185
DRY_RUN=0

die() {
    echo "FATAL: $*" >&2
    exit 1
}

usage() {
    printf '%s\n' "Usage: bash setup-astrbot-nginx.sh [--dry-run] [allowed_ip ...]

  allowed_ip    IPv4/IPv6 address or CIDR range, e.g. 203.0.113.7 or 198.51.100.0/24
  (none given)  fall back to the ASTROBOT_ALLOW_IPS environment variable
                (comma- or space-separated, same syntax)

127.0.0.1 is always allowed on top of these entries. There is no default entry:
the operator's egress IP is not in this public repo, so it has to be supplied
here, and the script aborts before touching the host if it is missing or invalid.

  -n, --dry-run   validate and print the vhost; write nothing, reload nothing
  -h, --help      show this help"
}

# Accept IPv4 / IPv6, optionally with a /prefix. Anything else is refused up front, so a
# stray value can never end up as an nginx directive (or as a shell redirection).
is_allow_entry() {
    local entry=$1 addr=$1 prefix='' octet group n=0

    case "$entry" in
        '' | *[!0-9A-Fa-f:./]*) return 1 ;;
    esac

    if [[ $entry == */* ]]; then
        addr=${entry%%/*}
        prefix=${entry#*/}
        [[ $prefix =~ ^[0-9]{1,3}$ ]] || return 1
    fi

    if [[ $addr == *:* ]]; then
        # IPv6: at most one "::", 1-4 hex digits per group, 8 groups in total.
        [[ -z $prefix ]] || [ "$((10#$prefix))" -le 128 ] || return 1
        [[ $addr == *:::* ]] && return 1
        [[ $addr == *::*::* ]] && return 1
        [[ $addr == *: && $addr != *:: ]] && return 1
        [[ $addr == :* && $addr != ::* ]] && return 1
        [[ $addr =~ ^[0-9A-Fa-f:]+$ ]] || return 1
        for group in ${addr//:/ }; do
            [ "${#group}" -le 4 ] || return 1
            n=$((n + 1))
        done
        if [[ $addr == *::* ]]; then
            [ "$n" -le 7 ] || return 1
        else
            [ "$n" -eq 8 ] || return 1
        fi
        return 0
    fi

    # IPv4: four decimal octets, no leading zeros, each 0-255.
    [[ -z $prefix ]] || [ "$((10#$prefix))" -le 32 ] || return 1
    octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    [[ $addr =~ ^$octet(\.$octet){3}$ ]]
}

ALLOW_IPS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -n | --dry-run) DRY_RUN=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            ALLOW_IPS+=("$@")
            break
            ;;
        -*) die "unknown option: $1 (see --help)" ;;
        *) ALLOW_IPS+=("$1") ;;
    esac
    shift
done

if [ "${#ALLOW_IPS[@]}" -eq 0 ] && [ -n "${ASTROBOT_ALLOW_IPS:-}" ]; then
    # Comma/space separated; empty fields are dropped so "a, , b" is not an error.
    _raw_ips=()
    IFS=', ' read -r -a _raw_ips <<< "$ASTROBOT_ALLOW_IPS"
    for entry in "${_raw_ips[@]}"; do
        [ -n "$entry" ] && ALLOW_IPS+=("$entry")
    done
    unset _raw_ips entry
fi

if [ "${#ALLOW_IPS[@]}" -eq 0 ]; then
    die "no allowlist entry given. Pass the operator IP explicitly, e.g.:
    bash $0 203.0.113.7
  or set ASTROBOT_ALLOW_IPS=203.0.113.7,198.51.100.0/24 (see --help)"
fi

for ip in "${ALLOW_IPS[@]}"; do
    is_allow_entry "$ip" || die "invalid allowlist entry '$ip': expected an IPv4/IPv6 address or CIDR range"
    case "$ip" in
        */0) echo "WARNING: '$ip' matches every address, so the allowlist is effectively open" >&2 ;;
    esac
done

if [ -d "$VHOST_DIR" ]; then
    :
elif [ "$DRY_RUN" -eq 1 ]; then
    echo "WARNING: $VHOST_DIR not found; dry run continues and writes nothing" >&2
else
    die "BT nginx vhost dir not found: $VHOST_DIR"
fi

render_vhost() {
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
}

echo
if [ "$DRY_RUN" -eq 1 ]; then
    echo '########## RENDER VHOST (dry run: nothing written) ##########'
    render_vhost
    echo
    echo "dry run: $VHOST_FILE untouched, nginx not reloaded"
    exit 0
fi

echo '########## BACKUP ##########'
BK="/root/backups/nginx-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BK"
cp -a "$VHOST_DIR" "$BK/vhost-nginx" 2>/dev/null || true
cp -a /www/server/nginx/conf/nginx.conf "$BK/" 2>/dev/null || true
printf '%s\n' "$BK" > /root/backups/nginx-LAST
echo "  backup at $BK"

echo
echo '########## WRITE VHOST ##########'
render_vhost > "$VHOST_FILE"
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
if [ -n "${TEST_HOST_IP:-}" ]; then
    echo "  http://${TEST_HOST_IP}/  -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://${TEST_HOST_IP}/" 2>/dev/null)   (expect 403: not in allowlist)"
else
    echo "  deny path          -> skipped; rerun with TEST_HOST_IP=<host address> in the environment to probe it (expect 403)"
fi
echo "  upstream direct    -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://${UPSTREAM}/ 2>/dev/null)   (expect 200)"
echo "  astrbot bindings:"
ss -lntp 2>/dev/null | grep -E ':6185|:6199' | sed 's/^/    /'
echo
echo "Next: set dashboard.trust_proxy_headers=true in cmd_config.json (restart AstrBot to apply),"
echo "then check from the operator's machine:  curl -s http://<public-ip>/ | grep -o '<title>[^<]*</title>'"
echo
echo 'setup-astrbot-nginx complete'
