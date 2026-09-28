#!/usr/bin/env bash
# astrbot-fix-config.sh - de-Windows an AstrBot data dir after migrating it from Windows.
#
# Does two things the container cannot survive without:
#   1. strips UTF-8 BOM from JSON/conf files (Windows editors add it; strict parsers choke)
#   2. clears http_proxy / no_proxy (the source machine's local Clash/SOCKS proxy does not
#      exist inside the container, and every pip install + outbound call fails while it is set)
#
# Usage: bash astrbot-fix-config.sh [data_dir] [compose_dir]
#   data_dir    default /opt/astrbot/data
#   compose_dir default /opt/astrbot   (must contain docker-compose.yml; skipped if absent)
#
# Idempotent: re-running finds no BOM and an already-empty proxy.
# Rollback: the previous cmd_config.json is left as cmd_config.json.pre-migration-fix.

set -uo pipefail

DATA="${1:-/opt/astrbot/data}"
COMPOSE_DIR="${2:-/opt/astrbot}"

[ -d "$DATA" ] || { echo "FATAL: data dir not found: $DATA" >&2; exit 1; }

if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    echo '########## STOP ##########'
    ( cd "$COMPOSE_DIR" && docker compose stop 2>&1 | tail -3 )
fi

echo
echo '########## STRIP UTF-8 BOM ##########'
DATA="$DATA" python3 - <<'PY'
import os

D = os.environ['DATA']
fixed = 0
for root, dirs, files in os.walk(D):
    if root[len(D):].count(os.sep) > 3:
        dirs[:] = []
        continue
    for name in files:
        if not name.endswith(('.json', '.pl', '.txt', '.yaml', '.yml', '.conf')):
            continue
        path = os.path.join(root, name)
        try:
            with open(path, 'rb') as fh:
                blob = fh.read()
            if blob[:3] == b'\xef\xbb\xbf':
                with open(path, 'wb') as fh:
                    fh.write(blob[3:])
                fixed += 1
        except OSError:
            pass
print(f'  BOM stripped from {fixed} files')
PY

echo
echo '########## CLEAR SOURCE-MACHINE PROXY ##########'
DATA="$DATA" python3 - <<'PY'
import json
import os
import shutil

path = os.path.join(os.environ['DATA'], 'cmd_config.json')
if not os.path.exists(path):
    print('  cmd_config.json absent - skipping (nothing to fix yet)')
    raise SystemExit(0)

with open(path, encoding='utf-8-sig') as fh:
    cfg = json.load(fh)

before = cfg.get('http_proxy')
shutil.copy2(path, path + '.pre-migration-fix')
cfg['http_proxy'] = ''
cfg['no_proxy'] = ['localhost', '127.0.0.1', '::1', '10.*', '192.168.*']
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(cfg, fh, ensure_ascii=False, indent=2)

print(f'  http_proxy: {before!r} -> {cfg["http_proxy"]!r}')
print(f'  pypi_index_url kept: {cfg.get("pypi_index_url")!r}')
print(f'  providers={len(cfg.get("provider", []))} platforms={len(cfg.get("platform", []))}')
print(f'  dashboard user={cfg.get("dashboard", {}).get("username")!r}')
PY

if [ -f "$COMPOSE_DIR/docker-compose.yml" ]; then
    echo
    echo '########## START ##########'
    ( cd "$COMPOSE_DIR" && docker compose start 2>&1 | tail -3 )
    echo "  (plugin dependency installs will now succeed; watch with: docker logs -f astrbot)"
fi

echo
echo 'astrbot-fix-config complete'
