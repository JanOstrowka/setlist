from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel


class MetadataFields(BaseModel):
    title: str = ""
    artist: str = ""
    album: str = ""
    album_artist: str = ""
    year: Optional[int] = None
    genre: str = ""
    comment: str = ""  # source YouTube URL (provenance)
    compilation: bool = False


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


class DownloadRequest(BaseModel):
    video_id: str
    url: str
    metadata: MetadataFields
    format: Literal["alac", "aac256"] = "alac"
    cover: str = "keep"  # "keep" reuses the server-cached cover, or a data URI overrides it


class ProgressEvent(BaseModel):
    stage: Literal["queued", "download", "encode", "tag", "done", "error"]
    pct: float = 0.0
    message: str = ""
    file_path: Optional[str] = None
