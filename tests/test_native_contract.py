"""Contract tests between the Python backend and the native Swift client.

The Swift client (macos/Sources/SetlistMac/API/APIModels.swift) decodes with
convertFromSnakeCase and encodes with convertToSnakeCase. These tests pin the
exact wire keys so a backend rename cannot silently break the native app.
"""

from fastapi.testclient import TestClient

from app.main import app
from app.models import (
    DownloadRequest,
    JobSnapshot,
    ProgressEvent,
    ResolveResponse,
    SplitDownloadRequest,
    Tracklist,
    Track,
    MetadataFields,
)


def test_health_reports_setlist_identity():
    client = TestClient(app)

    response = client.get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["app"] == "Setlist"


def test_resolve_response_serializes_swift_expected_keys():
    payload = ResolveResponse(
        video_id="abc123def45",
        duration=3600,
        metadata=MetadataFields(title="Set", artist="DJ"),
        cover="",
        formats="m4a",
        detected_line="Set",
        has_chapters=True,
        tracklist=Tracklist(source="chapters", tracks=[Track(start=0, title="A")]),
    ).model_dump()

    assert set(payload) == {
        "video_id",
        "duration",
        "metadata",
        "cover",
        "formats",
        "detected_line",
        "has_chapters",
        "tracklist",
    }
    assert set(payload["metadata"]) == {
        "title",
        "artist",
        "album",
        "album_artist",
        "year",
        "genre",
        "comment",
        "compilation",
    }
    assert set(payload["tracklist"]["tracks"][0]) == {
        "start",
        "title",
        "artist",
        "end",
    }


def test_progress_event_keeps_legacy_pct_and_rich_fields():
    payload = ProgressEvent(
        stage="split",
        pct=50.0,
        message="Cutting",
        track_index=2,
        track_count=10,
        track_title="Track",
        track_state="cutting",
        downloaded_bytes=1024,
        total_bytes=4096,
        speed_bytes_per_second=512.0,
        eta_seconds=6.0,
        file_path="/tmp/out.m4a",
    ).model_dump()

    # Legacy web clients read pct; the native client reads the rich fields.
    assert payload["pct"] == 50.0
    assert payload["stage_pct"] == 50.0
    assert payload["overall_pct"] == 80.0  # split spans 70-90
    for key in (
        "stage",
        "message",
        "track_index",
        "track_count",
        "track_title",
        "track_state",
        "downloaded_bytes",
        "total_bytes",
        "speed_bytes_per_second",
        "eta_seconds",
        "file_path",
    ):
        assert key in payload


def test_job_snapshot_serializes_swift_expected_keys():
    payload = JobSnapshot(
        job_id="job-1",
        status="completed",
        latest=ProgressEvent(stage="done", pct=100.0),
        output_paths=["/Music/set.m4a"],
        error="",
    ).model_dump()

    assert set(payload) == {"job_id", "status", "latest", "output_paths", "error"}


def test_download_requests_accept_swift_encoded_payloads():
    # Exactly what the Swift client's snake_case encoder produces.
    single = DownloadRequest.model_validate(
        {
            "video_id": "abc123def45",
            "url": "https://youtu.be/abc123def45",
            "metadata": {"title": "Set", "artist": "DJ", "album_artist": "DJ"},
            "format": "alac",
            "cover": "keep",
            "callback_url": "",
        }
    )
    assert single.video_id == "abc123def45"

    split = SplitDownloadRequest.model_validate(
        {
            "video_id": "abc123def45",
            "url": "https://youtu.be/abc123def45",
            "metadata": {"title": "Set"},
            "tracks": [{"start": 0.0, "title": "A", "artist": ""}],
            "format": "aac256",
            "cover": "keep",
            "callback_url": "",
        }
    )
    assert split.tracks[0].title == "A"


def test_cancel_unknown_job_returns_404():
    client = TestClient(app)

    response = client.post("/jobs/does-not-exist/cancel")

    assert response.status_code == 404


def test_snapshot_unknown_job_returns_404():
    client = TestClient(app)

    response = client.get("/jobs/does-not-exist")

    assert response.status_code == 404
