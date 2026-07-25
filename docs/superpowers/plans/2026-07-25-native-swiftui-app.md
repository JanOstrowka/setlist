# Setlist Native SwiftUI App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the full-window website wrapper with a native macOS 26 SwiftUI workflow that preserves the Python media engine, exposes truthful per-stage and per-track progress, persists all job history, and imports completed tracks into Apple Music on explicit confirmation.

**Architecture:** The existing FastAPI process remains an invisible localhost engine. A typed Swift `SetlistAPI` drives a single `WorkflowController`, persists history with SwiftData, renders native Liquid Glass views, and reserves `WKWebView` only for YouTube playback. Backend progress events remain backward-compatible with the current web client while adding cancellation and terminal job reconciliation.

**Tech Stack:** Python 3.11+, FastAPI, Pydantic 2, yt-dlp, ffmpeg, mutagen, Swift 6.3, SwiftUI, SwiftData, WebKit, AppKit, Apple Events, XCTest, pytest.

## Global Constraints

- Minimum supported OS is macOS 26.0; use real SwiftUI Liquid Glass APIs.
- Keep the existing Python download, split, tag, and tracklist pipeline.
- Keep existing browser and hosted-site API behavior operational.
- Preserve `ProgressEvent.pct`; all richer progress fields are optional additions.
- Process one native-app job at a time.
- Persist resolving, processing, completed, cancelled, interrupted, and failed jobs.
- Do not resume partial media in v1; mark it Interrupted after an unclean exit.
- Use an explicit **Add to Apple Music** action; never auto-import.
- Use `WKWebView` only for the YouTube player.
- Respect Reduce Motion and never communicate state only through animation.
- Write a failing test before each behavior change.
- Do not create Git commits unless the user separately requests them.

## File structure

### Python engine

- `app/models.py` — API request, response, progress, and terminal job models.
- `app/core/job_state.py` — cancellation token and in-memory job snapshots.
- `app/core/downloader.py` — yt-dlp and ffmpeg progress/cancellation.
- `app/core/splitter.py` — per-track split progress/cancellation.
- `app/core/tagger.py` — per-track tag progress/cancellation.
- `app/main.py` — job orchestration and API routes.
- `tests/test_progress_models.py` — backward-compatible progress serialization.
- `tests/test_job_state.py` — cancellation and snapshot behavior.
- `tests/test_media_progress.py` — yt-dlp and ffmpeg progress mapping.
- `tests/test_job_api.py` — cancel and terminal snapshot routes.

### Native app

- `macos/Sources/SetlistMac/App/SetlistMacApp.swift` — app scenes and menu-bar commands.
- `macos/Sources/SetlistMac/App/AppDelegate.swift` — activation and safe termination.
- `macos/Sources/SetlistMac/API/APIModels.swift` — Codable API contracts.
- `macos/Sources/SetlistMac/API/SSEDecoder.swift` — incremental SSE parsing.
- `macos/Sources/SetlistMac/API/SetlistAPI.swift` — typed localhost client.
- `macos/Sources/SetlistMac/Backend/BackendController.swift` — existing engine supervisor.
- `macos/Sources/SetlistMac/History/HistoryRecord.swift` — SwiftData model.
- `macos/Sources/SetlistMac/History/HistoryStore.swift` — persistence operations.
- `macos/Sources/SetlistMac/Workflow/WorkflowState.swift` — workflow state and editable draft.
- `macos/Sources/SetlistMac/Workflow/WorkflowController.swift` — single workflow coordinator.
- `macos/Sources/SetlistMac/Design/SetlistTheme.swift` — shared spacing and visual values.
- `macos/Sources/SetlistMac/Views/RootView.swift` — split-view shell and engine recovery.
- `macos/Sources/SetlistMac/Views/RecentSidebar.swift` — history navigation.
- `macos/Sources/SetlistMac/Views/LandingView.swift` — paste-first landing state.
- `macos/Sources/SetlistMac/Views/ResolveLoadingView.swift` — skeleton loading.
- `macos/Sources/SetlistMac/Views/ReviewView.swift` — two-pane production workspace.
- `macos/Sources/SetlistMac/Views/MetadataEditor.swift` — album metadata controls.
- `macos/Sources/SetlistMac/Views/TracklistEditor.swift` — native track rows.
- `macos/Sources/SetlistMac/Views/YouTubePlayerView.swift` — scoped IFrame player.
- `macos/Sources/SetlistMac/Views/ProcessingView.swift` — full-window processing state.
- `macos/Sources/SetlistMac/Views/StageRail.swift` — pipeline stages.
- `macos/Sources/SetlistMac/Views/TrackProgressList.swift` — per-track status.
- `macos/Sources/SetlistMac/Views/TrackSlipCanvas.swift` — completion-driven motion.
- `macos/Sources/SetlistMac/Views/CompletionView.swift` — Music/Finder CTAs.
- `macos/Sources/SetlistMac/Music/MusicImporter.swift` — Apple Events import.
- `macos/Tests/SetlistMacTests/` — unit and integration tests by matching feature name.

