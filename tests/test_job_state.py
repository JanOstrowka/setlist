import asyncio
import queue
import threading
import time

import pytest

from app import main as main_module
from app.core.job_state import CancellationToken, JobCancelled, JobRecord
from app.main import JobManager, progress_endpoint
from app.models import (
    DownloadRequest,
    MetadataFields,
    ProgressEvent,
    SplitDownloadRequest,
    Track,
)


TERMINAL_STAGES = {"done", "error", "cancelled"}


def _request() -> DownloadRequest:
    return DownloadRequest(
        video_id="video-1",
        url="https://example.com/video",
        metadata=MetadataFields(title="Test"),
    )


def _split_request() -> SplitDownloadRequest:
    return SplitDownloadRequest(
        video_id="video-1",
        url="https://example.com/video",
        metadata=MetadataFields(title="Test"),
        tracks=[
            Track(start=0.0, title="First"),
            Track(start=60.0, title="Second"),
        ],
    )


def _wait_for(predicate, timeout: float = 2.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.01)
    raise AssertionError("Timed out waiting for job state")


def _drain_events(manager: JobManager, job_id: str) -> list[ProgressEvent]:
    events = []
    event_queue = manager.get_queue(job_id)
    while not event_queue.empty():
        events.append(event_queue.get_nowait())
    return events


def test_cancel_token_raises_after_cancel():
    token = CancellationToken()
    token.cancel()
    with pytest.raises(JobCancelled):
        token.raise_if_cancelled()


def test_job_record_retains_terminal_result():
    record = JobRecord("job-1")
    record.update(ProgressEvent(stage="download", pct=50.0))
    record.complete(["/tmp/a.m4a"])
    snapshot = record.snapshot()
    assert snapshot.status == "completed"
    assert snapshot.latest.stage == "done"
    assert snapshot.output_paths == ["/tmp/a.m4a"]


def test_job_record_cancellation_becomes_terminal_after_cleanup():
    record = JobRecord("job-1")
    record.request_cancel()
    assert record.snapshot().status == "cancelling"
    record.mark_cancelled()
    assert record.snapshot().status == "cancelled"
    assert record.token.cancelled is True


def test_job_record_progress_does_not_clear_cancelling_status():
    record = JobRecord("job-1")
    record.request_cancel()
    late_progress = ProgressEvent(
        stage="encode",
        pct=99.0,
        message="Finishing current encode step",
    )

    record.update(late_progress)

    snapshot = record.snapshot()
    assert snapshot.status == "cancelling"
    assert snapshot.latest == late_progress


def test_job_manager_emits_events_and_retains_snapshot():
    manager = JobManager.__new__(JobManager)
    manager.jobs = {"job-1": JobRecord("job-1")}
    manager.events = {"job-1": queue.Queue()}
    event = ProgressEvent(stage="download", pct=25.0)

    manager._emit("job-1", event)

    assert manager.get_queue("job-1").get_nowait() == event
    snapshot = manager.get_snapshot("job-1")
    assert snapshot.status == "processing"
    assert snapshot.latest == event


def test_job_manager_completes_snapshot_before_single_terminal_event(monkeypatch):
    manager = JobManager(None)
    paths = ["/tmp/complete.m4a"]
    monkeypatch.setattr(manager, "_process", lambda job_id, req: paths)

    job_id = manager.submit(_request())
    _wait_for(lambda: manager.get_queue(job_id).qsize() == 2)

    events = _drain_events(manager, job_id)
    terminal = [event for event in events if event.stage in TERMINAL_STAGES]
    assert [event.stage for event in terminal] == ["done"]
    snapshot = manager.get_snapshot(job_id)
    assert snapshot.status == "completed"
    assert snapshot.output_paths == paths


@pytest.mark.parametrize(
    ("job_request", "process_method", "paths", "expected_file_path", "expected_message"),
    [
        (
            _request(),
            "_process",
            ["/tmp/complete.m4a"],
            "/tmp/complete.m4a",
            "Saved",
        ),
        (
            _split_request(),
            "_process_split",
            ["/tmp/set/01.m4a", "/tmp/set/02.m4a"],
            "/tmp/set",
            "Saved 2 tracks",
        ),
    ],
)
def test_job_manager_done_event_preserves_reveal_path(
    monkeypatch,
    job_request,
    process_method,
    paths,
    expected_file_path,
    expected_message,
):
    manager = JobManager(None)
    monkeypatch.setattr(manager, process_method, lambda job_id, req: paths)

    job_id = manager.submit(job_request)
    _wait_for(lambda: manager.get_queue(job_id).qsize() == 2)

    snapshot = manager.get_snapshot(job_id)
    terminal = [
        event
        for event in _drain_events(manager, job_id)
        if event.stage in TERMINAL_STAGES
    ]
    assert snapshot.status == "completed"
    assert len(terminal) == 1
    assert terminal[0].file_path == expected_file_path
    assert terminal[0].message == expected_message


