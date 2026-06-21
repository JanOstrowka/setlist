from __future__ import annotations

import json
import re
from pathlib import Path

import httpx

from ..config import Config
from ..models import MetadataFields
from .resolver import RawInfo

_CACHE_DIR = Path.home() / ".cache" / "setlist"

_NOISE = re.compile(
    r"[\[(]\s*(?:official\s*(?:music\s*)?(?:video|audio|lyric video)?|"
    r"lyrics?|audio|video|hd|4k|m/?v|visualizer|remastered)\s*[\])]",
    re.IGNORECASE,
)


def clean_title(title: str) -> str:
    cleaned = _NOISE.sub("", title or "")
    cleaned = re.sub(r"\s{2,}", " ", cleaned)
    return cleaned.strip(" -–—|·")


def parse_title_fallback(raw: RawInfo) -> MetadataFields:
    cleaned = clean_title(raw.title)
    artist, title = "", cleaned
    if " - " in cleaned:
        left, _, right = cleaned.partition(" - ")
        artist, title = left.strip(), right.strip()
    if not artist:
        artist = raw.uploader
    year = None
    if len(raw.upload_date) >= 4 and raw.upload_date[:4].isdigit():
        year = int(raw.upload_date[:4])
    return MetadataFields(
        title=title or cleaned,
        artist=artist,
        album=cleaned,
        album_artist=artist,
        year=year,
        genre="",
        comment=raw.url,
        compilation=False,
    )


def _map_ai_json(data: dict, fallback: MetadataFields, raw: RawInfo) -> MetadataFields:
    def pick(key: str, default: str) -> str:
        value = data.get(key)
        if isinstance(value, str):
            value = value.strip()
        return value or default

    raw_year = data.get("year")
    try:
        year = int(raw_year) if raw_year not in (None, "", "null") else fallback.year
    except (ValueError, TypeError):
        year = fallback.year

    return MetadataFields(
        title=pick("title", fallback.title),
        artist=pick("artist", fallback.artist),
        album=pick("album", fallback.album),
        album_artist=pick("album_artist", fallback.album_artist),
        year=year,
        genre=pick("genre", fallback.genre),
        comment=raw.url,
        compilation=bool(data.get("compilation", fallback.compilation)),
    )


def _firecrawl_context(query: str, api_key: str, limit: int = 3) -> str:
    try:
        resp = httpx.post(
            "https://api.firecrawl.dev/v1/search",
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            json={"query": query, "limit": limit},
            timeout=30,
        )
        resp.raise_for_status()
        results = resp.json().get("data") or []
        lines = [
            f"- {item.get('title', '')}: {item.get('description', '')} ({item.get('url', '')})"
            for item in results[:limit]
        ]
        return "\n".join(lines)
    except Exception:
        return ""


def _openai_propose(raw: RawInfo, context: str, cfg: Config) -> dict | None:
    try:
        from openai import OpenAI

        client = OpenAI(api_key=cfg.openai_api_key)
        system = (
            "You extract music metadata as strict JSON with exactly these keys: "
            "title, artist, album, album_artist, year (integer or null), genre, "
            "compilation (boolean). For DJ sets or festival recordings, use the "
            "event/set name as the album and the performer as artist/album_artist. "
            "For various-artist compilations set album_artist to 'Various Artists' "
            "and compilation to true. Return ONLY the JSON object."
        )
        user = (
            f"YouTube title: {raw.title}\n"
            f"Uploader: {raw.uploader}\n"
            f"Upload date: {raw.upload_date}\n"
            f"Description (truncated): {raw.description[:1500]}\n\n"
            f"Web context:\n{context or 'none'}"
        )
        resp = client.chat.completions.create(
            model=cfg.openai_model,
            messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
            response_format={"type": "json_object"},
            temperature=0.2,
        )
        return json.loads(resp.choices[0].message.content)
    except Exception:
        return None


def _cache_path(video_id: str) -> Path:
    _CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return _CACHE_DIR / f"{video_id}.json"


def _load_cache(video_id: str) -> dict | None:
    path = _cache_path(video_id)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (ValueError, OSError):
        return None


def _save_cache(video_id: str, data: dict) -> None:
    try:
        _cache_path(video_id).write_text(json.dumps(data, indent=2))
    except OSError:
        pass


def propose_metadata(raw: RawInfo, cfg: Config) -> MetadataFields:
    """Best-guess metadata: per-video cache → AI (OpenAI + optional Firecrawl) → plain title fallback."""
    cached = _load_cache(raw.video_id)
    if cached is not None:
        return MetadataFields(**cached)

    fallback = parse_title_fallback(raw)
    meta = fallback
    if cfg.openai_api_key:
        context = ""
        if cfg.firecrawl_api_key:
            context = _firecrawl_context(f"{clean_title(raw.title)} {raw.uploader}", cfg.firecrawl_api_key)
        data = _openai_propose(raw, context, cfg)
        if data:
            meta = _map_ai_json(data, fallback, raw)

    _save_cache(raw.video_id, meta.model_dump())
    return meta
