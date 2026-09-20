"""Metadata proposals from what YouTube already tells us.

The set's title, uploader, and upload date are parsed with a few rules into
the album fields the review screen starts from. The user fixes whatever the
rules get wrong before anything is written, and the tracklist itself comes
from chapters or 1001tracklists, so no external service is involved here.
"""

from __future__ import annotations

import re

from ..models import MetadataFields
from .resolver import RawInfo

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


def propose_metadata(raw: RawInfo) -> MetadataFields:
    """Best-guess album fields for the review screen."""
    return parse_title_fallback(raw)
