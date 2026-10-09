#!/usr/bin/env bash
# put-astrbot-panel-behind-tls.sh
#
#   * AstrBot's own dashboard gets HTTPS, using the same self-signed cert nginx
#     already uses on 443 (SAN = IP:<TEST_HOST_IP> + DNS:st.<PUBLIC_DOMAIN>).
#   * dashboard.trust_proxy_headers goes OFF: nothing sits in front of the
#     dashboard, so honouring a client-supplied X-Forwarded-For let anyone
#     reset the login rate-limit bucket at will.
#   * Port 80 stops serving SillyTavern and becomes a 301 to the 443 door, so
#     the basicAuth password no longer travels in the clear.
#
# Everything it touches is copied to /root/backups/panel-tls-<stamp>/ first.
set -euo pipefail

STAMP=$(date +%Y%m%d-%H%M%S)
BK="/root/backups/panel-tls-$STAMP"
mkdir -p "$BK"

COMPOSE=/opt/astrbot/docker-compose.yml
CFG=/opt/astrbot/data/cmd_config.json
CFC=/etc/cloudflared/config.yml
ST80=/www/server/panel/vhost/nginx/sillytavern.conf
ST443=/www/server/panel/vhost/nginx/sillytavern-ssl.conf

echo "== 备份到 $BK"
for f in "$COMPOSE" "$CFG" "$CFC" "$ST80" "$ST443"; do cp -a "$f" "$BK/"; done
ls -1 "$BK"

if docker compose version >/dev/null 2>&1; then DC="docker compose"; else DC="docker-compose"; fi
echo "== compose 命令: $DC"

echo
echo "== 前置检查: 容器里 astrbot 以什么身份跑"
U=$(docker exec astrbot id -u 2>/dev/null || echo "?")
echo "   uid=$U"
if [ "$U" != "0" ]; then
  echo "   !! 不是 root。privkey.pem 是 600 root，容器可能读不到，SSL 会起不来。"
fi

echo
echo "== 1/5 compose: 挂载证书目录 + 重写那段过时的注释"
python3 - "$COMPOSE" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = """    ports:
      # Originally loopback-only (nginx + IP allowlist). Changed 2026-09-29 at the
      # owner's explicit request so the dashboard can be opened directly.
      # Consequence, accepted knowingly: plain HTTP on a public port, so the login
      # credentials travel in the clear and the port is reachable by scanners.
      # To revert: restore the previous line and re-run `docker compose up -d`.
      - "6185:6185"
"""
new = """    ports:
      # Public on purpose: the owner wants to open the dashboard from a phone.
      # Since 2026-10-09 AstrBot terminates TLS itself with the cert mounted at
      # /AstrBot/certs, so this port is HTTPS, not plain HTTP.
      # dashboard.trust_proxy_headers is OFF because nothing sits in front of the
      # dashboard; see docs/decisions/ADR-0005.
      - "6185:6185"
"""
assert old in s, "compose: ports 注释块没有逐字匹配上"
s = s.replace(old, new, 1)
vol = "      - /etc/localtime:/etc/localtime:ro\n"
assert vol in s, "compose: 找不到 localtime 挂载行"
s = s.replace(vol, vol + "      # 与 nginx 443 用的是同一张自签证书。\n      - /www/server/panel/vhost/cert/sillytavern:/AstrBot/certs:ro\n", 1)
open(p, 'w', encoding='utf-8', newline='\n').write(s)
print("   compose 已改")
PY

echo
echo "== 2/5 停 astrbot（否则它退出时会把 cmd_config.json 写回去）并改配置"
docker stop astrbot >/dev/null
python3 - "$CFG" <<'PY'
import copy, json, re, sys
p = sys.argv[1]
raw = open(p, encoding='utf-8-sig').read()
orig = json.loads(raw)
m = re.search(r'\n(\s+)"', raw)
indent = len(m.group(1)) if m else 2
work = copy.deepcopy(orig)
db = work['dashboard']
db['ssl']['enable'] = True
db['ssl']['cert_file'] = '/AstrBot/certs/fullchain.pem'
db['ssl']['key_file'] = '/AstrBot/certs/privkey.pem'
db['trust_proxy_headers'] = False

def flat(d, pre=""):
    out = {}
    for k, v in d.items():
        kp = f"{pre}.{k}" if pre else k
        if isinstance(v, dict):
            out.update(flat(v, kp))
        else:
            out[kp] = v
    return out

