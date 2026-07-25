from __future__ import annotations

import threading
from dataclasses import dataclass, field

from ..models import JobSnapshot, ProgressEvent


TERMINAL_STATUSES = frozenset({"completed", "failed", "cancelled"})


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
    _lock: threading.Lock = field(
        default_factory=threading.Lock,
        init=False,
        repr=False,
        compare=False,
    )

    def _snapshot_unlocked(self) -> JobSnapshot:
        return JobSnapshot(
            job_id=self.job_id,
            status=self.status,
            latest=self.latest,
            output_paths=list(self.output_paths),
            error=self.error,
        )

    def _mark_cancelled_unlocked(self) -> None:
        self.status = "cancelled"
        self.latest = ProgressEvent(stage="cancelled", pct=0.0, message="Cancelled")

    def update(self, event: ProgressEvent) -> bool:
        with self._lock:
            if self.status in TERMINAL_STATUSES:
                return False
            self.latest = event
            if (
                self.status != "cancelling"
                and event.stage not in {"queued", "done", "error", "cancelled"}
            ):
                self.status = "processing"
            return True

    def complete(
        self,
        paths: list[str],
        event: ProgressEvent | None = None,
    ) -> str | None:
        with self._lock:
            if self.status in TERMINAL_STATUSES:
                return None
            if self.status == "cancelling" or self.token.cancelled:
                self._mark_cancelled_unlocked()
                return "cancelled"
            self.status = "completed"
            self.output_paths = list(paths)
            self.latest = event or ProgressEvent(
                stage="done",
                pct=100.0,
                message="Saved",
            )
            return "completed"

    def fail(self, message: str) -> str | None:
        with self._lock:
            if self.status in TERMINAL_STATUSES:
                return None
            if self.status == "cancelling" or self.token.cancelled:
                self._mark_cancelled_unlocked()
                return "cancelled"
            self.status = "failed"
            self.error = message
            self.latest = ProgressEvent(stage="error", pct=0.0, message=message)
            return "failed"

    def request_cancel(self) -> JobSnapshot:
        with self._lock:
            if self.status not in TERMINAL_STATUSES:
                self.token.cancel()
                self.status = "cancelling"
            return self._snapshot_unlocked()

    def mark_cancelled(self) -> bool:
        with self._lock:
            if self.status in TERMINAL_STATUSES:
                return False
            self.token.cancel()
            self._mark_cancelled_unlocked()
            return True

    def snapshot(self) -> JobSnapshot:
        with self._lock:
            return self._snapshot_unlocked()
