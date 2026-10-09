#!/usr/bin/env bash
# set-astrbot-pip-mirror.sh — point AstrBot's plugin-dependency installs (and any
# pip/uv run inside its container) at the Tencent Cloud mirror.
#
# WHY
#   AstrBot ships with `pypi_index_url = https://mirrors.aliyun.com/pypi/simple/`
#   (astrbot/core/config/default.py) and passes it to pip as `-i <url>`
#   (astrbot/core/utils/pip_installer.py:1008-1012). From a Tencent Cloud CVM the
#   Tencent mirror resolves to 169.254.0.3, i.e. the internal network.
#   Measured INSIDE the container on 2026-10-09 (16.7 MB numpy wheel, --no-deps):
#       aliyun                     280 500 ms   (~60 kB/s)
#       mirrors.tencentyun.com       1 144 ms   (http, internal)
#       mirrors.cloud.tencent.com    1 296 ms   (https, also internal)
#   ~215x. That gap is why rebuilding the container re-installed dependencies for
#   tens of minutes even with the image already local (KNOWN-ISSUES #23).
#
# WHAT IT CHANGES (idempotent, backs everything up, prints the rollback)
#   1. /opt/astrbot/data/cmd_config.json  -> pypi_index_url = $INDEX_URL
#      Bind-mounted, so it survives `docker compose up -d`. This is the setting
#      that actually governs plugin installs.
#   2. /opt/astrbot/docker-compose.yml    -> env + persisted pip/uv caches, so a
#      future rebuild both downloads fast and reuses the 122 MB wheel cache that
#      currently dies with the container. Takes effect on the NEXT rebuild only.
#   3. Restarts the container with `docker start`, never `up -d`: recreating it
#      would throw away every plugin dependency (that is #23 itself).
#
# USAGE
#   set-astrbot-pip-mirror.sh [index-url]
#   Default index: https://mirrors.cloud.tencent.com/pypi/simple/
#
# ROLLBACK
#   Printed at the end (files are copied to /root/backups/astrbot-pip-<stamp>/).

set -euo pipefail

INDEX_URL="${1:-https://mirrors.cloud.tencent.com/pypi/simple/}"
COMPOSE_DIR=/opt/astrbot
COMPOSE="$COMPOSE_DIR/docker-compose.yml"
CFG="$COMPOSE_DIR/data/cmd_config.json"
CONTAINER=astrbot
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/backups/astrbot-pip-$STAMP"
PIP_CACHE=/opt/astrbot/pip-cache
UV_CACHE=/opt/astrbot/uv-cache

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$COMPOSE" ] || die "not found: $COMPOSE"
[ -f "$CFG" ]     || die "not found: $CFG"
command -v docker >/dev/null || die "docker not found"

say "=== backup ==="
mkdir -p "$BACKUP_DIR"
cp -a "$COMPOSE" "$BACKUP_DIR/docker-compose.yml"
cp -a "$CFG"     "$BACKUP_DIR/cmd_config.json"
say "  $BACKUP_DIR/docker-compose.yml"
say "  $BACKUP_DIR/cmd_config.json"

# ---------------------------------------------------------------- compose ----
# Insert only inside the `astrbot:` service block, never into the napcat ones.
say
say "=== docker-compose.yml ==="
python3 - "$COMPOSE" "$INDEX_URL" "$PIP_CACHE" "$UV_CACHE" <<'PY'
import re, sys

path, index_url, pip_cache, uv_cache = sys.argv[1:5]
lines = open(path, encoding="utf-8").read().split("\n")

# Locate the astrbot service block: from the line "  astrbot:" up to the next
# "  <name>:" at the same indent level.
start = next((i for i, l in enumerate(lines) if l.rstrip() == "  astrbot:"), None)
if start is None:
    sys.exit("could not find the '  astrbot:' service block")
end = next((i for i in range(start + 1, len(lines))
            if re.match(r"^  \S.*:\s*$", lines[i])), len(lines))

env_lines = [
    f"      - PIP_INDEX_URL={index_url}",
    "      - PIP_DISABLE_PIP_VERSION_CHECK=1",
    f"      - UV_DEFAULT_INDEX={index_url}",
]
vol_lines = [
    f"      - {pip_cache}:/root/.cache/pip",
    f"      - {uv_cache}:/root/.cache/uv",
]


