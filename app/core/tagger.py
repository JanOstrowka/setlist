from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

from mutagen.mp4 import MP4, MP4Cover

from ..models import MetadataFields


def write_tags(
    m4a_path: Path | str,
    meta: MetadataFields,
    cover_jpeg: bytes | None = None,
    track: tuple[int, int] = (1, 1),
    disc: tuple[int, int] = (1, 1),
) -> None:
    """Write Apple-Music-friendly MP4 atoms (+ JPEG cover) to an existing .m4a.

    aART (Album Artist) + ©alb (Album) drive Apple Music album grouping; pgap=1
    keeps continuous mixes gapless. If mutagen fails to embed the cover, fall
    back to AtomicParsley.
    """
    path = Path(m4a_path)
    audio = MP4(str(path))
    audio["\xa9nam"] = [meta.title]
    audio["\xa9ART"] = [meta.artist]
    audio["\xa9alb"] = [meta.album]
    audio["aART"] = [meta.album_artist or meta.artist]
    if meta.year:
        audio["\xa9day"] = [str(meta.year)]
    if meta.genre:
        audio["\xa9gen"] = [meta.genre]
    if meta.comment:
        audio["\xa9cmt"] = [meta.comment]
    audio["trkn"] = [track]
    audio["disk"] = [disc]
    audio["cpil"] = bool(meta.compilation)
    audio["pgap"] = True
    if cover_jpeg:
        audio["covr"] = [MP4Cover(cover_jpeg, imageformat=MP4Cover.FORMAT_JPEG)]

    try:
        audio.save()
    except Exception:
        if not cover_jpeg:
            raise
        # Retry without the cover via mutagen, then embed the cover with AtomicParsley.
        audio.pop("covr", None)
        audio.save()
        _embed_cover_atomicparsley(path, cover_jpeg)


def _embed_cover_atomicparsley(path: Path, cover_jpeg: bytes) -> None:
    atomic = shutil.which("AtomicParsley")
    if not atomic:
        raise RuntimeError(
            "Cover embed failed via mutagen and AtomicParsley is not installed "
            "(install with: brew install atomicparsley)"
        )
    tmp = Path(tempfile.gettempdir()) / f"setlist-cover-{path.stem}.jpg"
    tmp.write_bytes(cover_jpeg)
    try:
        proc = subprocess.run(
            [atomic, str(path), "--artwork", str(tmp), "--overWrite"],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"AtomicParsley failed: {proc.stderr.strip()[-200:]}")
    finally:
        tmp.unlink(missing_ok=True)
