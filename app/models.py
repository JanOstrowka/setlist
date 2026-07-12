from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field


class MetadataFields(BaseModel):
    title: str = ""
    artist: str = ""
    album: str = ""
    album_artist: str = ""
    year: Optional[int] = None
    genre: str = ""
    comment: str = ""  # source YouTube URL (provenance)
    compilation: bool = False


class Track(BaseModel):
    start: Optional[float] = None  # seconds from set start; None until user fills a manual row
    title: str = ""
    artist: str = ""
    end: Optional[float] = None  # exclusive end in seconds; computed by the splitter


class Tracklist(BaseModel):
    source: Literal["chapters", "description", "manual", "none", "1001tracklists"] = "none"
    tracks: list[Track] = Field(default_factory=list)
    album: str = ""  # optional proposed set/album title (e.g. from a 1001tracklists H1)
    album_artist: str = ""  # optional proposed set artist (e.g. "John Summit")
    note: str = ""  # optional human-readable note about the parse (e.g. cue coverage)


class ResolveRequest(BaseModel):
    url: str


class ResolveResponse(BaseModel):
    video_id: str
    duration: int
    metadata: MetadataFields
    cover: str  # base64 JPEG data URI (square), or "" if unavailable
    formats: str
    detected_line: str
    has_chapters: bool
    tracklist: Optional[Tracklist] = None  # proposed split tracklist (chapters/description/none)


class DownloadRequest(BaseModel):
    video_id: str
    url: str
    metadata: MetadataFields
    format: Literal["alac", "aac256"] = "alac"
    cover: str = "keep"  # "keep" reuses the server-cached cover, or a data URI overrides it
    callback_url: str = ""  # optional: POSTed a completion summary when the job ends


class SplitDownloadRequest(BaseModel):
    video_id: str
    url: str
    metadata: MetadataFields  # album-level fields shared across tracks
    tracks: list[Track]
    format: Literal["alac", "aac256"] = "alac"
    cover: str = "keep"
    callback_url: str = ""  # optional: POSTed a completion summary when the job ends


class ProgressEvent(BaseModel):
    stage: Literal["queued", "download", "encode", "split", "tag", "done", "error"]
    pct: float = 0.0
    message: str = ""
    file_path: Optional[str] = None