---

## Milestone 1: Engine progress foundation

### Task 1: Backward-compatible progress and job models

**Files:**
- Modify: `app/models.py:68-72`
- Create: `tests/test_progress_models.py`

**Interfaces:**
- Produces: `TrackProgressState`, `JobStatus`, expanded `ProgressEvent`, and `JobSnapshot`.
- Preserves: `ProgressEvent(stage=..., pct=..., message=...)`.

- [ ] **Step 1: Write failing serialization tests**

```python
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
```

- [ ] **Step 2: Run the tests and verify the missing models fail**

Run: `.venv/bin/pytest -q tests/test_progress_models.py`

Expected: import or validation failures because the expanded models do not exist.

- [ ] **Step 3: Add the progress contracts**

Add these aliases and models to `app/models.py`:

```python
from typing import Literal, Optional

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
```

- [ ] **Step 4: Verify focused and existing model tests**

Run: `.venv/bin/pytest -q tests/test_progress_models.py tests/test_models_v2.py`

Expected: all tests pass and the old `pct` constructor remains valid.

- [ ] **Step 5: Review checkpoint**

Run: `git diff --check -- app/models.py tests/test_progress_models.py`

Expected: no whitespace errors. Do not commit without explicit user permission.

### Task 2: Cancellation tokens and retained job snapshots

**Files:**
- Create: `app/core/job_state.py`
- Create: `tests/test_job_state.py`
- Modify: `app/main.py:62-127`

**Interfaces:**
- Produces: `JobCancelled`, `CancellationToken.cancel()`, `CancellationToken.raise_if_cancelled()`, and `JobRecord.snapshot()`.
- Consumes: `ProgressEvent` and `JobSnapshot` from Task 1.

- [ ] **Step 1: Write failing state tests**

```python
import pytest

from app.core.job_state import CancellationToken, JobCancelled, JobRecord
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
```

- [ ] **Step 2: Run and verify failure**

Run: `.venv/bin/pytest -q tests/test_job_state.py`

Expected: module import failure for `app.core.job_state`.

- [ ] **Step 3: Implement job state primitives**

Create `app/core/job_state.py`:

```python
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
```

- [ ] **Step 4: Refactor `JobManager` to own `JobRecord` values**

Replace the separate queue-only `jobs` mapping with:

```python
self.jobs: dict[str, JobRecord] = {}
self.events: dict[str, queue.Queue[ProgressEvent]] = {}
```

`submit()` creates both entries. `_emit()` updates the `JobRecord` before publishing. `_run()` handles `JobCancelled` separately by cleaning temporary files, calling `record.mark_cancelled()`, emitting one terminal cancelled event, and posting a cancelled callback. It calls `record.complete(paths)` on success and retains the record after the SSE stream ends. `get_queue()` reads `events`; a new `get_snapshot(job_id)` returns `record.snapshot()`.

After a terminal SSE event is consumed, remove only its queue from `events`; retain the `JobRecord` in `jobs` for `GET /jobs/{job_id}`.

- [ ] **Step 5: Run state and API regressions**

Run: `.venv/bin/pytest -q tests/test_job_state.py tests/test_api.py tests/test_auth_callback.py`

Expected: all pass; update only assertions that previously depended on terminal jobs being removed.

### Task 3: Real download, encode, split, and tag progress

**Files:**
- Modify: `app/core/downloader.py`
- Modify: `app/core/splitter.py`
- Modify: `app/core/tagger.py`
- Create: `tests/test_media_progress.py`
- Modify: `tests/test_downloader.py`
- Modify: `tests/test_splitter.py`
- Modify: `tests/test_tagger_album.py`

**Interfaces:**
- Produces: `DownloadProgress`, `download_audio(..., on_progress, cancellation)`, `encode(..., on_progress, cancellation)`.
- Extends: `split_file(..., on_track, cancellation)` and `tag_album(..., on_track, cancellation)`.
- Consumes: `CancellationToken`.

- [ ] **Step 1: Write failing progress mapping tests**

```python
import pytest

from app.core.downloader import DownloadProgress, parse_ffmpeg_progress
from app.core.job_state import CancellationToken, JobCancelled


def test_download_progress_from_yt_dlp_payload():
    progress = DownloadProgress.from_yt_dlp({
        "downloaded_bytes": 25,
        "total_bytes": 100,
        "speed": 12.5,
        "eta": 6,
    })
    assert progress.pct == 25.0
    assert progress.downloaded_bytes == 25
    assert progress.speed_bytes_per_second == 12.5
    assert progress.eta_seconds == 6


def test_parse_ffmpeg_progress_uses_output_time():
    assert parse_ffmpeg_progress("out_time_us=5000000", duration_seconds=10) == 50.0


def test_cancelled_token_raises_from_progress_hook():
    token = CancellationToken()
    token.cancel()
    with pytest.raises(JobCancelled):
        token.raise_if_cancelled()
```

