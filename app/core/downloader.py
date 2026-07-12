from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Callable, Optional

from yt_dlp import YoutubeDL


def download_audio(
    url: str,
    workdir: Path,
    on_progress: Callable[[float], None],
    pot_provider_url: Optional[str] = None,
    cookiefile: Optional[Path | str] = None,
) -> Path:
    """Download the best audio-only stream into workdir. Returns the source file path.

    on_progress receives a 0-100 float. No postprocessing: we encode separately so
    the file stays untagged until mutagen writes the user-confirmed atoms.
    cookiefile (Netscape cookies.txt) lets cloud workers pass a signed-in YouTube
    session when datacenter IPs hit bot checks.
    """
    state: dict[str, Optional[str]] = {"path": None}

    def hook(d: dict) -> None:
        status = d.get("status")
        if status == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate")
            done = d.get("downloaded_bytes") or 0
            if total:
                on_progress(min(99.0, done / total * 100.0))
        elif status == "finished":
            state["path"] = d.get("filename")
            on_progress(100.0)

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
    cmd = [
        "ffmpeg", "-y", "-i", str(src),
        *duration_args,
        "-vn", *codec_args, "-movflags", "+faststart",
        str(dest),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg encode failed: {proc.stderr.strip()[-300:]}")