fo, fw = flat(orig), flat(work)
changed = sorted(k for k in fo if fo[k] != fw.get(k))
print("   变化的键:", changed)
want = sorted(['dashboard.ssl.enable', 'dashboard.ssl.cert_file',
               'dashboard.ssl.key_file', 'dashboard.trust_proxy_headers'])
assert changed == want, f"改动超出预期: {changed}"
open(p, 'w', encoding='utf-8', newline='\n').write(json.dumps(work, ensure_ascii=False, indent=indent) + "\n")
print(f"   cmd_config 已改 (indent={indent})")
PY

echo
echo "== 3/5 起 astrbot"
( cd /opt/astrbot && $DC up -d astrbot ) 2>&1 | tail -6

echo
echo "== 4/5 cloudflared: astr 那条回源改 https（自签，需 noTLSVerify）"
python3 - "$CFC" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
old = "  - hostname: astr.<PUBLIC_DOMAIN>\n    service: http://127.0.0.1:6185\n"
new = "  - hostname: astr.<PUBLIC_DOMAIN>\n    service: https://127.0.0.1:6185\n    originRequest:\n      noTLSVerify: true\n"
assert old in s, "cloudflared: astr 那段没匹配上"
open(p, 'w', encoding='utf-8', newline='\n').write(s.replace(old, new, 1))
print("   cloudflared 已改")
PY
cloudflared tunnel ingress validate --config "$CFC" 2>&1 | tail -3 || true
systemctl restart cloudflared
sleep 2
systemctl is-active cloudflared

echo
echo "== 5/5 nginx: 443 上的插件回源改 https；80 改成跳 443"
cat > "$ST80" <<'EOF'
# Public HTTP door, addressed by IP. Since 2026-10-09 it only redirects.
#
# Managed by scripts/deploy/switch-port80-to-sillytavern.sh and, later,
# scripts/deploy/put-astrbot-panel-behind-tls.sh.
#
# SillyTavern itself lives behind basicAuth, and basicAuth over plain HTTP sends
# the password in the clear, so this vhost now pushes everyone to 443. The cert
# there is self-signed: the browser shows exactly one warning, which is the
# trade-off recorded in docs/decisions/ADR-0004.
#
# To go back to serving plain HTTP: restore sillytavern.conf from the matching
# /root/backups/panel-tls-*/ directory and reload nginx.
server {
    listen 80 default_server;
    server_name _;

    access_log /www/wwwlogs/sillytavern.access.log;
    error_log  /www/wwwlogs/sillytavern.error.log;

    return 301 https://$host$request_uri;
}
EOF

cat > "$ST443" <<'EOF'
# HTTPS door for SillyTavern.
#
# Managed by scripts/deploy/setup-st-https.sh and, later,
# scripts/deploy/put-astrbot-panel-behind-tls.sh.
#
# The certificate is self-signed (SAN = IP:<TEST_HOST_IP> + DNS:st.<PUBLIC_DOMAIN>),
# so browsers show one warning. There is deliberately no public CA option: the
# cloud provider blocks unregistered domains on both 80 and 443 by SNI, and no
# CA issues for a bare IP. See docs/decisions/ADR-0004.
server {
    listen 443 ssl;
    http2 on;
    server_name _;

    ssl_certificate     /www/server/panel/vhost/cert/sillytavern/fullchain.pem;
    ssl_certificate_key /www/server/panel/vhost/cert/sillytavern/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:STSSL:10m;
    ssl_session_timeout 1h;

    access_log /www/wwwlogs/sillytavern-ssl.access.log;
    error_log  /www/wwwlogs/sillytavern-ssl.error.log;

    client_max_body_size 200m;

    # MAA remote control endpoints -> AstrBot. Longest-prefix match wins over
    # `location /` below, so SillyTavern is unaffected; this only claims the
    # plugin's own path.
    #
    # The dashboard moved to HTTPS on 2026-10-09, hence the https upstream and
    # the disabled verification (same self-signed cert).
    location /api/v1/plugins/extensions/astrbot_plugin_arknights_toolbox/ {
        proxy_pass https://127.0.0.1:6185;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
        proxy_buffering off;
    }
}
EOF

/www/server/nginx/sbin/nginx -t
/www/server/nginx/sbin/nginx -s reload

echo
echo "== 等 astrbot 起来"
sleep 12
docker ps --filter name=astrbot --format '{{.Names}}|{{.Status}}|{{.Ports}}'
echo "--- 最近日志"
docker logs --tail 25 astrbot 2>&1 | tail -25

echo
echo "== done. 备份在 $BK"