- [ ] **Step 2: Run and verify failure**

Run: `.venv/bin/pytest -q tests/test_media_progress.py`

Expected: missing progress type and parser failures.

- [ ] **Step 3: Add structured yt-dlp mapping**

Add to `downloader.py`:

```python
from dataclasses import dataclass
from .job_state import CancellationToken


@dataclass(frozen=True)
class DownloadProgress:
    pct: float
    downloaded_bytes: int | None = None
    total_bytes: int | None = None
    speed_bytes_per_second: float | None = None
    eta_seconds: float | None = None

    @classmethod
    def from_yt_dlp(cls, payload: dict) -> "DownloadProgress":
        total = payload.get("total_bytes") or payload.get("total_bytes_estimate")
        downloaded = payload.get("downloaded_bytes")
        pct = min(99.0, downloaded / total * 100.0) if downloaded and total else 0.0
        return cls(pct, downloaded, total, payload.get("speed"), payload.get("eta"))
```

Change `download_audio` to accept `Callable[[DownloadProgress], None]` and an optional `CancellationToken`. The progress hook calls `token.raise_if_cancelled()` before publishing each event.

- [ ] **Step 4: Add machine-readable ffmpeg progress**

Implement:

```python
def probe_duration(path: Path | str) -> float:
    proc = subprocess.run(
        [
            "ffprobe", "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return float(proc.stdout.strip())


def parse_ffmpeg_progress(line: str, duration_seconds: float) -> float | None:
    if not line.startswith("out_time_us=") or duration_seconds <= 0:
        return None
    microseconds = int(line.split("=", 1)[1])
    return min(99.0, microseconds / 1_000_000 / duration_seconds * 100.0)
```

Probe the source duration with `ffprobe`, then run ffmpeg with `-loglevel error -progress pipe:1 -nostats` through `subprocess.Popen`. Read stdout line-by-line, publish parsed percentages, check cancellation between lines, terminate on cancellation, and raise the existing encode error on a nonzero exit. Publish 100% after success.

- [ ] **Step 5: Add per-file callbacks and cancellation**

In `splitter.split_file`, call `cancellation.raise_if_cancelled()` before each `_cut`.

In `tagger.tag_album`, add:

```python
on_track: Callable[[int, int, str], None] | None = None
cancellation: CancellationToken | None = None
```

Check cancellation before each file and call `on_track(i, total, track.title)` after `write_tags`.

- [ ] **Step 6: Verify media tests**

Run:

```bash
.venv/bin/pytest -q \
  tests/test_media_progress.py \
  tests/test_downloader.py \
  tests/test_splitter.py \
  tests/test_tagger_album.py
```

Expected: all pass; ffmpeg-dependent tests may skip only when ffmpeg is unavailable.

### Task 4: Orchestration, cancellation API, and terminal reconciliation

**Files:**
- Modify: `app/main.py:62-242`
- Create: `tests/test_job_api.py`
- Modify: `web/app.js` only if event compatibility tests reveal a regression

**Interfaces:**
- Produces: `GET /jobs/{job_id}` and `POST /jobs/{job_id}/cancel`.
- Consumes: Tasks 1–3 progress and cancellation interfaces.

- [ ] **Step 1: Write failing API tests**

```python
import queue
from uuid import uuid4

from fastapi.testclient import TestClient

from app.core.job_state import JobRecord
from app.main import app, jobs
from app.models import ProgressEvent


def test_get_job_snapshot():
    job_id = uuid4().hex
    jobs.jobs[job_id] = JobRecord(job_id)
    jobs.events[job_id] = queue.Queue()
    jobs._emit(job_id, ProgressEvent(stage="download", pct=20.0))
    response = TestClient(app).get(f"/jobs/{job_id}")
    assert response.status_code == 200
    assert response.json()["latest"]["pct"] == 20.0


def test_cancel_job():
    job_id = uuid4().hex
    jobs.jobs[job_id] = JobRecord(job_id)
    jobs.events[job_id] = queue.Queue()
    response = TestClient(app).post(f"/jobs/{job_id}/cancel")
    assert response.status_code == 200
    assert response.json()["status"] == "cancelling"


def test_unknown_job_returns_404():
    client = TestClient(app)
    assert client.get("/jobs/missing").status_code == 404
    assert client.post("/jobs/missing/cancel").status_code == 404
```

Move the repeated setup into a pytest fixture after the tests fail. The fixture writes directly to the manager's existing record/event collections and removes both entries during teardown; do not add production test-only methods.

- [ ] **Step 2: Run and verify route failures**

Run: `.venv/bin/pytest -q tests/test_job_api.py`

Expected: 404 or route-not-found failures.

- [ ] **Step 3: Wire structured progress into both pipelines**

In `_process` and `_process_split`, map `DownloadProgress` fields into `ProgressEvent`. Pass `record.token` to downloader, encoder, splitter, and tagger. Emit:

