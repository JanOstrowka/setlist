#!/usr/bin/env python3
"""Sync the assets shared between the local UI (web/) and the hosted site (site/).

web/app.js and web/styles.css are the single source of truth; the copies in
site/ are committed so the site deploys as plain static files with no build
step on Vercel. Run this after editing either shared file; tests/test_site.py
fails the suite if the copies drift.
"""
from __future__ import annotations

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SHARED = ["app.js", "styles.css"]


def sync(check: bool = False) -> int:
    stale = []
    for name in SHARED:
        src = ROOT / "web" / name
        dst = ROOT / "site" / name
        if not dst.exists() or dst.read_bytes() != src.read_bytes():
            stale.append(name)
            if not check:
                shutil.copyfile(src, dst)
    if check and stale:
        print(f"site/ copies out of date: {', '.join(stale)} — run scripts/build_site.py")
        return 1
    if not check:
        print(f"synced {', '.join(SHARED)} -> site/")
    return 0


if __name__ == "__main__":
    sys.exit(sync(check="--check" in sys.argv))
