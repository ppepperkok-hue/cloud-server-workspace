"""st-patch-config.py - adjust a migrated SillyTavern config.yaml for container + proxy use.

Two changes, both idempotent:
  1. add the private ranges (172.16.0.0/12) to `whitelist`
     -- requests reach the container from the docker bridge gateway, never from
        127.0.0.1, so without this SillyTavern answers 403 to everything.
  2. set `heartbeatInterval: 30` so the docker healthcheck can work.

The previous file is kept as config.yaml.pre-migration on the first run.

Usage: python3 st-patch-config.py /opt/sillytavern/config/config.yaml
"""

import re
import shutil
import sys
from pathlib import Path

WANT_ENTRY = "172.16.0.0/12"


def whitelist_block(text: str):
    """Return (start, end, body) of the entries list that follows `whitelist:`."""
    m = re.search(r"(?m)^whitelist:[ \t]*\n((?:[ \t]*-[^\n]*\n)+)", text)
    if not m:
        return None
    return m.start(1), m.end(1), m.group(1)


def main() -> int:
    path = Path(sys.argv[1] if len(sys.argv) > 1 else "/opt/sillytavern/config/config.yaml")
    if not path.is_file():
        print(f"FATAL: {path} not found")
        return 1
    if not (path.parent / (path.name + ".pre-migration")).exists():
        shutil.copy2(path, str(path) + ".pre-migration")

    text = path.read_text(encoding="utf-8")

    # -- 1. whitelist ------------------------------------------------------
    # Drop any previously added copy first (it may carry the wrong indentation,
    # in which case YAML nests it as a sub-list of the previous entry and the
    # address is silently NOT whitelisted).
    text = re.sub(r"(?m)^[ \t]*-[ \t]*" + re.escape(WANT_ENTRY) + r"[ \t]*\n", "", text)

    block = whitelist_block(text)
    if not block:
        print("FATAL: could not locate the whitelist list in config.yaml")
        return 1
    start, end, body = block
    indent = re.match(r"([ \t]*)", body).group(1)
    new_body = body.rstrip("\n") + f"\n{indent}- {WANT_ENTRY}\n"
    text = text[:start] + new_body + text[end:]

    # -- 2. heartbeat ------------------------------------------------------
    text = re.sub(r"(?m)^heartbeatInterval:.*$", "heartbeatInterval: 30", text, count=1)

    path.write_text(text, encoding="utf-8")

    # -- report ------------------------------------------------------------
    _, _, final = whitelist_block(text)
    print("  whitelist entries (raw repr, so indentation is visible):")
    for line in final.splitlines():
        print("   ", repr(line))
    for key in ("whitelistMode", "whitelistDockerHosts", "enableForwardedWhitelist",
                "basicAuthMode", "port", "listen", "heartbeatInterval"):
        m = re.search(rf"(?m)^{key}:.*$", text)
        if m:
            print(f"  {m.group(0).strip()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
