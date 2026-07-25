from __future__ import annotations

import subprocess
import threading
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

from yt_dlp import YoutubeDL

from .job_state import CancellationToken, JobCancelled


@dataclass(frozen=True)
class DownloadProgress:
    pct: float
    downloaded_bytes: int | None = None
    total_bytes: int | None = None
    speed_bytes_per_second: float | None = None
    eta_seconds: float | None = None

    @classmethod
    def from_yt_dlp(cls, payload: dict) -> "DownloadProgress":
        total = payload.get("total_bytes") or payload.get("total_bytes_estimate")
        downloaded = payload.get("downloaded_bytes")
        pct = min(99.0, downloaded / total * 100.0) if downloaded and total else 0.0
        return cls(pct, downloaded, total, payload.get("speed"), payload.get("eta"))


def parse_ffmpeg_progress(line: str, duration_seconds: float) -> float | None:
    if not line.startswith("out_time_us=") or duration_seconds <= 0:
        return None
    microseconds = int(line.split("=", 1)[1])
    return min(99.0, microseconds / 1_000_000 / duration_seconds * 100.0)


def probe_duration(path: Path | str) -> float:
    proc = subprocess.run(
        [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return float(proc.stdout.strip())


def download_audio(
    url: str,
    workdir: Path,
    on_progress: Callable[[DownloadProgress], None],
    pot_provider_url: Optional[str] = None,
    cookiefile: Optional[Path | str] = None,
    cancellation: CancellationToken | None = None,
) -> Path:
    """Download the best audio-only stream into workdir. Returns the source file path.

    on_progress receives structured download progress. No postprocessing: we encode
    separately so the file stays untagged until mutagen writes the confirmed atoms.
    cookiefile (Netscape cookies.txt) lets cloud workers pass a signed-in YouTube
    session when datacenter IPs hit bot checks.
    """
    state: dict[str, Optional[str]] = {"path": None}

    def hook(d: dict) -> None:
        status = d.get("status")
        if status == "downloading":
            if cancellation:
                cancellation.raise_if_cancelled()
            on_progress(DownloadProgress.from_yt_dlp(d))
        elif status == "finished":
            state["path"] = d.get("filename")
            if cancellation:
                cancellation.raise_if_cancelled()
            progress = DownloadProgress.from_yt_dlp(d)
            on_progress(DownloadProgress(
                100.0,
                progress.downloaded_bytes,
                progress.total_bytes,
                progress.speed_bytes_per_second,
                progress.eta_seconds,
            ))

    opts: dict = {
        "format": "bestaudio/best",
        "outtmpl": str(workdir / "%(id)s.%(ext)s"),
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "progress_hooks": [hook],
    }
    if pot_provider_url:
        # Requires the bgutil PO-token provider plugin. Plugin >=1.0 (yt-dlp's
        # 2025 PO Token Provider framework) reads youtubepot-bgutilhttp:base_url;
        # the legacy youtube:getpot_bgutil_baseurl key keeps pre-1.0 plugins
        # working. Unknown extractor args are ignored, so passing both is safe.
        opts["extractor_args"] = {
            "youtubepot-bgutilhttp": {"base_url": [pot_provider_url]},
            "youtube": {"getpot_bgutil_baseurl": [pot_provider_url]},
        }
    if cookiefile:
        opts["cookiefile"] = str(cookiefile)

    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=True)
        if not state["path"]:
            state["path"] = ydl.prepare_filename(info)

    path = state["path"]
    if not path or not Path(path).exists():
        raise RuntimeError("Download finished but the audio file was not found")
    return Path(path)


def encode(
    src: Path | str,
    dest: Path | str,
    fmt: str,
    limit_seconds: Optional[float] = None,
    on_progress: Callable[[float], None] | None = None,
    cancellation: CancellationToken | None = None,
) -> None:
    """Transcode src to dest. fmt is 'alac' (lossless) or 'aac256'.

    limit_seconds caps the output duration (ffmpeg -t); used by the Modal spike
    to prove the pipeline without paying for a full-set encode.
    """
    if fmt == "aac256":
        codec_args = ["-c:a", "aac", "-b:a", "256k"]
    else:
        codec_args = ["-c:a", "alac"]
    duration_args = ["-t", str(limit_seconds)] if limit_seconds else []
    duration_seconds = probe_duration(src)
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error", "-i", str(src),
        *duration_args,
        "-vn", *codec_args, "-movflags", "+faststart",
        "-progress", "pipe:1", "-nostats",
        str(dest),
    ]
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None
    assert proc.stderr is not None

    stderr_tail: deque[str] = deque(maxlen=100)

    def drain_stderr() -> None:
        for line in proc.stderr:
            stderr_tail.append(line)

    stderr_thread = threading.Thread(target=drain_stderr, daemon=True)
    stderr_thread.start()

    try:
        if cancellation:
            cancellation.raise_if_cancelled()
        for raw_line in proc.stdout:
            if cancellation:
                cancellation.raise_if_cancelled()
            pct = parse_ffmpeg_progress(raw_line.strip(), duration_seconds)
            if pct is not None and on_progress:
                on_progress(pct)
            if cancellation:
                cancellation.raise_if_cancelled()
        if cancellation:
            cancellation.raise_if_cancelled()
    except JobCancelled:
        proc.terminate()
        proc.wait()
        stderr_thread.join()
        raise

    returncode = proc.wait()
    stderr_thread.join()
    if returncode != 0:
        error = "".join(stderr_tail).strip()
        raise RuntimeError(f"ffmpeg encode failed: {error[-300:]}")
    if on_progress:
        on_progress(100.0)