- `download` events from yt-dlp.
- `encode` events from ffmpeg.
- `split` events before and after each cut with `track_state="cutting"`.
- `tag` events per file with `track_state="tagging"`.
- `done`, `error`, or `cancelled` exactly once.

- [ ] **Step 4: Add job routes**

```python
@app.get("/jobs/{job_id}", response_model=JobSnapshot)
def job_endpoint(job_id: str) -> JobSnapshot:
    try:
        return jobs.get_snapshot(job_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Unknown job")


@app.post("/jobs/{job_id}/cancel", response_model=JobSnapshot)
def cancel_job_endpoint(job_id: str) -> JobSnapshot:
    try:
        return jobs.request_cancel(job_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Unknown job")
```

- [ ] **Step 5: Preserve SSE compatibility**

Keep SSE as `data: <ProgressEvent JSON>\n\n`. Do not remove `pct`, `message`, `stage`, or `file_path`. Stop removing terminal records from the job map when the stream closes.

- [ ] **Step 6: Run the complete Python suite**

Run: `.venv/bin/pytest -q`

Expected: all existing and new tests pass; only the existing optional smoke skip is allowed.

---

## Milestone 2: Native workflow

### Task 5: macOS 26 platform and typed API client

**Files:**
- Modify: `macos/Package.swift`
- Create: `macos/Sources/SetlistMac/API/APIModels.swift`
- Create: `macos/Sources/SetlistMac/API/SSEDecoder.swift`
- Create: `macos/Sources/SetlistMac/API/SetlistAPI.swift`
- Create: `macos/Tests/SetlistMacTests/APIModelsTests.swift`
- Create: `macos/Tests/SetlistMacTests/SSEDecoderTests.swift`
- Create: `macos/Tests/SetlistMacTests/SetlistAPITests.swift`

**Interfaces:**
- Produces: `SetlistAPIProtocol`, `SetlistAPI`, `APIProgressEvent`, `APIJobSnapshot`, and `SSEDecoder`.
- Consumes: backend JSON contracts from Milestone 1.

- [ ] **Step 1: Raise the platform and tools versions**

Set `// swift-tools-version: 6.2` and `.macOS(.v26)` in `Package.swift`. Keep the executable and test target names unchanged.

- [ ] **Step 2: Write failing Codable tests**

```swift
func testLegacyProgressPayloadDecodes() throws {
    let data = #"{"stage":"download","pct":25,"message":"Downloading"}"#.data(using: .utf8)!
    let event = try JSONDecoder().decode(APIProgressEvent.self, from: data)
    XCTAssertEqual(event.stage, .download)
    XCTAssertEqual(event.stagePercent, 25)
    XCTAssertNil(event.trackIndex)
}

func testRichProgressPayloadDecodes() throws {
    let data = #"{"stage":"split","pct":50,"stage_pct":50,"overall_pct":80,"message":"Cutting","track_index":2,"track_count":4,"track_title":"Second","track_state":"cutting"}"#.data(using: .utf8)!
    let event = try JSONDecoder().decode(APIProgressEvent.self, from: data)
    XCTAssertEqual(event.overallPercent, 80)
    XCTAssertEqual(event.trackState, .cutting)
}
```

- [ ] **Step 3: Define exact Swift API models**

Create Codable value types mirroring `MetadataFields`, `Track`, `Tracklist`, `ResolveResponse`, download requests, `APIProgressEvent`, and `APIJobSnapshot`. Use snake-case conversion:

```swift
static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()
```

`APIProgressEvent.stagePercent` returns `stagePct ?? pct`.

Declare API value types as `Codable, Equatable, Sendable` so workflow state remains comparable and safely crosses concurrency boundaries.

- [ ] **Step 4: Write and implement incremental SSE parsing**

Test two events split across arbitrary byte chunks. Implement `SSEDecoder.append(_:) -> [Data]` with an internal byte buffer split on `\n\n`; return only `data:` payloads and retain an incomplete tail.

- [ ] **Step 5: Implement the typed client**

Define:

```swift
protocol SetlistAPIProtocol: Sendable {
    func resolve(url: String) async throws -> APIResolveResponse
    func autoTracklist(query: String, url: String, duration: Int) async throws -> APITracklist
    func parseTracklist(text: String, duration: Int) async throws -> APITracklist
    func submit(_ request: APIDownloadRequest) async throws -> String
    func submitSplit(_ request: APISplitDownloadRequest) async throws -> String
    func progress(jobID: String) -> AsyncThrowingStream<APIProgressEvent, Error>
    func job(jobID: String) async throws -> APIJobSnapshot
    func cancel(jobID: String) async throws -> APIJobSnapshot
}
```

`SetlistAPI` uses `URLSession.bytes(for:)` for SSE and checks every HTTP status before decoding.

- [ ] **Step 6: Verify Swift API tests**

Run: `swift test --package-path macos --filter 'APIModelsTests|SSEDecoderTests|SetlistAPITests'`

Expected: all focused tests pass with no warnings.

### Task 6: SwiftData history and workflow state machine

