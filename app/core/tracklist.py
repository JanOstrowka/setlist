from __future__ import annotations

import re
from typing import Optional

from ..models import Track, Tracklist
from .resolver import RawInfo

# Additional tracklist sources plug in here as extra parse_*() producers returning
# the same Track/Tracklist types: 1001tracklists scraping lives in tracklist_1001.py
# (Firecrawl-fetched, since the site is Cloudflare-gated). Audio fingerprinting
# (AudD/Panako) is still deferred and would slot in the same way.
#
# A user can supply a tracklist two ways today: fetch it from a 1001tracklists URL,
# or paste raw text (a YouTube comment/description list), which parse_manual() below
# turns into the same Track model. Auto-fetching a YouTube comment's tracklist would
# be a natural future source — it would pull the comment text server-side and reuse
# parse_manual()/parse_description() — but only manual paste is wired today.

_LEADING_INDEX = re.compile(r"^\s*\d{1,3}[.)]\s+")
_LEADING_TS = re.compile(r"^\s*\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?\s*[-–—)]?\s*")
_TRAILING_TS = re.compile(r"[\[(]?(\d{1,2}:\d{2}(?::\d{2})?)[\])]?\s*$")


def _to_seconds(ts: str) -> float:
    parts = [int(p) for p in ts.split(":")]
    if len(parts) == 3:
        h, m, s = parts
    else:
        h, m, s = 0, parts[0], parts[1]
    return float(h * 3600 + m * 60 + s)


# Artist/Title separators, in priority order. ASCII hyphen is tried first so the
# existing " - " behavior is unchanged; the en-dash and em-dash are added because
# YouTube comments and track names frequently use them (e.g. "Artist – Title").
_LABEL_SEPARATORS = (" - ", " – ", " — ")


def _split_label(label: str) -> tuple[str, str]:
    """Split 'Artist - Title' into (artist, title); plain text → ('', title).

    Accepts a space-padded hyphen, en-dash, or em-dash as the separator, so a
    pasted ``Artist – Title`` parses the same as ``Artist - Title``.
    """
    label = label.strip(" -–—|·:\t")
    for sep in _LABEL_SEPARATORS:
        if sep in label:
            left, _, right = label.partition(sep)
            return left.strip(), right.strip()
    return "", label.strip()


def parse_chapters(chapters: list[dict]) -> list[Track]:
    tracks: list[Track] = []
    for ch in chapters or []:
        start = ch.get("start_time")
        if start is None:
            continue
        artist, title = _split_label((ch.get("title") or "").strip())
        tracks.append(Track(start=float(start), title=title, artist=artist))
    return tracks


def parse_description(description: str) -> list[Track]:
    tracks: list[Track] = []
    for line in (description or "").splitlines():
        m = _LEADING_TS.match(line)
        if m:
            rest = line[m.end():]
        else:
            stripped = _LEADING_INDEX.sub("", line)
            m = _LEADING_TS.match(stripped)
            if not m:
                continue
            rest = stripped[m.end():]
        artist, title = _split_label(rest)
        if not title and not artist:
            continue
        tracks.append(Track(start=_to_seconds(m.group(1)), title=title, artist=artist))
    return tracks


def parse_manual(text: str) -> list[Track]:
    tracks: list[Track] = []
    for line in (text or "").splitlines():
        body = _LEADING_INDEX.sub("", line.strip())
        if not body:
            continue
        start: Optional[float] = None
        ml = _LEADING_TS.match(body)
        mt = _TRAILING_TS.search(body)
        if ml:
            start = _to_seconds(ml.group(1))
            body = body[ml.end():].strip()
        elif mt:
            start = _to_seconds(mt.group(1))
            body = body[: mt.start()].strip()
        artist, title = _split_label(body)
        if not title and not artist:
            continue
        tracks.append(Track(start=start, title=title, artist=artist))
    return tracks


def normalize(tracks: list[Track], total_duration: Optional[float] = None) -> list[Track]:
    """Sort by start (when all present), dedupe, drop rows past the file end.

    When some starts are missing (manual paste), preserve input order and only
    drop exact-duplicate label rows.
    """
    cleaned = [t for t in tracks if (t.title or t.artist or t.start is not None)]
    if cleaned and all(t.start is not None for t in cleaned):
        ordered = sorted(cleaned, key=lambda t: t.start)
        out: list[Track] = []
        seen: set[float] = set()
        for t in ordered:
            key = round(float(t.start), 2)
            if key in seen:
                continue
            if total_duration and t.start >= total_duration:
                continue
            seen.add(key)
            out.append(t)
        return out
    out2: list[Track] = []
    seen2: set = set()
    for t in cleaned:
        key = (t.start, t.title.strip().lower(), t.artist.strip().lower())
        if key in seen2:
            continue
        seen2.add(key)
        out2.append(t)
    return out2


def build_tracklist(raw: RawInfo) -> Tracklist:
    """Best available auto tracklist: chapters → description timestamps → empty."""
    chapter_tracks = parse_chapters(raw.chapters)
    if chapter_tracks:
        return Tracklist(source="chapters", tracks=normalize(chapter_tracks, raw.duration or None))
    desc_tracks = parse_description(raw.description)
    if desc_tracks:
        return Tracklist(source="description", tracks=normalize(desc_tracks, raw.duration or None))
    return Tracklist(source="none", tracks=[])


def parse_manual_tracklist(text: str, total_duration: Optional[float] = None) -> Tracklist:
    return Tracklist(source="manual", tracks=normalize(parse_manual(text), total_duration))
