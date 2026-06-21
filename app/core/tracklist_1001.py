"""1001tracklists.com tracklist source.

1001tracklists is Cloudflare-Turnstile-gated and has no official API, so this was
deferred in v2 (see the note in ``tracklist.py``). It is now wired in as another
``parse_*`` producer returning the same ``Track``/``Tracklist`` types as the other
sources, so the splitter/tagger/UI flow downstream is unchanged.

The page is fetched through the existing Firecrawl integration (Firecrawl renders
JS and bypasses the anti-bot wall, returning clean markdown). The pure parser
(`parse_1001tracklists_markdown`) is unit-tested against a saved markdown fixture
so the tests are deterministic and never hit the network.

Parsing anchors on the per-row "search the web via Google" links: each track row
carries a ``google.com/search?q=Artist+-+Title`` link whose decoded query is a clean
``Artist - Title`` (remix/edit info included), which is far more robust than scraping
the link-and-label-littered name line. Cue times (``m:ss`` / ``h:mm:ss``) appear as
standalone lines just before each row's Google link; the first row has no cue on
1001tracklists and is treated as starting at ``0:00``.
"""
from __future__ import annotations

import re
import urllib.parse
from dataclasses import dataclass, field
from typing import Optional
from urllib.parse import urlparse

import httpx

from ..config import Config
from ..models import Track, Tracklist

_FIRECRAWL_SCRAPE_URL = "https://api.firecrawl.dev/v2/scrape"

# A standalone cue line: "1:31", "03:10", or "1:02:13" (optionally bracketed/parens).
_CUE_LINE = re.compile(r"^[\[(]?(\d{1,2}:\d{2}(?::\d{2})?)[)\]]?$")
# Each track row links to a Google search whose q= param is a clean "Artist - Title".
_GOOGLE_Q = re.compile(r"google\.com/search\?q=([^\s)\"']+)")
# Where the track listing ends and page footer/navigation begins. Truncating here
# keeps the footer's own (non-track) Google links from being mistaken for tracks.
_FOOTER_MARKERS = (
    "Add a (live) video",
    "Tracklist Actions",
    "General Information",
)
_MD_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")


def is_1001_url(url: str) -> bool:
    """True if the URL points at 1001tracklists (full domain or the 1001.tl shortener)."""
    try:
        host = urlparse((url or "").strip()).netloc.lower()
    except ValueError:
        return False
    host = host.split("@")[-1].split(":")[0]
    return host == "1001.tl" or host == "1001tracklists.com" or host.endswith(
        ".1001tracklists.com"
    )


def _clean(text: str) -> str:
    return re.sub(r"\s+", " ", text or "").strip()


def _cue_to_seconds(ts: str) -> float:
    parts = [int(p) for p in ts.split(":")]
    if len(parts) == 3:
        h, m, s = parts
    elif len(parts) == 2:
        h, m, s = 0, parts[0], parts[1]
    else:
        h, m, s = 0, 0, parts[0]
    return float(h * 3600 + m * 60 + s)


def _split_artist_title(query: str) -> tuple[str, str]:
    """Decode a Google ``q=`` param into ``(artist, title)``, splitting on the first
    ``' - '``. ``ID - ID`` -> ``('ID', 'ID')``; ``A w/ B - Title`` keeps ``w/`` in the
    artist. A string without ``' - '`` returns ``('', text)``."""
    text = _clean(urllib.parse.unquote_plus(query))
    if " - " in text:
        artist, _, title = text.partition(" - ")
        return _clean(artist), _clean(title)
    return "", text


@dataclass
class Parsed1001:
    tracks: list[Track] = field(default_factory=list)
    album: str = ""
    album_artist: str = ""
    note: str = ""