**Files:**
- Create: `macos/Sources/SetlistMac/History/HistoryRecord.swift`
- Create: `macos/Sources/SetlistMac/History/HistoryStore.swift`
- Create: `macos/Sources/SetlistMac/Workflow/WorkflowState.swift`
- Create: `macos/Sources/SetlistMac/Workflow/WorkflowController.swift`
- Create: `macos/Tests/SetlistMacTests/HistoryStoreTests.swift`
- Create: `macos/Tests/SetlistMacTests/WorkflowControllerTests.swift`

**Interfaces:**
- Produces: `HistoryRecord`, `HistoryStoreProtocol`, `WorkflowState`, `WorkflowController`.
- Consumes: `SetlistAPIProtocol` and `API*` value types.

- [ ] **Step 1: Write failing workflow transition tests**

```swift
@MainActor
func testResolveMovesFromResolvingToReviewing() async throws {
    let api = StubAPI(resolveResponse: .fixture)
    let history = InMemoryHistoryStore()
    let controller = WorkflowController(api: api, history: history)

    await controller.resolve("https://youtu.be/abcdefghijk")

    guard case .reviewing(let draft) = controller.state else {
        return XCTFail("Expected reviewing")
    }
    XCTAssertEqual(draft.videoID, "abcdefghijk")
    XCTAssertEqual(history.records.count, 1)
}

@MainActor
func testInterruptedRecordsAreMarkedOnLaunch() throws {
    let history = InMemoryHistoryStore(records: [.fixture(status: .processing)])
    history.markActiveJobsInterrupted()
    XCTAssertEqual(history.records[0].status, .interrupted)
}
```

- [ ] **Step 2: Define persistence and workflow types**

Use a SwiftData `@Model final class HistoryRecord` with:

```swift
@Attribute(.unique) var id: UUID
var backendJobID: String?
var sourceURL: String
var videoID: String?
var title: String
var artist: String
var artworkData: Data?
var statusRawValue: String
var stageRawValue: String?
var errorSummary: String?
var metadataJSON: Data?
var tracklistJSON: Data?
var outputPaths: [String]
var createdAt: Date
var updatedAt: Date
var completedAt: Date?
var importedAt: Date?
```

Use computed enum accessors that fall back safely when old raw values are unknown.

- [ ] **Step 3: Implement the state machine**

```swift
enum WorkflowState: Equatable {
    case idle
    case resolving(ResolvePhase)
    case reviewing(SetDraft)
    case processing(ProcessingState)
    case completed(CompletedJob)
    case failed(FailedJob)
}
```

`WorkflowController` is `@MainActor @Observable`. It owns one resolve task, one tracklist task, and one progress task. Starting a new resolve cancels previous resolve/tracklist tasks. Starting processing freezes the current `SetDraft` into request values.

- [ ] **Step 4: Persist all state changes**

Create a history record before calling `/resolve`. Update it when metadata arrives, when backend job ID is assigned, on every stage change, and on every terminal outcome. On app startup, convert stored resolving/processing records to Interrupted.

- [ ] **Step 5: Verify history and state tests**

Run: `swift test --package-path macos --filter 'HistoryStoreTests|WorkflowControllerTests'`

Expected: all tests pass with deterministic stub APIs and an in-memory SwiftData container.

### Task 7: Native Liquid Glass shell, landing, and Recent

**Files:**
- Move/replace: `macos/Sources/SetlistMac/SetlistMacApp.swift`
- Create: `macos/Sources/SetlistMac/App/SetlistMacApp.swift`
- Create: `macos/Sources/SetlistMac/App/AppDelegate.swift`
- Create: `macos/Sources/SetlistMac/Design/SetlistTheme.swift`
- Create: `macos/Sources/SetlistMac/Views/RootView.swift`
- Create: `macos/Sources/SetlistMac/Views/RecentSidebar.swift`
- Create: `macos/Sources/SetlistMac/Views/LandingView.swift`
- Create: `macos/Sources/SetlistMac/Views/ResolveLoadingView.swift`
- Create: `macos/Tests/SetlistMacTests/LandingIntentTests.swift`

**Interfaces:**
- Produces: native app shell that renders `WorkflowState`.
- Consumes: `BackendController`, `WorkflowController`, and SwiftData model container.

- [ ] **Step 1: Write failing URL intent tests**

Extract pure validation:

```swift
func testYouTubeURLValidation() {
    XCTAssertTrue(YouTubeURLValidator.isValid("https://youtu.be/abcdefghijk"))
    XCTAssertTrue(YouTubeURLValidator.isValid("https://www.youtube.com/watch?v=abcdefghijk"))
    XCTAssertFalse(YouTubeURLValidator.isValid("https://example.com/video"))
}
```

- [ ] **Step 2: Build the app environment**

`SetlistMacApp` creates the SwiftData container, `SetlistAPI`, `HistoryStore`, and `WorkflowController`. The existing menu-bar extra remains. `Window("Setlist", id: "setlist")` renders `RootView`.

