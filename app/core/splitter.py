from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Callable, Optional

from mutagen.mp4 import MP4

from ..models import Track
from . import library
from .job_state import CancellationToken


def _probe_duration(path: Path | str) -> float:
    return float(MP4(str(path)).info.length)


def compute_end_times(tracks: list[Track], total_duration: float) -> list[Track]:
    """Return tracks sorted by start with `end` filled: end = next start;
    the last track's end is the file end (total_duration)."""
    ordered = sorted(tracks, key=lambda t: (t.start if t.start is not None else 0.0))
    result: list[Track] = []
    for i, t in enumerate(ordered):
        end = ordered[i + 1].start if i + 1 < len(ordered) else total_duration
        result.append(t.model_copy(update={"end": float(end)}))
    return result


def _cut(full: Path, start: float, end: float, dest: Path) -> None:
    """Lossless stream-copy cut of [start, end). Both -ss and -to are input
    options (before -i), so -to is an absolute position in the input timeline."""
    cmd = [
        "ffmpeg", "-y",
        "-ss", f"{start:.3f}",
        "-to", f"{end:.3f}",
        "-i", str(full),
        "-c", "copy", "-map", "0:a",
        "-movflags", "+faststart",
        str(dest),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg split failed: {proc.stderr.strip()[-300:]}")


def split_file(
    full: Path | str,
    tracks: list[Track],
    out_dir: Path | str,
    total_duration: Optional[float] = None,
    on_track: Optional[Callable[[int, int, str], None]] = None,
    cancellation: CancellationToken | None = None,
) -> list[Path]:
    """Cut `full` into per-track .m4a files in `out_dir` named 'NN - Title.m4a'.

    `on_track(index, total, title)` (1-based) reports per-track progress.
    Raises ValueError if any track is missing a start time.
    """
    if any(t.start is None for t in tracks):
        raise ValueError("Every track needs a start time before splitting")
    full = Path(full)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    if total_duration is None:
        total_duration = _probe_duration(full)

    timed = compute_end_times(tracks, total_duration)
    files: list[Path] = []
    total = len(timed)
    for i, t in enumerate(timed, start=1):
        dest = out / library.track_filename(i, t.title)
        if cancellation:
            cancellation.raise_if_cancelled()
        _cut(full, float(t.start), float(t.end), dest)
        files.append(dest)
        if on_track:
            on_track(i, total, t.title)
    return files
