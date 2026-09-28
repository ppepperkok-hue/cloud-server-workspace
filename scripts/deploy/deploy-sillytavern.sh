#!/usr/bin/env bash
# deploy-sillytavern.sh - unpack a migrated SillyTavern payload and (re)start the container.
#
# Expected payload layout (produced by scripts/deploy/package-sillytavern.py):
#   config/config.yaml
#   data/            (default-user, cookie-secret.txt, ...)
#   extensions/third-party/<extension>
#   plugins/
#
# Usage: bash deploy-sillytavern.sh [tarball] [root]
#
# Notes for this host:
#   * The container port is published on 127.0.0.1 only; access goes over an SSH tunnel
#     (see scripts/utils/napcat-webui-tunnel.ps1 / the ST section of the runbook).
#   * Requests arrive from the docker bridge gateway, so SillyTavern can no longer be
#     reached "from 127.0.0.1" - its own whitelist needs the private ranges added.
#
# Rollback: cd /opt/sillytavern && docker compose down
#           previous config/data/extensions are kept as <name>.pre-<timestamp>

set -uo pipefail

ROOT="${2:-/opt/sillytavern}"
TARBALL="${1:-/root/sillytavern-payload.tar.gz}"
IMAGE=$(cat /root/.dsh-st-image 2>/dev/null || echo ghcr.io/sillytavern/sillytavern:latest)

[ -f "$TARBALL" ] || { echo "FATAL: payload not found: $TARBALL" >&2; exit 1; }
echo "image: $IMAGE"

echo
echo '########## STOP + BACKUP ##########'
if [ -f "$ROOT/docker-compose.yml" ]; then
    ( cd "$ROOT" && docker compose down 2>&1 | tail -3 )
    cp -a "$ROOT/docker-compose.yml" "$ROOT/docker-compose.yml.$(date +%Y%m%d-%H%M%S).bak"
    echo "  compose backed up"
else
    docker rm -f sillytavern >/dev/null 2>&1 || true
fi

echo
echo '########## UNPACK ##########'
SCRATCH="$(mktemp -d /tmp/st-unpack.XXXXXX)"
tar xzf "$TARBALL" -C "$SCRATCH"
for d in config data extensions plugins; do
    if [ ! -d "$SCRATCH/$d" ]; then
        echo "FATAL: payload is missing '$d/'" >&2
        ls -la "$SCRATCH" >&2
        exit 1
    fi
done
echo "  payload: $(find "$SCRATCH" -type f | wc -l) files, $(du -sh "$SCRATCH" | cut -f1)"

