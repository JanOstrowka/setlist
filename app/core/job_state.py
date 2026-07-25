from __future__ import annotations

import threading
from dataclasses import dataclass, field

from ..models import JobSnapshot, ProgressEvent


class JobCancelled(RuntimeError):
    pass


class CancellationToken:
    def __init__(self) -> None:
        self._event = threading.Event()

    @property
    def cancelled(self) -> bool:
        return self._event.is_set()

    def cancel(self) -> None:
        self._event.set()

    def raise_if_cancelled(self) -> None:
        if self.cancelled:
            raise JobCancelled("Job cancelled")


@dataclass
class JobRecord:
    job_id: str
    token: CancellationToken = field(default_factory=CancellationToken)
    status: str = "queued"
    latest: ProgressEvent = field(
        default_factory=lambda: ProgressEvent(stage="queued", pct=0.0, message="Queued")
    )
    output_paths: list[str] = field(default_factory=list)
    error: str = ""

    def update(self, event: ProgressEvent) -> None:
        self.latest = event
        if event.stage not in {"queued", "done", "error", "cancelled"}:
            self.status = "processing"

    def complete(self, paths: list[str]) -> None:
        self.status = "completed"
        self.output_paths = paths
        self.latest = ProgressEvent(stage="done", pct=100.0, message="Saved")

    def fail(self, message: str) -> None:
        self.status = "failed"
        self.error = message
        self.latest = ProgressEvent(stage="error", pct=0.0, message=message)

    def request_cancel(self) -> None:
        self.token.cancel()
        self.status = "cancelling"

    def mark_cancelled(self) -> None:
        self.status = "cancelled"
        self.latest = ProgressEvent(stage="cancelled", pct=0.0, message="Cancelled")

    def snapshot(self) -> JobSnapshot:
        return JobSnapshot(
            job_id=self.job_id,
            status=self.status,
            latest=self.latest,
            output_paths=self.output_paths,
            error=self.error,
        )