def insert_after(anchor_prefix, new_lines, label):
    """Insert new_lines right after the first line starting with anchor_prefix."""
    idx = next((i for i in range(start, end) if lines[i].startswith(anchor_prefix)), None)
    if idx is None:
        sys.exit(f"anchor not found for {label}: {anchor_prefix!r}")
    have = [l for l in new_lines if l in lines[idx:end]]
    todo = [l for l in new_lines if l not in lines[idx:end]]
    if not todo:
        print(f"  {label}: already present, unchanged")
        return 0
    lines[idx + 1:idx + 1] = todo
    print(f"  {label}: added {len(todo)} line(s)")
    return 1


changed = 0
changed += insert_after("      - TZ=Asia/Shanghai", env_lines, "environment")
changed += insert_after("      - /etc/localtime:/etc/localtime:ro", vol_lines, "volumes")

if changed:
    open(path, "w", encoding="utf-8").write("\n".join(lines))
else:
    print("  compose unchanged")
PY

# caches live in bind mounts now, so they must exist on the host
mkdir -p "$PIP_CACHE" "$UV_CACHE"
say "  host cache dirs: $PIP_CACHE, $UV_CACHE"

say
say "=== validate compose ==="
( cd "$COMPOSE_DIR" && docker compose config >/dev/null ) && say "  docker compose config: OK"

# ------------------------------------------------------------- cmd_config ----
# AstrBot rewrites cmd_config.json from memory on shutdown, so this MUST happen
# while the container is stopped or the edit is silently lost.
say
say "=== stop container (JSON edit must not race AstrBot's own writes) ==="
docker stop "$CONTAINER" >/dev/null
say "  stopped"

# The 122 MB of wheels that plugin installs already downloaded live in the
# container's writable layer and are thrown away by the next recreate. Copy them
# onto the host now, so the bind mount above starts warm instead of empty.
say
say "=== seed the persistent pip/uv cache from the container's writable layer ==="
if [ ! -f "$PIP_CACHE/.seeded" ]; then
    if docker cp "$CONTAINER:/root/.cache/pip/." "$PIP_CACHE/" 2>/dev/null; then
        say "  pip cache -> $PIP_CACHE ($(du -sh "$PIP_CACHE" | cut -f1))"
    else
        say "  (no pip cache in the container to copy)"
    fi
    if docker cp "$CONTAINER:/root/.cache/uv/." "$UV_CACHE/" 2>/dev/null; then
        say "  uv cache -> $UV_CACHE ($(du -sh "$UV_CACHE" | cut -f1))"
    else
        say "  (no uv cache in the container to copy)"
    fi
    touch "$PIP_CACHE/.seeded" "$UV_CACHE/.seeded"
else
    say "  already seeded, skipped"
fi

say
say "=== cmd_config.json: pypi_index_url ==="
python3 - "$CFG" "$INDEX_URL" <<'PY'
import json, sys

path, index_url = sys.argv[1:3]
raw = open(path, encoding="utf-8").read()
cfg = json.loads(raw)
before = cfg.get("pypi_index_url")
if before == index_url:
    print(f"  already {index_url}")
    sys.exit(0)
cfg["pypi_index_url"] = index_url
# Same style AstrBot itself writes: indent 2, real UTF-8 (the file is full of CJK).
open(path, "w", encoding="utf-8").write(json.dumps(cfg, indent=2, ensure_ascii=False))
after = json.load(open(path, encoding="utf-8"))
assert after["pypi_index_url"] == index_url, "write did not stick"
removed = set(cfg) - set(after)
assert not removed, f"unexpected key loss: {removed}"
print(f"  {before!r} -> {after['pypi_index_url']!r}")
print(f"  top-level keys before/after: {len(cfg)}/{len(after)} (unchanged)")
PY

say
say "=== start container (start, NOT up -d: recreating loses plugin deps) ==="
docker start "$CONTAINER" >/dev/null
say "  started"

say
say "=== effective config inside the container ==="
docker exec "$CONTAINER" python3 -c "
import json
d = json.load(open('/AstrBot/data/cmd_config.json', encoding='utf-8'))
print('  pypi_index_url =', repr(d.get('pypi_index_url')))
"

cat <<ROLLBACK

=== rollback ===
docker stop $CONTAINER
cp -a $BACKUP_DIR/cmd_config.json   $CFG
cp -a $BACKUP_DIR/docker-compose.yml $COMPOSE
docker start $CONTAINER
# the compose env/cache lines only matter on a future 'docker compose up -d',
# so removing them from the file above is enough.
# backup dir: $BACKUP_DIR
ROLLBACK
