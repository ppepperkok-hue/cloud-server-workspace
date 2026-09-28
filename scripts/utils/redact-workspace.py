#!/usr/bin/env python3
"""redact-workspace.py - replace real infrastructure / personal values with placeholders.

The public repo must not carry the operator's IP, the test host's address, QQ numbers,
character names or panel secrets. The real values live in secrets/redaction-map.json
(gitignored); this script rewrites the committed tree to use the placeholders instead.

Usage:
  python3 redact-workspace.py --check     # report only, change nothing
  python3 redact-workspace.py --apply     # rewrite files in place

Scope: docs/, scripts/, state/, configs/, infrastructure/, templates/, *.md at the root.
Never touches .git/, secrets/, logs/, tmp/ (those are gitignored or not ours to rewrite).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAP_PATH = ROOT / "secrets" / "redaction-map.json"

SKIP_PARTS = {".git", "secrets", "logs", "tmp", "node_modules", "__pycache__", ".venv"}
INCLUDE_SUFFIX = {".md", ".sh", ".ps1", ".py", ".txt", ".yml", ".yaml", ".json", ".cfg", ".conf"}
SELF = Path(__file__).resolve()


def iter_files():
    for path in sorted(ROOT.rglob("*")):
        if not path.is_file():
            continue
        if set(path.relative_to(ROOT).parts) & SKIP_PARTS:
            continue
        if path.resolve() == SELF:
            continue
        if path.suffix.lower() not in INCLUDE_SUFFIX:
            continue
        yield path


def main() -> int:
    apply = "--apply" in sys.argv
    if not MAP_PATH.is_file():
        print(f"FATAL: mapping not found: {MAP_PATH}")
        return 1
    mapping = json.loads(MAP_PATH.read_text(encoding="utf-8"))["replacements"]

    # Longest key first, so a fully-qualified hostname is replaced before any shorter
    # prefix of it, and the full key fingerprint before the bare hex digest.
    ordered = sorted(mapping.items(), key=lambda kv: -len(kv[0]))

    total_hits = 0
    touched: list[tuple[str, int]] = []

    for path in iter_files():
        original = path.read_text(encoding="utf-8", errors="surrogateescape")
        text = original
        hits = 0
        for real, token in ordered:
            n = text.count(real)
            if n:
                hits += n
                text = text.replace(real, token)
        if hits:
            touched.append((str(path.relative_to(ROOT)), hits))
            total_hits += hits
            if apply:
                path.write_text(text, encoding="utf-8", errors="surrogateescape")

    mode = "APPLIED" if apply else "CHECK ONLY"
    print(f"== redact-workspace ({mode}) ==")
    for rel, n in touched:
        print(f"  {n:4d}  {rel}")
    print(f"  ---- total replacements: {total_hits} in {len(touched)} files")

    if not apply:
        print("\n  run with --apply to rewrite")

    # Verify nothing sensitive is left when applying.
    if apply:
        leftovers = []
        for path in iter_files():
            text = path.read_text(encoding="utf-8", errors="surrogateescape")
            for real, _ in ordered:
                if real in text:
                    leftovers.append((str(path.relative_to(ROOT)), real))
        if leftovers:
            print("\n  LEFTOVERS (should be empty):")
            for rel, real in leftovers[:20]:
                print(f"    {rel}: {real}")
            return 1
        print("  verification: no mapped literal remains in the committed tree")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
