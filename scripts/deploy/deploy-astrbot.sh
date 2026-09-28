#!/usr/bin/env bash
# deploy-astrbot.sh - unpack migrated AstrBot data and (re)start the container.
#
# Usage: bash deploy-astrbot.sh [tarball] [root] [image]
#   tarball  default /root/astrbot-data.tar.gz  (must contain a top-level data/ dir)
#   root     default /opt/astrbot
#   image    default the pinned image matching the source version
#
# The tarball is unpacked into a scratch dir and the CONTENTS are then copied into
# <root>/data. Do NOT `mv <scratch>/data <root>/data` while <root>/data exists:
# mv nests it as <root>/data/data and AstrBot silently boots with a brand-new
# config and a random initial password instead of the migrated one.
# (Learned the hard way on bt-he1k, 2026-09-28.)

set -uo pipefail

TARBALL="${1:-/root/astrbot-data.tar.gz}"
ROOT="${2:-/opt/astrbot}"
IMAGE="${3:-m.daocloud.io/docker.io/soulter/astrbot:v4.28.1}"
DATA="$ROOT/data"

[ -f "$TARBALL" ] || { echo "FATAL: tarball not found: $TARBALL" >&2; exit 1; }

echo '########## STOP ##########'
if [ -f "$ROOT/docker-compose.yml" ]; then
    ( cd "$ROOT" && docker compose down 2>&1 | tail -4 )
else
    docker rm -f astrbot >/dev/null 2>&1 || true
    echo "no compose file yet"
fi

echo
echo '########## UNPACK ##########'
SCRATCH="$(mktemp -d /tmp/astrbot-unpack.XXXXXX)"
tar xzf "$TARBALL" -C "$SCRATCH"
SRC="$SCRATCH/data"
if [ ! -d "$SRC" ]; then
    echo "FATAL: tarball has no top-level data/ dir" >&2
    ls -la "$SCRATCH" >&2
    exit 1
fi
echo "scratch payload: $(find "$SRC" -type f | wc -l) files"

echo
echo '########## PLACE DATA ##########'
mkdir -p "$ROOT"
if [ -d "$DATA" ] && [ "$(ls -A "$DATA" 2>/dev/null)" ]; then
    PREV="$ROOT/data.pre-$(date +%Y%m%d-%H%M%S)"
    mv "$DATA" "$PREV"
    echo "previous data preserved at $PREV"
fi
mkdir -p "$DATA"
shopt -s dotglob
cp -a "$SRC"/* "$DATA"/
shopt -u dotglob
rm -rf "$SCRATCH"

find "$ROOT" -type d -exec chmod 755 {} + 2>/dev/null || true
find "$DATA" -type f -exec chmod 644 {} + 2>/dev/null || true
chown -R root:root "$ROOT" 2>/dev/null || true

echo "files=$(find "$DATA" -type f | wc -l)  size=$(du -sh "$DATA" | cut -f1)"
echo '--- top level ---'
ls -la "$DATA" | head -26
echo '--- sanity ---'
for f in cmd_config.json data_v4.db plugins.json; do
    printf '  %-18s %s\n' "$f" "$( [ -f "$DATA/$f" ] && stat -c '%s bytes' "$DATA/$f" || echo MISSING )"
done
if [ ! -f "$DATA/cmd_config.json" ]; then
    echo "FATAL: migrated cmd_config.json missing, refusing to start" >&2
    exit 1
fi

echo
echo '########## COMPOSE ##########'
cat > "$ROOT/docker-compose.yml" <<EOS
services:
  astrbot:
    image: $IMAGE
    container_name: astrbot
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - $DATA:/AstrBot/data
      - /etc/localtime:/etc/localtime:ro
    ports:
      # Bound to loopback on purpose: the WebUI is published through nginx with an
      # IP allowlist, never exposed to the internet directly.
      - "127.0.0.1:6185:6185"
      # aiocqhttp (OneBot v11) reverse-WS endpoint: a platform adapter (NapCat)
      # connects IN to this port from the same host.
      - "127.0.0.1:6199:6199"
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
sleep 25
echo "container: $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' astrbot 2>&1)"
echo "ports:     $(docker port astrbot 2>&1 | tr '\n' ' ')"
echo
echo '--- logs (tail 45) ---'
docker logs --tail 45 astrbot 2>&1

echo
echo 'deploy-astrbot complete'
