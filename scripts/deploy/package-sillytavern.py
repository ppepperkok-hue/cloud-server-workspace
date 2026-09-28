"""package-sillytavern.py - stage a migration-ready copy of a Windows SillyTavern install.

Takes only what is USER data:
  config.yaml                      -> config/
  data/default-user, cookie-secret -> data/
  public/.../third-party/*         -> extensions/third-party/
and skips the app itself, node_modules, caches and logs (the image supplies those).
"""

import os
import shutil
import sys
from pathlib import Path

SKIP_DATA_DIRS = {"_webpack", "_cache", "_errors", "_css", "_storage", "_uploads"}
SKIP_DATA_FILES = {"access.log", "content.log"}


def copy_tree(src: Path, dst: Path) -> int:
    n = 0
    for root, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if d not in SKIP_DATA_DIRS]
        rel = os.path.relpath(root, src)
        target = dst if rel == "." else dst / rel
        target.mkdir(parents=True, exist_ok=True)
        for name in files:
            if name in SKIP_DATA_FILES:
                continue
            try:
                shutil.copy2(Path(root) / name, target / name)
                n += 1
            except OSError as exc:
                print(f"  WARN copy failed: {Path(root) / name}: {exc}")
    return n


def main() -> int:
    st = Path(sys.argv[1])
    out = Path(sys.argv[2])

    if not (st / "config.yaml").is_file():
        print(f"FATAL: {st}/config.yaml not found")
        return 1
    if out.exists():
        shutil.rmtree(out)
    (out / "config").mkdir(parents=True)
    (out / "data").mkdir(parents=True)
    (out / "extensions" / "third-party").mkdir(parents=True)
    (out / "plugins").mkdir(parents=True)

    shutil.copy2(st / "config.yaml", out / "config" / "config.yaml")
    print("  config.yaml -> config/config.yaml")

    n_data = copy_tree(st / "data", out / "data")
    print(f"  data: {n_data} files")

    tp = st / "public" / "scripts" / "extensions" / "third-party"
    n_ext = 0
    if tp.is_dir():
        for d in sorted(tp.iterdir()):
            if d.is_dir() and d.name != "node_modules":
                n = copy_tree(d, out / "extensions" / "third-party" / d.name)
                n_ext += n
                print(f"  extension {d.name}: {n} files")
    print(f"  extensions total: {n_ext} files")

    total = sum(f.stat().st_size for f in out.rglob("*") if f.is_file())
    print(f"  staged: {total / 1024 / 1024:.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