Move the current `@main` declaration into `App/SetlistMacApp.swift`, move the delegate into `App/AppDelegate.swift`, and delete the old root-level `SetlistMacApp.swift` in the same step so the executable has exactly one entry point.

- [ ] **Step 3: Build the hybrid shell**

Use `NavigationSplitView`:

```swift
NavigationSplitView {
    RecentSidebar(
        records: history.records,
        selection: $selectedRecordID,
        newSet: workflow.startOver
    )
    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
} detail: {
    WorkflowDetailView(workflow: workflow)
}
```

Use system sidebar materials. Apply `.glassEffect()` only to the paste action surface and floating engine recovery controls. Group nearby effects inside `GlassEffectContainer(spacing: 16)`.

- [ ] **Step 4: Build landing and resolving skeletons**

Landing has one URL field, Resolve button, paste-from-clipboard command, and keyboard shortcut Return. Resolve loading uses redacted native content and a restrained shimmer disabled under Reduce Motion. Named phases are always visible.

- [ ] **Step 5: Remove the full-window web view**

Delete `macos/Sources/SetlistMac/WebView.swift` after `RootView` no longer references it. Keep backend startup and recovery views native.

- [ ] **Step 6: Compile and run tests**

Run:

```bash
swift test --package-path macos
swift build --package-path macos --configuration release
```

Expected: all tests and release compilation pass with no warnings.

### Task 8: Metadata, tracklist, and scoped YouTube player

**Files:**
- Create: `macos/Sources/SetlistMac/Views/ReviewView.swift`
- Create: `macos/Sources/SetlistMac/Views/MetadataEditor.swift`
- Create: `macos/Sources/SetlistMac/Views/TracklistEditor.swift`
- Create: `macos/Sources/SetlistMac/Views/YouTubePlayerView.swift`
- Create: `macos/Tests/SetlistMacTests/TracklistEditingTests.swift`
- Create: `macos/Tests/SetlistMacTests/ReviewValidationTests.swift`

**Interfaces:**
- Produces: editable `SetDraft` and validation errors.
- Consumes: reviewing state and controller intents.

- [ ] **Step 1: Write failing tracklist and validation tests**

```swift
func testMoveTrackPreservesOrderAndValues() {
    var draft = SetDraft.fixture(tracks: [.named("A"), .named("B"), .named("C")])
    draft.moveTrack(from: 2, to: 0)
    XCTAssertEqual(draft.tracks.map(\.title), ["C", "A", "B"])
}

func testSplitValidationIdentifiesMissingCue() {
    let draft = SetDraft.fixture(
        split: true,
        tracks: [.init(start: 0, title: "A"), .init(start: nil, title: "B")]
    )
    XCTAssertEqual(draft.validationIssues, [.missingStart(trackIndex: 1)])
}
```

- [ ] **Step 2: Implement metadata editor**

Use native `Form` sections or aligned `Grid` fields for title, artist, album, album artist, year, genre, compilation, format, and split toggle. Bind directly to a draft owned by `WorkflowController`.

- [ ] **Step 3: Implement tracklist editor**

Use a native `List` with drag reordering, add/remove actions, editable time/title/artist fields, source status, and row-level validation. Clicking the cue sends `player.seek(seconds:)`.

- [ ] **Step 4: Implement the scoped player**

`YouTubePlayerView` loads a minimal local HTML string containing only the YouTube IFrame API host element and a message handler. Native code exposes:

```swift
func load(videoID: String)
func seek(to seconds: Double)
```

Do not load the Setlist web application. Restrict navigation to YouTube player origins and cancel external navigation.

- [ ] **Step 5: Connect auto and manual tracklist flows**

Run `autoTracklist` after basic resolve returns. Apply a nonempty result only when the user has not edited the current tracklist since lookup began. Manual paste calls `parseTracklist` and replaces rows after confirmation when edits exist.

- [ ] **Step 6: Verify review behavior**

Run: `swift test --package-path macos --filter 'TracklistEditingTests|ReviewValidationTests'`

Expected: all tests pass.

---

## Milestone 3: Processing and completion

### Task 9: Native processing scene and per-track progress

**Files:**
- Create: `macos/Sources/SetlistMac/Views/ProcessingView.swift`
- Create: `macos/Sources/SetlistMac/Views/StageRail.swift`
- Create: `macos/Sources/SetlistMac/Views/TrackProgressList.swift`
- Create: `macos/Sources/SetlistMac/Views/TrackSlipCanvas.swift`
- Create: `macos/Tests/SetlistMacTests/ProcessingReducerTests.swift`
- Create: `macos/Tests/SetlistMacTests/TrackSlipModelTests.swift`

**Interfaces:**
- Produces: `ProcessingState.apply(_ event:)` and `TrackSlipModel`.
- Consumes: rich `APIProgressEvent` stream.

- [ ] **Step 1: Write failing progress reducer tests**

