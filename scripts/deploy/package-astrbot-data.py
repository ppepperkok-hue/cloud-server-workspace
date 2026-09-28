"""package-astrbot-data.py - stage a migration-ready copy of the live AstrBot data dir.

- Skips caches / backups / pip site-packages / *.bak that must not travel.
- Takes a CONSISTENT SQLite snapshot of every .db via the online backup API,
  so the copy is safe while AstrBot is still running (no downtime needed).
"""

import os
import shutil
import sqlite3
import sys
from pathlib import Path

SRC = Path(sys.argv[1])
DST = Path(sys.argv[2])

EXCL_DIRS = {
    "backups", "temp", "temp.bak", "plugins.bak", "plugin_data.bak",
    "config.bak", "t2i_templates.bak", "logs", "site-packages",
    "sowing_discord_cache",
}
EXCL_SUFFIX = (".db-shm", ".db-wal", ".bak", ".log")


def main() -> int:
    if not SRC.is_dir():
        print(f"FATAL: source not found: {SRC}")
        return 1
    if DST.exists():
        shutil.rmtree(DST)
    DST.mkdir(parents=True, exist_ok=True)

    copied = 0
    skipped = 0
    db_jobs = []
    failed = []

    for root, dirs, files in os.walk(SRC):
        dirs[:] = [d for d in dirs if d not in EXCL_DIRS]
        rel = os.path.relpath(root, SRC)
        target = DST if rel == "." else DST / rel
        target.mkdir(parents=True, exist_ok=True)
        for name in files:
            src_file = Path(root) / name
            if name.endswith(EXCL_SUFFIX):
                skipped += 1
                continue
            dst_file = target / name
            if name.endswith(".db"):
                db_jobs.append((src_file, dst_file))
                continue
            try:
                shutil.copy2(src_file, dst_file)
                copied += 1
            except Exception as exc:  # noqa: BLE001
                failed.append((str(src_file), str(exc)))

    ok_db = 0
    for src_file, dst_file in db_jobs:
        dst_file.parent.mkdir(parents=True, exist_ok=True)
        try:
            sc = sqlite3.connect(src_file.as_uri() + "?mode=ro", uri=True)
            dc = sqlite3.connect(str(dst_file))
            with dc:
                sc.backup(dc)
            dc.close()
            sc.close()
            ok_db += 1
        except Exception as exc:  # noqa: BLE001
            failed.append((str(src_file), f"sqlite backup: {exc}"))

    total = sum(f.stat().st_size for f in DST.rglob("*") if f.is_file())
    print(f"files copied      : {copied}")
    print(f"db snapshotted    : {ok_db}/{len(db_jobs)}")
    print(f"skipped (excluded): {skipped}")
    print(f"staged bytes      : {total} ({total / 1024 / 1024:.1f} MB)")
    if failed:
        print(f"FAILURES ({len(failed)}):")
        for path, err in failed[:20]:
            print(f"  {path} -> {err}")
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