def _parse_header(markdown: str) -> tuple[str, str]:
    """Derive ``(album, album_artist)`` from the H1.

    The H1 looks like::

        # [John Summit](url) @ [Do LaB](url) Stage, [Coachella Festival](url) Weekend 1, United States 2026-04-10

    -> album ``"John Summit @ Do LaB Stage, Coachella Festival Weekend 1, ..."``,
    album_artist ``"John Summit"`` (the performer before ``" @ "``).
    """
    for line in markdown.splitlines():
        if line.startswith("# "):
            text = _clean(_MD_LINK.sub(r"\1", line[2:]))
            artist = _clean(text.split(" @ ")[0]) if " @ " in text else ""
            return text, artist
    return "", ""


def parse_1001tracklists_markdown(markdown: str) -> Parsed1001:
    """Parse Firecrawl markdown of a 1001tracklists page into tracks + set metadata.

    Pure and deterministic (no network), so it is unit-tested against a saved fixture.
    """
    album, album_artist = _parse_header(markdown)

    # Restrict to the track-listing region; the footer carries its own Google links.
    body = markdown
    cut = len(body)
    for marker in _FOOTER_MARKERS:
        idx = body.find(marker)
        if idx != -1:
            cut = min(cut, idx)
    body = body[:cut]

    tracks: list[Track] = []
    pending_cue: Optional[float] = None
    for raw in body.splitlines():
        line = raw.strip()
        if not line:
            continue
        cue = _CUE_LINE.match(line)
        if cue:
            pending_cue = _cue_to_seconds(cue.group(1))
            continue
        gq = _GOOGLE_Q.search(line)
        if not gq:
            continue
        decoded = urllib.parse.unquote_plus(gq.group(1))
        if " - " not in decoded:
            # Footer/navigation search (e.g. q=John+Summit), not a track row.
            pending_cue = None
            continue
        artist, title = _split_artist_title(gq.group(1))
        tracks.append(Track(start=pending_cue, title=title, artist=artist))
        pending_cue = None

    # 1001tracklists omits the opening track's cue; it starts the set at 0:00.
    if tracks and tracks[0].start is None:
        tracks[0].start = 0.0

    total = len(tracks)
    with_cues = sum(1 for t in tracks if t.start is not None)
    if total == 0:
        note = "No tracks found on the 1001tracklists page."
    elif with_cues == total:
        note = f"Parsed {total} tracks from 1001tracklists, all with cue times."
    else:
        note = (
            f"Parsed {total} tracks from 1001tracklists; {with_cues}/{total} have cue "
            "times — fill the rest in before splitting."
        )
    return Parsed1001(tracks=tracks, album=album, album_artist=album_artist, note=note)


def fetch_1001tracklists_markdown(url: str, api_key: str, timeout: float = 120.0) -> str:
    """Fetch a 1001tracklists page as markdown via Firecrawl (renders JS, bypasses
    the Cloudflare anti-bot wall). Reuses the same httpx + Bearer pattern as the
    metadata enrichment. ``proxy=auto`` retries with enhanced proxies if needed."""
    resp = httpx.post(
        _FIRECRAWL_SCRAPE_URL,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        json={
            "url": url,
            "formats": ["markdown"],
            "proxy": "auto",
            "onlyMainContent": True,
            "waitFor": 3000,
        },
        timeout=timeout,
    )
    resp.raise_for_status()
    payload = resp.json().get("data") or {}
    markdown = payload.get("markdown") or ""
    if not markdown:
        raise RuntimeError("Firecrawl returned no markdown for the 1001tracklists page")
    return markdown


def parse_1001tracklists(url: str, cfg: Config) -> Tracklist:
    """Fetch + parse a 1001tracklists URL into a ``Tracklist`` (source ``1001tracklists``)."""
    if not cfg.firecrawl_api_key:
        raise RuntimeError(
            "A FIRECRAWL_API_KEY is required to fetch 1001tracklists pages "
            "(they are Cloudflare-protected). Add it to your .env."
        )
    markdown = fetch_1001tracklists_markdown(url, cfg.firecrawl_api_key)
    parsed = parse_1001tracklists_markdown(markdown)
    return Tracklist(
        source="1001tracklists",
        tracks=parsed.tracks,
        album=parsed.album,
        album_artist=parsed.album_artist,
        note=parsed.note,
    )
