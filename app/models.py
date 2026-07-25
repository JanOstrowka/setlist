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


TrackProgressState = Literal["pending", "cutting", "tagging", "ready"]
JobStatus = Literal[
    "queued", "processing", "cancelling", "completed", "failed", "cancelled", "interrupted"
]
ProgressStage = Literal[
    "queued", "download", "encode", "split", "tag", "done", "error", "cancelled"
]


class ProgressEvent(BaseModel):
    stage: ProgressStage
    pct: float = 0.0
    stage_pct: Optional[float] = None
    overall_pct: Optional[float] = None
    message: str = ""
    track_index: Optional[int] = None
    track_count: Optional[int] = None
    track_title: Optional[str] = None
    track_state: Optional[TrackProgressState] = None
    downloaded_bytes: Optional[int] = None
    total_bytes: Optional[int] = None
    speed_bytes_per_second: Optional[float] = None
    eta_seconds: Optional[float] = None
    file_path: Optional[str] = None

    def model_post_init(self, __context) -> None:
        if self.stage_pct is None:
            self.stage_pct = self.pct
        if self.overall_pct is None:
            spans = {
                "queued": (0.0, 0.0),
                "download": (0.0, 40.0),
                "encode": (40.0, 70.0),
                "split": (70.0, 90.0),
                "tag": (90.0, 100.0),
                "done": (100.0, 100.0),
                "error": (0.0, 0.0),
                "cancelled": (0.0, 0.0),
            }
            start, end = spans[self.stage]
            self.overall_pct = start + (end - start) * self.pct / 100.0


class JobSnapshot(BaseModel):
    job_id: str
    status: JobStatus
    latest: ProgressEvent
    output_paths: list[str] = Field(default_factory=list)
    error: str = ""
