from app.models import JobSnapshot, ProgressEvent


def test_progress_event_keeps_web_contract():
    event = ProgressEvent(stage="download", pct=25.0, message="Downloading")
    payload = event.model_dump()
    assert payload["pct"] == 25.0
    assert payload["stage_pct"] == 25.0
    assert payload["overall_pct"] == 10.0
    assert payload["track_state"] is None


def test_split_progress_carries_track_fields():
    event = ProgressEvent(
        stage="split",
        pct=50.0,
        overall_pct=80.0,
        message="Cutting track 2 of 4",
        track_index=2,
        track_count=4,
        track_title="Second",
        track_state="cutting",
    )
    assert event.track_index == 2
    assert event.track_state == "cutting"


def test_job_snapshot_terminal_shape():
    snapshot = JobSnapshot(
        job_id="job-1",
        status="completed",
        latest=ProgressEvent(stage="done", pct=100.0),
        output_paths=["/tmp/01.m4a"],
    )
    assert snapshot.status == "completed"
    assert snapshot.output_paths == ["/tmp/01.m4a"]
