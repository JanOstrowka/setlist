import queue

import pytest

from app.core.job_state import CancellationToken, JobCancelled, JobRecord
from app.main import JobManager
from app.models import ProgressEvent


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