def test_job_manager_failure_retains_snapshot_and_single_terminal_event(monkeypatch):
    manager = JobManager(None)

    def fail(job_id, req):
        raise RuntimeError("pipeline exploded")

    monkeypatch.setattr(manager, "_process", fail)
    job_id = manager.submit(_request())
    _wait_for(lambda: manager.get_queue(job_id).qsize() == 2)

    events = _drain_events(manager, job_id)
    terminal = [event for event in events if event.stage in TERMINAL_STAGES]
    assert [event.stage for event in terminal] == ["error"]
    assert "pipeline exploded" in manager.get_snapshot(job_id).error


def test_job_manager_cancellation_retains_snapshot_and_single_terminal_event(monkeypatch):
    manager = JobManager(None)

    def cancel(job_id, req):
        raise JobCancelled("stop")

    monkeypatch.setattr(manager, "_process", cancel)
    job_id = manager.submit(_request())
    _wait_for(lambda: manager.get_queue(job_id).qsize() == 2)

    events = _drain_events(manager, job_id)
    terminal = [event for event in events if event.stage in TERMINAL_STAGES]
    assert [event.stage for event in terminal] == ["cancelled"]
    assert manager.get_snapshot(job_id).status == "cancelled"


def test_cancellation_between_final_checkpoint_and_completion_wins(monkeypatch):
    manager = JobManager(None)
    paths = ["/tmp/complete.m4a"]
    completion_entered = threading.Event()
    allow_completion = threading.Event()
    callback_payloads = []
    original_complete = JobRecord.complete

    def pause_before_completion(self, *args, **kwargs):
        completion_entered.set()
        assert allow_completion.wait(timeout=2.0)
        return original_complete(self, *args, **kwargs)

    class OkResponse:
        is_success = True

    monkeypatch.setattr(manager, "_process", lambda job_id, req: paths)
    monkeypatch.setattr(JobRecord, "complete", pause_before_completion)
    monkeypatch.setattr(
        main_module.httpx,
        "post",
        lambda url, json, timeout: callback_payloads.append(json) or OkResponse(),
    )
    request = _request().model_copy(
        update={"callback_url": "https://n8n.example/resume"}
    )

    job_id = manager.submit(request)
    try:
        assert completion_entered.wait(timeout=2.0)
        cancelling = manager.request_cancel(job_id)
        assert cancelling.status == "cancelling"
    finally:
        allow_completion.set()

    _wait_for(
        lambda: manager.get_snapshot(job_id).status in {"completed", "cancelled"}
    )
    events = _drain_events(manager, job_id)
    terminal = [event for event in events if event.stage in TERMINAL_STAGES]
    snapshot = manager.get_snapshot(job_id)
    assert snapshot.status == "cancelled"
    assert snapshot.output_paths == []
    assert [event.stage for event in terminal] == ["cancelled"]
    assert callback_payloads == [{
        "job_id": job_id,
        "status": "cancelled",
        "output_paths": [],
        "error": "",
    }]


def test_progress_disconnect_removes_only_terminal_event_queue(monkeypatch):
    manager = JobManager.__new__(JobManager)
    record = JobRecord("job-1")
    record.complete(["/tmp/complete.m4a"])
    manager.jobs = {"job-1": record}
    manager.events = {"job-1": queue.Queue()}
    manager.events["job-1"].put(record.latest)
    monkeypatch.setattr(main_module, "jobs", manager)

    async def consume_terminal_then_disconnect() -> None:
        response = await progress_endpoint("job-1")
        chunk = await anext(response.body_iterator)
        assert '"stage":"done"' in chunk
        await response.body_iterator.aclose()

    asyncio.run(consume_terminal_then_disconnect())

    assert "job-1" not in manager.events
    assert manager.get_snapshot("job-1").status == "completed"