```swift
func testSplitEventUpdatesOnlyActiveTrack() {
    var state = ProcessingState.fixture(trackCount: 3)
    state.apply(.fixture(
        stage: .split,
        trackIndex: 2,
        trackCount: 3,
        trackTitle: "Second",
        trackState: .cutting
    ))
    XCTAssertEqual(state.tracks[0].state, .pending)
    XCTAssertEqual(state.tracks[1].state, .cutting)
    XCTAssertEqual(state.currentTrackLabel, "Track 2 of 3")
}

func testReadyTransitionCreatesOneSlip() {
    var model = TrackSlipModel()
    model.apply(trackIndex: 2, title: "Second", state: .ready)
    model.apply(trackIndex: 2, title: "Second", state: .ready)
    XCTAssertEqual(model.slips.count, 1)
}
```

- [ ] **Step 2: Implement progress state reduction**

`ProcessingState.apply(_:)` updates stage, active percentage, overall percentage, byte/speed/ETA fields, and per-track state. Repeated events are idempotent. Terminal events move the workflow controller exactly once.

- [ ] **Step 3: Build stage and track presentation**

`StageRail` shows Download, Encode, Split, Tag, Complete with checkmarks for completed stages and an animated active indicator. `TrackProgressList` shows every track's status and scrolls the active row into view without stealing keyboard focus.

- [ ] **Step 4: Build the signature animation**

Use `Canvas` plus `TimelineView(.animation)` for track trajectories. Create a slip only on a real transition to `ready`. Use a quadratic Bézier path from artwork to the Music destination. Keep each slip animation under 700 ms and remove settled particles from the active canvas.

Under `@Environment(\.accessibilityReduceMotion)`, replace the canvas path with a 200 ms opacity transition and preserve the ready state.

- [ ] **Step 5: Wire cancellation**

Cancel presents confirmation, calls `api.cancel(jobID:)`, waits for a terminal cancelled snapshot, records Cancelled, and returns to history. Disable duplicate cancel requests.

- [ ] **Step 6: Verify processing tests and release build**

Run:

```bash
swift test --package-path macos --filter 'ProcessingReducerTests|TrackSlipModelTests'
swift build --package-path macos --configuration release
```

Expected: all pass without concurrency warnings.

### Task 10: Apple Music import and completion state

**Files:**
- Create: `macos/Sources/SetlistMac/Music/MusicImporter.swift`
- Create: `macos/Sources/SetlistMac/Views/CompletionView.swift`
- Create: `macos/Tests/SetlistMacTests/MusicImporterTests.swift`
- Modify: `scripts/build_macos_app.sh`

**Interfaces:**
- Produces: `MusicImporting.importFiles(_:) async throws -> MusicImportResult`.
- Consumes: completed output paths.

- [ ] **Step 1: Write failing importer tests**

```swift
func testImporterPreservesTrackOrder() async throws {
    let runner = RecordingAppleScriptRunner(result: .success("3"))
    let importer = MusicImporter(runner: runner)
    let files = [URL(fileURLWithPath: "/tmp/01.m4a"), URL(fileURLWithPath: "/tmp/02.m4a")]
    _ = try await importer.importFiles(files)
    XCTAssertTrue(runner.lastSource.contains("01.m4a"))
    XCTAssertLessThan(
        runner.lastSource.range(of: "01.m4a")!.lowerBound,
        runner.lastSource.range(of: "02.m4a")!.lowerBound
    )
}

func testPermissionDenialMapsToActionableError() async {
    let runner = RecordingAppleScriptRunner(result: .failure(status: -1743))
    let importer = MusicImporter(runner: runner)
    do {
        _ = try await importer.importFiles([.init(fileURLWithPath: "/tmp/a.m4a")])
        XCTFail("Expected permission denial")
    } catch {
        XCTAssertEqual(error as? MusicImportError, .automationPermissionDenied)
    }
}
```

- [ ] **Step 2: Define an injectable AppleScript runner**

```swift
protocol AppleScriptRunning: Sendable {
    func run(source: String) async throws -> String
}

protocol MusicImporting: Sendable {
    func importFiles(_ files: [URL]) async throws -> MusicImportResult
}
```

The production runner executes `NSAppleScript` on the main actor and maps error number `-1743` to automation permission denial.

- [ ] **Step 3: Implement deterministic import**

Generate AppleScript that:

1. Launches Music.
2. Adds each POSIX file to `library playlist 1` in output order.
3. Returns the count added.
4. Activates Music after success.

Escape file paths as AppleScript string literals; never interpolate unescaped user-controlled text.

- [ ] **Step 4: Build the completion view**

Show artwork, title, track count, output path, **Add N tracks to Apple Music**, Reveal in Finder, and Start Another Set. Disable import while running. On success, persist `importedAt` and replace the CTA with **Open in Music**.

- [ ] **Step 5: Add bundle metadata**

Update `build_macos_app.sh` to insert:

```text
NSAppleEventsUsageDescription =
"Setlist adds your completed, tagged tracks to your Apple Music library when you choose Add to Apple Music."
```

