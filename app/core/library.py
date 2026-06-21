from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

_ILLEGAL = {"/": "-", ":": "-"}
_RECENT_FILE = ".setlist-recent.json"
_RECENT_CAP = 20


def sanitize_filename(name: str) -> str:
    cleaned = name or ""
    for bad, good in _ILLEGAL.items():
        cleaned = cleaned.replace(bad, good)
    cleaned = cleaned.replace("\x00", "")
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip()
    return cleaned or "untitled"


def ensure_output_dir(output_dir: Path | str) -> Path:
    path = Path(output_dir).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    return path


def output_path(output_dir: Path | str, album_artist: str, title: str, video_id: str) -> Path:
    filename = f"{sanitize_filename(album_artist or 'Unknown Artist')} - {sanitize_filename(title or 'Untitled')} [{video_id}].m4a"
    return Path(output_dir).expanduser() / filename


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
