import queue
import time
from pathlib import Path
from types import SimpleNamespace
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app import main as main_module
from app.core.downloader import DownloadProgress
from app.core.job_state import JobCancelled, JobRecord
from app.main import JobManager, app, jobs
from app.models import (
    DownloadRequest,
    MetadataFields,
    ProgressEvent,
    SplitDownloadRequest,
    Track,
)


@pytest.fixture
def job_id():
    value = uuid4().hex
    jobs.jobs[value] = JobRecord(value)
    jobs.events[value] = queue.Queue()
    try:
        yield value
    finally:
        jobs.events.pop(value, None)
        jobs.jobs.pop(value, None)


def test_get_job_snapshot(job_id):
    jobs._emit(job_id, ProgressEvent(stage="download", pct=20.0))

    response = TestClient(app).get(f"/jobs/{job_id}")

    assert response.status_code == 200
    assert response.json()["latest"]["pct"] == 20.0


def test_cancel_job_is_transient_until_worker_cleanup(job_id):
    response = TestClient(app).post(f"/jobs/{job_id}/cancel")

    assert response.status_code == 200
    assert response.json()["status"] == "cancelling"
    assert response.json()["latest"]["stage"] == "queued"
    assert jobs.events[job_id].empty()


@pytest.mark.parametrize("terminal_status", ["completed", "failed", "cancelled"])
def test_cancel_terminal_job_returns_immutable_snapshot(job_id, terminal_status):
    record = jobs.jobs[job_id]
    if terminal_status == "completed":
        record.complete(["/tmp/finished.m4a"])
    elif terminal_status == "failed":
        record.fail("pipeline failed")
    else:
        record.request_cancel()
        record.mark_cancelled()
    before = record.snapshot().model_dump(mode="json")

    response = TestClient(app).post(f"/jobs/{job_id}/cancel")

    assert response.status_code == 200
    assert response.json() == before
    assert jobs.events[job_id].empty()


def test_unknown_job_returns_404():
    client = TestClient(app)

    assert client.get("/jobs/missing").status_code == 404
    assert client.post("/jobs/missing/cancel").status_code == 404


def _manager(tmp_path) -> tuple[JobManager, str]:
    manager = JobManager.__new__(JobManager)
    manager.cfg = SimpleNamespace(
        output_dir=tmp_path / "output",
        pot_provider_url="https://pot.example",
    )
    job_id = "job-1"
    manager.jobs = {job_id: JobRecord(job_id)}
    manager.events = {job_id: queue.Queue()}
    return manager, job_id


def _request() -> DownloadRequest:
    return DownloadRequest(
        video_id="video-1",
        url="https://example.test/video",
        metadata=MetadataFields(title="Set"),
    )


def _split_request() -> SplitDownloadRequest:
    return SplitDownloadRequest(
        video_id="video-1",
        url="https://example.test/video",
        metadata=MetadataFields(title="Set"),
        tracks=[
            Track(start=0.0, title="First"),
            Track(start=60.0, title="Second"),
        ],
    )


def _events(manager: JobManager, job_id: str) -> list[ProgressEvent]:
    event_queue = manager.events[job_id]
    return list(event_queue.queue)


def _patch_library_and_cover(monkeypatch, destination: Path) -> None:
    monkeypatch.setattr(main_module.resolver, "read_cached_cover", lambda video_id: None)
    monkeypatch.setattr(
        main_module.library,
        "single_track_path",
        lambda *args: destination,
    )
    monkeypatch.setattr(
        main_module.library,
        "set_output_dir",
        lambda *args: destination,
    )
    monkeypatch.setattr(main_module.library, "ensure_output_dir", lambda path: None)
    monkeypatch.setattr(main_module.library, "save", lambda source, target: None)
    monkeypatch.setattr(main_module.library, "write_cover", lambda directory, cover: None)
    monkeypatch.setattr(main_module.library, "record_recent", lambda output_dir, item: None)


