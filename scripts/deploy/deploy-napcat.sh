#!/usr/bin/env bash
# deploy-napcat.sh - add NapCat (OneBot v11 adapter for QQ) next to AstrBot.
#
# One container per QQ account: NapCat logs in exactly one QQ number per instance,
# so the two accounts that ran locally get two containers (napcat1 / napcat2).
# MODE=astrbot makes NapCat auto-configure its reverse-WebSocket client toward the
# AstrBot container on ws://astrbot:6199/ws.
#
# Usage: bash deploy-napcat.sh
# Rollback: cd /opt/astrbot && docker compose down   (NapCat dirs stay on disk under napcat1/ napcat2/)

set -uo pipefail
ROOT=/opt/astrbot
ASTRBOT_IMG=m.daocloud.io/docker.io/soulter/astrbot:v4.28.1
NAPCAT_IMG=m.daocloud.io/docker.io/mlikiowa/napcat-docker:latest

mkdir -p "$ROOT"

echo '########## BACKUP EXISTING COMPOSE ##########'
if [ -f "$ROOT/docker-compose.yml" ]; then
    cp -a "$ROOT/docker-compose.yml" "$ROOT/docker-compose.yml.$(date +%Y%m%d-%H%M%S).bak"
    echo "  backed up"
fi

echo
echo '########## PREPARE NAPCAT DIRS ##########'
for i in 1 2; do
    mkdir -p "$ROOT/napcat$i/config" "$ROOT/napcat$i/ntqq"
done
chown -R root:root "$ROOT"/napcat1 "$ROOT"/napcat2 2>/dev/null || true
ls -ld "$ROOT"/napcat1 "$ROOT"/napcat1/config "$ROOT"/napcat2 "$ROOT"/napcat2/config

echo
echo '########## WRITE COMPOSE ##########'
cat > "$ROOT/docker-compose.yml" <<EOS
services:
  astrbot:
    image: $ASTRBOT_IMG
    container_name: astrbot
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
    volumes:
      - $ROOT/data:/AstrBot/data
      - /etc/localtime:/etc/localtime:ro
    ports:
      # Bound to loopback on purpose: the WebUI is published through nginx with an
      # IP allowlist, never exposed to the internet directly.
      - "127.0.0.1:6185:6185"
      # aiocqhttp (OneBot v11) reverse-WS endpoint; NapCat connects IN from this network.
      - "127.0.0.1:6199:6199"
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"

  # ---- QQ adapters: one container per QQ account ----
  napcat1:
    image: $NAPCAT_IMG
    container_name: napcat1
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
      - MODE=astrbot
      - NAPCAT_UID=0
      - NAPCAT_GID=0
    # Stable MAC keeps the fake device fingerprint from changing between restarts.
    mac_address: "02:42:ac:11:00:02"
    volumes:
      - $ROOT/data:/AstrBot/data
      - $ROOT/napcat1/config:/app/napcat/config
      - $ROOT/napcat1/ntqq:/app/.config/QQ
    ports:
      # NapCat WebUI (QR login lives here) - loopback only.
      - "127.0.0.1:6099:6099"
    depends_on:
      - astrbot
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"

  napcat2:
    image: $NAPCAT_IMG
    container_name: napcat2
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
      - MODE=astrbot
      - NAPCAT_UID=0
      - NAPCAT_GID=0
    mac_address: "02:42:ac:11:00:03"
    volumes:
      - $ROOT/data:/AstrBot/data
      - $ROOT/napcat2/config:/app/napcat/config
      - $ROOT/napcat2/ntqq:/app/.config/QQ
    ports:
      - "127.0.0.1:6100:6099"
    depends_on:
      - astrbot
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
docker compose up -d 2>&1 | tail -12
sleep 25

echo
echo '########## STATE ##########'
docker ps --format '{{.Names}} | {{.Status}} | {{.Ports}}' | sed 's/^/  /'

echo
echo '########## NAPCAT1 LOG (QR / WebUI link lives here) ##########'
docker logs napcat1 2>&1 | tail -40

echo
echo '########## NAPCAT2 LOG (tail) ##########'
docker logs napcat2 2>&1 | tail -15

echo
echo 'deploy-napcat complete'
