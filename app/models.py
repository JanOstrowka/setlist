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
    source: Literal["chapters", "description", "manual", "none"] = "none"
    tracks: list[Track] = Field(default_factory=list)


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


class SplitDownloadRequest(BaseModel):
    video_id: str
    url: str
    metadata: MetadataFields  # album-level fields shared across tracks
    tracks: list[Track]
    format: Literal["alac", "aac256"] = "alac"
    cover: str = "keep"


class ProgressEvent(BaseModel):
    stage: Literal["queued", "download", "encode", "split", "tag", "done", "error"]
    pct: float = 0.0
    message: str = ""
    file_path: Optional[str] = None