def test_single_pipeline_maps_structured_progress_and_cancellation(monkeypatch, tmp_path):
    manager, job_id = _manager(tmp_path)
    token = manager.jobs[job_id].token
    observed_tokens = []
    destination = tmp_path / "output" / "track.m4a"
    _patch_library_and_cover(monkeypatch, destination)

    def fake_download(url, workdir, on_progress, pot_provider_url, cancellation=None):
        observed_tokens.append(cancellation)
        on_progress(DownloadProgress(25.0, 250, 1000, 12.5, 9))
        return workdir / "source.webm"

    def fake_encode(source, target, media_format, on_progress=None, cancellation=None):
        observed_tokens.append(cancellation)
        on_progress(50.0)

    monkeypatch.setattr(main_module.downloader, "download_audio", fake_download)
    monkeypatch.setattr(main_module.downloader, "encode", fake_encode)
    monkeypatch.setattr(main_module.tagger, "write_tags", lambda *args: None)

    result = manager._process(job_id, _request())

    progress = next(
        event
        for event in _events(manager, job_id)
        if event.stage == "download" and event.downloaded_bytes is not None
    )
    assert progress.model_dump() == {
        "stage": "download",
        "pct": 25.0,
        "stage_pct": 25.0,
        "overall_pct": 10.0,
        "message": "Downloading audio",
        "track_index": None,
        "track_count": None,
        "track_title": None,
        "track_state": None,
        "downloaded_bytes": 250,
        "total_bytes": 1000,
        "speed_bytes_per_second": 12.5,
        "eta_seconds": 9.0,
        "file_path": None,
    }
    assert any(event.stage == "encode" and event.pct == 50.0 for event in _events(manager, job_id))
    assert observed_tokens == [token, token]
    assert result == [str(destination)]


def test_split_pipeline_reports_each_cut_and_tag_with_track_fields(monkeypatch, tmp_path):
    manager, job_id = _manager(tmp_path)
    token = manager.jobs[job_id].token
    observed_tokens = []
    destination = tmp_path / "output" / "set"
    _patch_library_and_cover(monkeypatch, destination)

    def fake_download(url, workdir, on_progress, pot_provider_url, cancellation=None):
        observed_tokens.append(cancellation)
        on_progress(DownloadProgress(20.0, 200, 1000, 10.0, 8))
        return workdir / "source.webm"

    def fake_encode(source, target, media_format, on_progress=None, cancellation=None):
        observed_tokens.append(cancellation)
        on_progress(50.0)

    def fake_split(full, tracks, out_dir, on_track=None, cancellation=None):
        observed_tokens.append(cancellation)
        files = [out_dir / "01 - First.m4a", out_dir / "02 - Second.m4a"]
        for index, track in enumerate(tracks, start=1):
            on_track(index, len(tracks), track.title)
        return files

    def fake_tag(files, tracks, metadata, cover, on_track=None, cancellation=None):
        observed_tokens.append(cancellation)
        for index, track in enumerate(tracks, start=1):
            on_track(index, len(tracks), track.title)

    monkeypatch.setattr(main_module.downloader, "download_audio", fake_download)
    monkeypatch.setattr(main_module.downloader, "encode", fake_encode)
    monkeypatch.setattr(main_module.splitter, "split_file", fake_split)
    monkeypatch.setattr(main_module.tagger, "tag_album", fake_tag)

    result = manager._process_split(job_id, _split_request())

    events = _events(manager, job_id)
    structured_download = next(
        event
        for event in events
        if event.stage == "download" and event.downloaded_bytes is not None
    )
    assert (
        structured_download.downloaded_bytes,
        structured_download.total_bytes,
        structured_download.speed_bytes_per_second,
        structured_download.eta_seconds,
    ) == (200, 1000, 10.0, 8.0)
    split_events = [event for event in events if event.stage == "split"]
    assert [
        (event.pct, event.track_index, event.track_count, event.track_title, event.track_state)
        for event in split_events
    ] == [
        (0.0, 1, 2, "First", "cutting"),
        (50.0, 1, 2, "First", "cutting"),
        (50.0, 2, 2, "Second", "cutting"),
        (100.0, 2, 2, "Second", "cutting"),
    ]
    tag_events = [
        event
        for event in events
        if event.stage == "tag" and event.track_index is not None
    ]
    assert [
        (event.pct, event.track_index, event.track_count, event.track_title, event.track_state)
        for event in tag_events
    ] == [
        (50.0, 1, 2, "First", "tagging"),
        (100.0, 2, 2, "Second", "tagging"),
    ]
    assert observed_tokens == [token, token, token, token]
    assert result == [
        str(destination / "01 - First.m4a"),
        str(destination / "02 - Second.m4a"),
    ]


def _enable_master_cache(manager: JobManager, tmp_path: Path) -> Path:
    root = tmp_path / "masters"
    manager.cfg.master_cache_dir = root
    manager.cfg.master_cache_bytes = 10**9
    return root


def _patch_split_and_tag(monkeypatch) -> None:
    def fake_split(full, tracks, out_dir, on_track=None, cancellation=None):
        assert Path(full).read_bytes() == b"encoded-master"
        return [out_dir / "01 - First.m4a", out_dir / "02 - Second.m4a"]

    monkeypatch.setattr(main_module.splitter, "split_file", fake_split)
    monkeypatch.setattr(
        main_module.tagger, "tag_album", lambda *args, **kwargs: None
    )


