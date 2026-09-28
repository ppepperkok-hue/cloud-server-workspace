#!/usr/bin/env bash
# setup-cloudflared-tunnel.sh - run a named Cloudflare tunnel as a systemd service.
#
# Usage:
#   setup-cloudflared-tunnel.sh <credentials.json> <tunnel-id> <name=port> [<name=port> ...]
#
# Example (hostnames supplied by the caller - this repo is public, so the script
# itself must not carry any real hostname, see docs/inventory/README.md):
#   setup-cloudflared-tunnel.sh /root/tunnel.json 00000000-1111-2222-3333-444444444444 \
#       astr.example.com=6185 napcat1.example.com=6099 st.example.com=8000
#
# Every route is proxied to 127.0.0.1:<port> on this host. Anything else -> 404.
set -uo pipefail

CRED="${1:-}"
TUNNEL_ID="${2:-}"
shift 2 2>/dev/null || true
ROUTES=("$@")

[ -n "$CRED" ] && [ -f "$CRED" ] || { echo "FATAL: credentials file missing: ${CRED:-<none>}" >&2; exit 1; }
[ -n "$TUNNEL_ID" ] || { echo 'FATAL: tunnel id missing' >&2; exit 1; }
[ "${#ROUTES[@]}" -gt 0 ] || { echo 'FATAL: no routes given (name=port)' >&2; exit 1; }
[ -x /usr/local/bin/cloudflared ] || { echo 'FATAL: cloudflared not installed (run install-cloudflared.sh)' >&2; exit 1; }

echo '########## INSTALL CREDENTIALS ##########'
install -d -m 700 /etc/cloudflared
install -m 600 "$CRED" "/etc/cloudflared/$TUNNEL_ID.json"
ls -la "/etc/cloudflared/$TUNNEL_ID.json" | sed 's/^/  /'

echo
echo '########## WRITE CONFIG ##########'
{
    echo "tunnel: $TUNNEL_ID"
    echo "credentials-file: /etc/cloudflared/$TUNNEL_ID.json"
    echo ''
    echo '# Avoid sending the operator IP in X-Forwarded-For to the origins we control.'
    echo 'ingress:'
    for route in "${ROUTES[@]}"; do
        host="${route%%=*}"
        port="${route##*=}"
        [ "$host" != "$route" ] || { echo "FATAL: bad route '$route' (expected name=port)" >&2; exit 1; }
        case "$port" in
            ''|*[!0-9]*) echo "FATAL: bad port in '$route'" >&2; exit 1 ;;
        esac
        echo "  - hostname: $host"
        echo "    service: http://127.0.0.1:$port"
    done
    echo '  - service: http_status:404'
} > /etc/cloudflared/config.yml
chmod 600 /etc/cloudflared/config.yml
cat /etc/cloudflared/config.yml | sed 's/^/  /'

echo
echo '########## SYSTEMD UNIT ##########'
cat > /etc/systemd/system/cloudflared.service <<'EOS'
[Unit]
Description=Cloudflare Tunnel
Documentation=https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
# The origin services are local containers published on 127.0.0.1; make sure they
# are up before the tunnel advertises itself.
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config /etc/cloudflared/config.yml tunnel run
Restart=on-failure
RestartSec=5s
# cloudflared is happy with modest limits
LimitNOFILE=65536
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOS
sed 's/^/  /' /etc/systemd/system/cloudflared.service

echo
echo '########## START ##########'
systemctl daemon-reload
systemctl enable --now cloudflared 2>&1 | tail -3 | sed 's/^/  /'
sleep 20

echo
echo '########## VERIFY ##########'
echo "  unit   : $(systemctl is-active cloudflared) / $(systemctl is-enabled cloudflared)"
echo "  version: $(/usr/local/bin/cloudflared --version)"
echo '  --- tunnel info ---'
/usr/local/bin/cloudflared tunnel info "$TUNNEL_ID" 2>&1 | tail -8 | sed 's/^/    /'
echo '  --- journal (tail) ---'
journalctl -u cloudflared -n 12 --no-pager --output=cat 2>/dev/null | sed 's/^/    /'

echo
echo '  --- local origin probes (what the tunnel will reach) ---'
for route in "${ROUTES[@]}"; do
    host="${route%%=*}"
    port="${route##*=}"
    printf '    %-34s -> 127.0.0.1:%-5s http=%s\n' "$host" "$port" \
        "$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:$port/" 2>/dev/null)"
done

echo
echo 'setup-cloudflared-tunnel complete'