echo
echo '########## PLACE ##########'
mkdir -p "$ROOT"
STAMP="$(date +%Y%m%d-%H%M%S)"
for d in config data extensions plugins; do
    if [ -d "$ROOT/$d" ] && [ "$(ls -A "$ROOT/$d" 2>/dev/null)" ]; then
        mv "$ROOT/$d" "$ROOT/$d.pre-$STAMP"
        echo "  previous $d -> $d.pre-$STAMP"
    fi
    mkdir -p "$ROOT/$d"
    shopt -s dotglob
    if [ "$d" = "extensions" ] && [ -d "$SCRATCH/extensions/third-party" ]; then
        # The payload keeps the upstream layout (extensions/third-party/<name>), but the
        # container mounts its volume AT .../extensions/third-party, so the host dir must
        # hold the extension folders directly. Flatten one level or nothing loads.
        cp -a "$SCRATCH/extensions/third-party"/* "$ROOT/$d"/ 2>/dev/null || true
    else
        cp -a "$SCRATCH/$d"/* "$ROOT/$d"/ 2>/dev/null || true
    fi
    shopt -u dotglob
done
rm -rf "$SCRATCH"
chown -R root:root "$ROOT" 2>/dev/null || true
find "$ROOT" -type d -exec chmod 755 {} + 2>/dev/null || true

echo "  --- layout ---"
for d in config data extensions plugins; do
    printf '    %-12s %s files  %s\n' "$d" "$(find "$ROOT/$d" -type f | wc -l)" "$(du -sh "$ROOT/$d" | cut -f1)"
done
[ -f "$ROOT/config/config.yaml" ] || { echo "FATAL: config/config.yaml missing" >&2; exit 1; }

echo
echo '########## PATCH CONFIG FOR CONTAINER / PROXY ##########'
python3 - "$ROOT/config/config.yaml" <<'PY'
import re
import shutil
import sys

path = sys.argv[1]
shutil.copy2(path, path + '.pre-migration')
text = open(path, encoding='utf-8').read()

# Requests reach the container from the docker bridge gateway, never from 127.0.0.1,
# so SillyTavern's own whitelist needs the private ranges or it answers 403 to
# everything. The outer gate stays the SSH tunnel / nginx IP allowlist.
#
# The indentation MUST match the existing entries exactly: a deeper indent turns the
# entry into a sub-list of the previous one, YAML still parses, and the address is
# silently NOT whitelisted. (Cost me an hour on 2026-09-28.)
WANT = '172.16.0.0/12'
text = re.sub(r'(?m)^[ \t]*-[ \t]*' + re.escape(WANT) + r'[ \t]*\n', '', text)
m = re.search(r'(?m)^whitelist:[ \t]*\n((?:[ \t]*-[^\n]*\n)+)', text)
if not m:
    raise SystemExit('FATAL: whitelist list not found in config.yaml')
indent = re.match(r'([ \t]*)', m.group(1)).group(1)
new_body = m.group(1).rstrip('\n') + f'\n{indent}- {WANT}\n'
text = text[:m.start(1)] + new_body + text[m.end(1):]

text = re.sub(r'(?m)^heartbeatInterval:.*$', 'heartbeatInterval: 30', text, count=1)
open(path, 'w', encoding='utf-8').write(text)

for key in ('whitelistMode', 'whitelistDockerHosts', 'basicAuthMode', 'heartbeatInterval'):
    mm = re.search(rf'(?m)^{key}:.*$', text)
    if mm:
        print('  ' + mm.group(0).strip())
print('  whitelist:')
for line in re.search(r'(?m)^whitelist:[ \t]*\n((?:[ \t]*-[^\n]*\n)+)', text).group(1).splitlines():
    print('   ', repr(line))
PY

echo
echo '########## COMPOSE ##########'
cat > "$ROOT/docker-compose.yml" <<EOS
services:
  sillytavern:
    image: $IMAGE
    container_name: sillytavern
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
      - SILLYTAVERN_HEARTBEATINTERVAL=30
    volumes:
      - $ROOT/config:/home/node/app/config:rw
      - $ROOT/data:/home/node/app/data:rw
      - $ROOT/extensions:/home/node/app/public/scripts/extensions/third-party:rw
      - $ROOT/plugins:/home/node/app/plugins:rw
      - /etc/localtime:/etc/localtime:ro
    ports:
      # loopback only: reached through an SSH tunnel, never published to the internet.
      - "127.0.0.1:8000:8000"
    healthcheck:
      test: ["CMD", "node", "src/healthcheck.js"]
      interval: 30s
      timeout: 10s
      start_period: 30s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
EOS
cat "$ROOT/docker-compose.yml"

echo
echo '########## START ##########'
cd "$ROOT"
docker compose up -d 2>&1 | tail -6
sleep 30
echo "  status : $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' sillytavern 2>&1)"
echo "  health : $(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' sillytavern 2>&1)"
echo "  ports  : $(docker port sillytavern 2>&1 | tr '\n' ' ')"
echo "  http   : $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1:8000/ 2>/dev/null)"
echo '  --- logs (tail 25) ---'
docker logs --tail 25 sillytavern 2>&1

echo
echo 'deploy-sillytavern complete'
