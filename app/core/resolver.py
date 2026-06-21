from __future__ import annotations

import base64
import tempfile
from dataclasses import dataclass, field
from io import BytesIO
from pathlib import Path

import httpx
from PIL import Image
from yt_dlp import YoutubeDL

_COVER_DIR = Path(tempfile.gettempdir()) / "setlist-covers"


@dataclass
class RawInfo:
    video_id: str
    url: str
    title: str
    description: str
    uploader: str
    upload_date: str  # "YYYYMMDD" or ""
    thumbnail: str
    duration: int
    has_chapters: bool
    best_audio_label: str
    formats_summary: str
    chapters: list[dict] = field(default_factory=list)


def _best_audio(formats: list[dict]) -> dict | None:
    audio_only = [
        f for f in formats
        if f.get("acodec") not in (None, "none") and f.get("vcodec") in (None, "none")
    ]
    candidates = audio_only or [f for f in formats if f.get("acodec") not in (None, "none")]
    if not candidates:
        return None
    return max(candidates, key=lambda f: (f.get("abr") or f.get("tbr") or 0))


def _best_audio_label(fmt: dict | None) -> str:
    if not fmt:
        return "unknown audio"
    parts = [str(fmt.get("format_id", "?"))]
    if fmt.get("acodec") and fmt["acodec"] != "none":
        parts.append(str(fmt["acodec"]))
    abr = fmt.get("abr") or fmt.get("tbr")
    if abr:
        parts.append(f"~{int(abr)} kbps")
    return " · ".join(parts)


def _formats_summary(fmt: dict | None) -> str:
    if not fmt:
        return "no audio-only stream detected"
    ext = fmt.get("ext", "?")
    return f"bestaudio {fmt.get('format_id', '?')} ({ext})"


def resolve(url: str) -> RawInfo:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
    }
    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)
    formats = info.get("formats") or []
    best = _best_audio(formats)
    return RawInfo(
        video_id=info.get("id", "") or "",
        url=info.get("webpage_url") or url,
        title=info.get("title", "") or "",
        description=info.get("description", "") or "",
        uploader=info.get("uploader") or info.get("channel") or "",
        upload_date=info.get("upload_date", "") or "",
        thumbnail=info.get("thumbnail", "") or "",
        duration=int(info.get("duration") or 0),
        has_chapters=bool(info.get("chapters")),
        best_audio_label=_best_audio_label(best),
        formats_summary=_formats_summary(best),
        chapters=info.get("chapters") or [],
    )


def detected_line(best_audio_label: str, fmt: str, output_dir: str) -> str:
    if fmt == "aac256":
        return f"Detected: bestaudio ({best_audio_label}) → AAC 256 kbps · {output_dir}"
    return (
        f"Detected: bestaudio ({best_audio_label}) → ALAC lossless · {output_dir}"
        f" · ALAC files are ~5-10x the source size"
    )


def fetch_thumbnail(url: str) -> bytes:
    resp = httpx.get(url, timeout=30, follow_redirects=True)
    resp.raise_for_status()
    return resp.content


def to_square_jpeg(data: bytes, max_size: int = 1400, quality: int = 90) -> bytes:
    img = Image.open(BytesIO(data)).convert("RGB")
    width, height = img.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    img = img.crop((left, top, left + side, top + side))
    if side > max_size:
        img = img.resize((max_size, max_size))
    buf = BytesIO()
    img.save(buf, format="JPEG", quality=quality)
    return buf.getvalue()


def cover_cache_path(video_id: str) -> Path:
    _COVER_DIR.mkdir(parents=True, exist_ok=True)
    return _COVER_DIR / f"{video_id}.jpg"


def cache_cover_jpeg(video_id: str, jpeg: bytes) -> Path:
    path = cover_cache_path(video_id)
    path.write_bytes(jpeg)
    return path


def read_cached_cover(video_id: str) -> bytes | None:
    path = cover_cache_path(video_id)
    return path.read_bytes() if path.exists() else None


def jpeg_to_data_uri(jpeg: bytes) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(jpeg).decode("ascii")


def data_uri_to_bytes(uri: str) -> bytes:
    payload = uri.split(",", 1)[1] if "," in uri else uri
    return base64.b64decode(payload)


def augment_error(exc: Exception) -> str:
    """Turn an exception into a user-facing message, hinting at the PO-token
    provider when the failure looks like a YouTube bot/sign-in check."""
    message = str(exc) or exc.__class__.__name__
    lowered = message.lower()
    triggers = ("sign in", "bot", "confirm you", "403", "429", "rate", "captcha", "not a bot")
    if any(trigger in lowered for trigger in triggers):
        message += (
            " — YouTube may be applying a bot check. Set POT_PROVIDER_URL to a "
            "running PO-token provider sidecar and retry."
        )
    return message
