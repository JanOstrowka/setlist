"""Keeps the encoded full-length master of recent sets.

Running a set again with a corrected tracklist or fixed tags only needs the
split and tag stages; the download and the encode are the slow, unchanged
part. The master is kept per (video, format) under a size budget, oldest
use evicted first. Everything here is best effort: a cache problem must
never fail a job, so errors are swallowed and reported as a miss.
"""
from __future__ import annotations

import os
import re
import shutil
from dataclasses import dataclass
from pathlib import Path

_SAFE = re.compile(r"[^A-Za-z0-9_-]")


@dataclass(frozen=True)
class MasterCache:
    root: Path
    max_bytes: int

    @property
    def enabled(self) -> bool:
        return self.max_bytes > 0

    def path_for(self, video_id: str, fmt: str) -> Path:
        """Where the master for this video and format lives. The YouTube id
        charset is letters, digits, `-` and `_`; anything else is dropped so
        the name can never leave the cache folder."""
        safe_id = _SAFE.sub("", video_id or "") or "unknown"
        safe_fmt = _SAFE.sub("", fmt or "") or "unknown"
        return self.root / f"{safe_id}.{safe_fmt}.m4a"

    def lookup(self, video_id: str, fmt: str) -> Path | None:
        """The cached master, or None. A hit is touched so it stays recent."""
        if not self.enabled:
            return None
        path = self.path_for(video_id, fmt)
        try:
            if not path.is_file() or path.stat().st_size == 0:
                return None
            os.utime(path, None)
        except OSError:
            return None
        return path

    def store(self, source: Path, video_id: str, fmt: str) -> Path | None:
        """Copies `source` into the cache and prunes to budget. Returns the
        cached path, or None when the cache is off, the file does not fit,
        or the copy failed."""
        if not self.enabled:
            return None
        try:
            size = Path(source).stat().st_size
            if size == 0 or size > self.max_bytes:
                return None
            self.root.mkdir(parents=True, exist_ok=True)
            target = self.path_for(video_id, fmt)
            partial = target.with_name(target.name + ".part")
            shutil.copy2(source, partial)
            os.replace(partial, target)
            os.utime(target, None)
            self.prune()
        except OSError:
            return None
        return target

    def prune(self) -> None:
        """Evicts least recently used masters until the folder fits the budget."""
        try:
            entries = []
            for path in self.root.iterdir():
                if path.suffix != ".m4a" or not path.is_file():
                    if path.suffix == ".part":
                        path.unlink(missing_ok=True)
                    continue
                stat = path.stat()
                entries.append((stat.st_mtime, stat.st_size, path))
        except OSError:
            return
        total = sum(size for _, size, _ in entries)
        for _, size, path in sorted(entries):
            if total <= self.max_bytes:
                break
            try:
                path.unlink()
                total -= size
            except OSError:
                continue
