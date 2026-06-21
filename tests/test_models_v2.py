from app.models import (
    Track,
    Tracklist,
    SplitDownloadRequest,
    MetadataFields,
    ProgressEvent,
    ResolveResponse,
)


def test_track_defaults():
    t = Track()
    assert t.start is None
    assert t.title == ""
    assert t.artist == ""
    assert t.end is None


def test_tracklist_defaults():
    tl = Tracklist()
    assert tl.source == "none"
    assert tl.tracks == []


def test_split_download_request_defaults():
    req = SplitDownloadRequest(
        video_id="abc",
        url="https://x",
        metadata=MetadataFields(),
        tracks=[Track(start=0.0, title="A")],
    )
    assert req.format == "alac"
    assert req.cover == "keep"
    assert req.tracks[0].title == "A"


def test_progress_event_accepts_split_stage():
    ev = ProgressEvent(stage="split", pct=50.0, message="Cut 1/2")
    assert ev.stage == "split"


def test_resolve_response_tracklist_optional():
    resp = ResolveResponse(
        video_id="v", duration=10, metadata=MetadataFields(),
        cover="", formats="", detected_line="", has_chapters=False,
    )
    assert resp.tracklist is None