For this personal ad-hoc, non-sandboxed build, add the usage description and do not add an entitlements file. Hardened-runtime distribution is outside this plan.

- [ ] **Step 6: Verify importer and bundle**

Run:

```bash
swift test --package-path macos --filter MusicImporterTests
./scripts/build_macos_app.sh
codesign --verify --deep --strict --verbose=2 dist/Setlist.app
plutil -lint dist/Setlist.app/Contents/Info.plist
```

Expected: tests pass and bundle verification succeeds.

---

## Milestone 4: Personal release polish

### Task 11: Safe lifecycle, engine identity, and interruption recovery

**Files:**
- Modify: `macos/Sources/SetlistMac/Backend/BackendController.swift`
- Modify: `macos/Sources/SetlistMac/App/AppDelegate.swift`
- Modify: `macos/Sources/SetlistMac/Views/RootView.swift`
- Modify: `macos/Tests/SetlistMacTests/BackendControllerTests.swift`
- Create: `macos/Tests/SetlistMacTests/AppTerminationTests.swift`

**Interfaces:**
- Produces: compatible-engine detection and safe quit intent.
- Consumes: workflow active-state and history interruption APIs.

- [ ] **Step 1: Add failing compatible-health tests**

```swift
func testRejectsUnrelatedHealthyServer() async {
    let controller = BackendController(
        configuration: configuration,
        healthCheck: { _ in .init(status: "ok", app: "Other") },
        launcher: launcher
    )
    await controller.start()
    XCTAssertTrue(launcher.didLaunch)
}

func testQuitRequiresConfirmationDuringProcessing() {
    let policy = TerminationPolicy(state: .processing(.fixture))
    XCTAssertEqual(policy.action, .confirmCancellation)
}
```

- [ ] **Step 2: Decode health identity**

Replace boolean health checks with a Codable `HealthResponse(status: String, app: String)`. Attach only when `status == "ok"` and `app == "Setlist"`.

- [ ] **Step 3: Implement safe termination**

When idle or completed, terminate normally and stop only an owned backend. During resolving or processing, reply `.terminateLater`, show confirmation, call workflow cancellation, persist the terminal state, stop the backend, then call `NSApp.reply(toApplicationShouldTerminate: true)`.

- [ ] **Step 4: Verify lifecycle tests**

Run: `swift test --package-path macos --filter 'BackendControllerTests|AppTerminationTests'`

Expected: all pass.

### Task 12: Accessibility, end-to-end verification, and documentation

**Files:**
- Modify: all native views created in Tasks 7–10
- Create: `macos/Tests/SetlistMacTests/AccessibilityStateTests.swift`
- Create: `tests/test_native_contract.py`
- Modify: `README.md`
- Modify: `scripts/build_macos_app.sh`

**Interfaces:**
- Produces: verified personal release artifact.
- Consumes: all prior tasks.

- [ ] **Step 1: Add accessibility state tests**

Test that stage labels, track statuses, icon-only controls, and progress values expose nonempty accessibility labels. Test that Reduce Motion selects the crossfade animation model.

- [ ] **Step 2: Add backend/native contract tests**

`tests/test_native_contract.py` validates that `/health`, `/resolve`, `/download-split`, rich SSE events, `/jobs/{id}`, and cancellation serialize fields expected by `APIModels.swift`, including legacy `pct`.

- [ ] **Step 3: Audit keyboard and VoiceOver behavior**

Verify:

- Command-N starts a new set.
- Command-O opens the window.
- Return submits a valid URL.
- Escape dismisses transient confirmation UI.
- Tab order follows visible workflow order.
- Track reordering has accessible move actions.
- Progress announcements are throttled to stage and 10% boundaries.

- [ ] **Step 4: Update documentation**

Document the native flow, macOS 26 requirement, single active job, explicit Music import permission, Reduce Motion behavior, build command, and browser UI compatibility in `README.md`.

- [ ] **Step 5: Run complete verification**

Run:

```bash
.venv/bin/pytest -q
swift test --package-path macos
swift build --package-path macos --configuration release
./scripts/build_macos_app.sh
codesign --verify --deep --strict --verbose=2 dist/Setlist.app
plutil -lint dist/Setlist.app/Contents/Info.plist
git diff --check
```

Expected:

- Python suite has zero failures.
- Swift suite has zero failures.
- Release build succeeds without warnings.
- App signature and plist validate.
- Diff check reports no whitespace errors.

- [ ] **Step 6: Run the opt-in smoke path**

With a user-provided test URL and permission to make the network request:

```bash
RUN_SMOKE=1 .venv/bin/pytest tests/test_smoke.py -v
```

Then open `dist/Setlist.app`, resolve the same URL, verify native progress reaches completion, use Reveal in Finder, and test Add to Apple Music only after explicit confirmation.

- [ ] **Step 7: Final review checkpoint**

Review `git status --short` and the full diff. Confirm no `.env`, downloaded media, API keys, generated app bundle, or local SwiftData database is staged. Do not commit or push without explicit user permission.

