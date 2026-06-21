from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

_ILLEGAL = {"/": "-", ":": "-"}
_RECENT_FILE = ".setlist-recent.json"
_RECENT_CAP = 20


def sanitize_filename(name: str) -> str:
    """Make a string safe + readable as a single macOS/APFS path component."""
    cleaned = name or ""
    for bad, good in _ILLEGAL.items():
        cleaned = cleaned.replace(bad, good)
    cleaned = re.sub(r"[\x00-\x1f]", "", cleaned)        # strip control chars
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip()    # collapse whitespace
    cleaned = cleaned.strip(" .")                        # no leading/trailing dots or spaces
    return cleaned or "untitled"


def ensure_output_dir(output_dir: Path | str) -> Path:
    path = Path(output_dir).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    return path


def set_output_dir(
    output_dir: Path | str,
    album_artist: str,
    artist: str,
    album: str,
    title: str,
) -> Path:
    """Folder for one set/album: OUTPUT_DIR/<Artist>/<Set>/.

    Artist = Album Artist (fallback Artist); Set = Album (fallback Title).
    """
    artist_name = sanitize_filename(album_artist or artist or "Unknown Artist")
    set_name = sanitize_filename(album or title or "Untitled")
    return Path(output_dir).expanduser() / artist_name / set_name


def single_track_path(
    output_dir: Path | str,
    album_artist: str,
    artist: str,
    album: str,
    title: str,
) -> Path:
    """v1 single track destination: OUTPUT_DIR/<Artist>/<Set>/<Title>.m4a."""
    set_dir = set_output_dir(output_dir, album_artist, artist, album, title)
    return set_dir / f"{sanitize_filename(title or 'Untitled')}.m4a"


def track_filename(index: int, title: str) -> str:
    """v2 per-track filename inside the set folder: 'NN - Title.m4a'."""
    return f"{index:02d} - {sanitize_filename(title or 'Untitled')}.m4a"


def write_cover(set_dir: Path | str, cover_jpeg: bytes | None) -> Path | None:
    """Write a standalone cover.jpg into the set folder (for Apple Music playlist
    artwork). No-op when there is no cover; never raises on a missing cover."""
    if not cover_jpeg:
        return None
    folder = ensure_output_dir(set_dir)
    path = folder / "cover.jpg"
    path.write_bytes(cover_jpeg)
    return path


def save(temp_file: Path | str, dest: Path | str) -> Path:
    dest_path = Path(dest)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(temp_file), str(dest_path))
    return dest_path


def _recent_path(output_dir: Path | str) -> Path:
    return Path(output_dir).expanduser() / _RECENT_FILE


def load_recent(output_dir: Path | str) -> list[dict]:
    path = _recent_path(output_dir)
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, list) else []
    except (ValueError, OSError):
        return []


def record_recent(output_dir: Path | str, entry: dict, cap: int = _RECENT_CAP) -> None:
    items = [e for e in load_recent(output_dir) if e.get("path") != entry.get("path")]
    items.insert(0, entry)
    ensure_output_dir(output_dir)
    _recent_path(output_dir).write_text(json.dumps(items[:cap], indent=2))