def test_split_pipeline_keeps_the_encoded_master_for_next_time(monkeypatch, tmp_path):
    manager, job_id = _manager(tmp_path)
    cache_root = _enable_master_cache(manager, tmp_path)
    _patch_library_and_cover(monkeypatch, tmp_path / "output" / "set")
    _patch_split_and_tag(monkeypatch)

    def fake_download(url, workdir, on_progress, pot_provider_url, cancellation=None):
        return workdir / "source.webm"

    def fake_encode(source, target, media_format, on_progress=None, cancellation=None):
        Path(target).write_bytes(b"encoded-master")

    monkeypatch.setattr(main_module.downloader, "download_audio", fake_download)
    monkeypatch.setattr(main_module.downloader, "encode", fake_encode)

    manager._process_split(job_id, _split_request())

    cached = cache_root / "video-1.alac.m4a"
    assert cached.read_bytes() == b"encoded-master"


def test_split_pipeline_skips_download_and_encode_when_the_master_is_cached(
    monkeypatch, tmp_path
):
    manager, job_id = _manager(tmp_path)
    cache_root = _enable_master_cache(manager, tmp_path)
    cache_root.mkdir()
    (cache_root / "video-1.alac.m4a").write_bytes(b"encoded-master")
    _patch_library_and_cover(monkeypatch, tmp_path / "output" / "set")
    _patch_split_and_tag(monkeypatch)

    def no_download(*args, **kwargs):
        raise AssertionError("download must not run for a cached master")

    monkeypatch.setattr(main_module.downloader, "download_audio", no_download)
    monkeypatch.setattr(main_module.downloader, "encode", no_download)

    result = manager._process_split(job_id, _split_request())

    events = _events(manager, job_id)
    assert [(e.stage, e.pct) for e in events if e.stage in ("download", "encode")] == [
        ("download", 100.0),
        ("encode", 100.0),
    ]
    assert "already on this Mac" in next(e for e in events if e.stage == "download").message
    assert len(result) == 2
    # The cache keeps its copy for the next re-run.
    assert (cache_root / "video-1.alac.m4a").read_bytes() == b"encoded-master"


def test_single_pipeline_tags_a_private_copy_of_the_cached_master(monkeypatch, tmp_path):
    manager, job_id = _manager(tmp_path)
    cache_root = _enable_master_cache(manager, tmp_path)
    cache_root.mkdir()
    (cache_root / "video-1.alac.m4a").write_bytes(b"encoded-master")
    _patch_library_and_cover(monkeypatch, tmp_path / "output" / "track.m4a")
    tagged = []

    def fake_write_tags(path, metadata, cover):
        # Tagging rewrites the file; the cached master must stay pristine.
        Path(path).write_bytes(b"tagged")
        tagged.append(Path(path))

    monkeypatch.setattr(main_module.tagger, "write_tags", fake_write_tags)
    monkeypatch.setattr(
        main_module.downloader,
        "download_audio",
        lambda *a, **k: (_ for _ in ()).throw(AssertionError("no download")),
    )

    manager._process(job_id, _request())

    assert tagged and tagged[0].name == "encoded.m4a"
    assert (cache_root / "video-1.alac.m4a").read_bytes() == b"encoded-master"


def test_pipeline_runs_without_a_configured_cache(monkeypatch, tmp_path):
    manager, job_id = _manager(tmp_path)  # cfg has no master_cache_* attributes
    _patch_library_and_cover(monkeypatch, tmp_path / "output" / "set")
    _patch_split_and_tag(monkeypatch)
    monkeypatch.setattr(
        main_module.downloader,
        "download_audio",
        lambda url, workdir, *a, **k: workdir / "source.webm",
    )
    monkeypatch.setattr(
        main_module.downloader,
        "encode",
        lambda source, target, *a, **k: Path(target).write_bytes(b"encoded-master"),
    )

    result = manager._process_split(job_id, _split_request())

    assert len(result) == 2
    assert not (tmp_path / "masters").exists()


def test_cancelled_worker_posts_one_terminal_callback(monkeypatch):
    manager = JobManager(main_module.cfg)
    calls = []

    def cancel(job_id, request):
        raise JobCancelled("stop")

    class OkResponse:
        is_success = True

    monkeypatch.setattr(manager, "_process", cancel)
    monkeypatch.setattr(
        main_module.httpx,
        "post",
        lambda url, json, timeout: calls.append((url, json)) or OkResponse(),
    )
    request = _request().model_copy(
        update={"callback_url": "https://n8n.example/resume"}
    )

    job_id = manager.submit(request)
    deadline = time.time() + 2.0
    while time.time() < deadline and not calls:
        time.sleep(0.01)

    assert calls == [
        (
            "https://n8n.example/resume",
            {
                "job_id": job_id,
                "status": "cancelled",
                "output_paths": [],
                "error": "",
            },
        )
    ]
    terminal = [
        event for event in _events(manager, job_id) if event.stage == "cancelled"
    ]
    assert len(terminal) == 1
