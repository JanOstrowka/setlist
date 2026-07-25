# Setlist Native macOS App Design

**Date:** 2026-07-25  
**Status:** Approved design  
**Target:** Personal-use macOS 26 app

## Summary

Setlist will replace its full-window web wrapper with a native SwiftUI interface built for macOS 26 and Liquid Glass. The existing Python/FastAPI media engine remains responsible for YouTube resolution, tracklist parsing, downloads, ffmpeg processing, tagging, and file output. SwiftUI becomes the complete product surface and communicates with the engine through a typed local API.

The app uses a hybrid spatial model:

1. A calm landing view with Recent history and one primary paste action.
2. A denser production workspace for metadata, YouTube preview, and tracklist editing.
3. An immersive full-window processing and completion experience.

The first release is for the owner's Mac. Public distribution, notarization, bundled media dependencies, and automatic updates remain later work.

## Product decisions

- Minimum operating system: macOS 26.
- UI technology: native SwiftUI with system Liquid Glass.
- App presence: menu-bar resident with one native main window and menu actions for Open, New Set, and Quit.
- Processing engine: existing Python/FastAPI service.
- YouTube preview: a scoped `WKWebView` using the YouTube IFrame player.
- Concurrency: one active set at a time; no multi-job queue.
- History: all jobs, including resolving, processing, completed, cancelled, interrupted, and failed.
- Apple Music handoff: explicit **Add to Apple Music** completion CTA.
- Active work is not resumable in the first release.
- The existing browser UI and hosted integration remain compatible while the native client is developed.

## Goals

- Make the primary workflow feel like a first-class Mac application.
- Show clear, truthful loading and processing state at every step.
- Make every split track's progress visible.
- Preserve the proven download, split, and tagging pipeline.
- Add durable native history and deterministic Apple Music import.
- Use one memorable completion animation that communicates real work.
- Respect Reduce Motion and standard macOS accessibility behavior.

## Non-goals

- Rewriting yt-dlp, ffmpeg processing, or metadata tagging in Swift.
- Parallel downloads or a multi-job processing queue.
- Resuming a partially downloaded or encoded job after restart.
- Public distribution, App Store sandboxing, notarization, or automatic updates.
- Replacing the existing hosted web UI.
- Building a fully native YouTube playback stack.

## Experience state machine

The native app has one explicit workflow state:

```text
idle
  → resolving
  → reviewing
  → processing
  → completed

resolving | reviewing | processing
  → failed | cancelled | interrupted

completed | failed | cancelled | interrupted
  → idle
```

Only valid state transitions are exposed by the feature model. View code renders state and sends user intents; it does not directly coordinate networking or processes.

## Screen design

### 1. Landing and Recent

The app opens with a `NavigationSplitView`.

The sidebar contains:

- New Set
- Recent jobs ordered by latest activity
- Artwork thumbnail
- Set title and artist
- Status badge
- Track count when known
- Import status for completed jobs

The detail view contains one dominant URL paste field and a Resolve action. A valid YouTube URL pasted from the clipboard begins resolution after a short debounce. The user can also submit explicitly.

Selecting a Recent item opens its persistent detail state. Completed jobs expose Add/Open in Music and Reveal in Finder. Failed, cancelled, and interrupted jobs expose their status, diagnostic summary, and Retry.

### 2. Resolve loading

Resolve uses progressive disclosure and skeletons rather than fake percentages:

1. **Reading YouTube details** — artwork and metadata skeletons.
2. **Preparing artwork and tags** — fields resolve into place.
3. **Finding a tracklist** — shimmering track rows.
4. **Ready to review** — skeletons crossfade into editable content.

Basic YouTube metadata is shown as soon as `/resolve` completes. The separate automatic tracklist lookup continues without blocking review. A failed 1001tracklists lookup falls back to YouTube chapters, description timestamps, or manual editing.

### 3. Production workspace

The review state expands into a two-pane workspace.

The leading pane contains:

- Square artwork
- Title
- Artist
- Album
- Album Artist
- Year
- Genre
- Compilation
- Output format
- Split into tracks

The main pane contains:

- Scoped YouTube `WKWebView` player
- Tracklist source and fetch/paste controls
- Native editable track rows
- Start time, title, and artist
- Add, remove, and reorder actions
- Track count and timing validation

Selecting a track time seeks the YouTube player. The web view is an isolated playback component; no other app UI is HTML.

### 4. Processing

Starting a download freezes an immutable snapshot of the reviewed metadata and tracklist. The editor transitions out and processing fills the window without forcing macOS system full-screen mode.

The processing scene contains:

- Album artwork
- Current stage and human-readable action
- Stage rail: Download → Encode → Split → Tag → Complete
- Active-stage percentage
- Overall progress ring
- Current track title and `Track N of M`
- Expandable per-track status list
- Downloaded bytes and ETA when available
- Secondary Cancel action

Per-track states are:

```text
pending → cutting → tagging → ready
```

Single-track jobs use the same screen without the split-track list.

### 5. Completion

Completion presents:

- Finished artwork and metadata
- Track count and output location
- Primary **Add N tracks to Apple Music** CTA
- Secondary Reveal in Finder
- Secondary Start Another Set

Successful import changes the primary action to **Open in Music** and records the import timestamp in history.

## Visual system

The app uses macOS 26 system materials and Liquid Glass APIs instead of imitated glassmorphism.

Principles:

- Glass is reserved for navigation, controls, and floating process surfaces.
- Content such as artwork and track rows remains visually solid and readable.
- System typography is used to preserve a native Mac character.
- Artwork-derived color may tint the processing background, but text and controls retain accessible contrast.
- The layout avoids nested cards and decorative glass on every surface.
- Window resizing preserves a usable editor at the minimum size and expands tracklist density on larger windows.

## Motion system

Motion communicates state and progress.

### Standard transitions

- Button feedback: 100–150 ms.
- Field and status transitions: 200–300 ms.
- Layout changes: 300–450 ms.
- Workflow state transitions: 450–700 ms.
- Exit motion is approximately 75% of entrance duration.
- Motion uses natural deceleration and avoids bounce or elastic easing.

### Signature processing animation

Album artwork floats at the center of the processing scene. Each real track completion emits one small glass track slip containing its number and title. The slip follows a curved path and settles into a stylized Mac/Music destination. The animation count is driven by actual ready-track events; decorative tracks are never invented.

When all tracks are complete:

1. Remaining track slips settle.
2. The stage rail collapses into a success mark.
3. Artwork settles into the completion layout.
4. The Apple Music CTA appears.

The completion choreography must not block interaction for longer than 700 ms.

### Reduced Motion

When Reduce Motion is enabled:

- Curved track trajectories become opacity crossfades.
- Matched-geometry movement becomes short dissolves.
- Progress and status remain fully visible.
- No information depends on animation.

## Native architecture

### Swift modules

`SetlistMacApp`
- App entry point, menu-bar commands, main-window activation, and lifecycle.

`BackendSupervisor`
- Starts, detects, monitors, and stops the Python engine.
- Attaches to an existing compatible Setlist engine without claiming ownership.
- Stops only a process launched by this app.
- Supplies Homebrew paths required by ffmpeg.

`SetlistAPI`
- Typed `URLSession` client.
- Codable request and response models.
- Server-sent event decoding as `AsyncSequence`.
- Request cancellation and consistent error mapping.

`WorkflowFeature`
- Main state machine.
- Coordinates resolve, tracklist, review, processing, completion, and recovery.
- Contains no view code.

`HistoryStore`
- SwiftData persistence for all user-visible jobs.
- Marks active work Interrupted after an unclean app exit.
- Reconciles completed output paths with the filesystem.

`YouTubePlayerView`
- Narrow `WKWebView` wrapper for the YouTube IFrame player.
- Loads only the selected video and exposes native seek intents.

`MusicImporter`
- Adds generated files to Apple Music after explicit confirmation.
- Reports permission and per-file failures.

`ProcessingScene`
- Stage rail, progress presentation, track states, and motion choreography.

### Python engine

The existing FastAPI application remains the source of truth for media processing. It gains:

- Structured progress data.
- Actual ffmpeg encoding progress.
- Per-track split and tag progress.
- Cooperative cancellation.
- A stable terminal job result endpoint.
- Backward-compatible defaults for existing web clients.

The first personal build continues to run the engine from the repository virtual environment. The native app keeps the project root in its generated bundle metadata, matching the existing wrapper approach.

## API changes

### Health

`GET /health` remains public and must return the expected app identity. The native app attaches only when both the status and app name match.

### Resolve

The native client continues to call:

- `POST /resolve`
- `POST /auto-tracklist`
- `POST /parse-tracklist`

These remain separate so basic metadata can appear before the slower optional tracklist lookup finishes.

### Processing

The existing submission routes remain:

- `POST /download`
- `POST /download-split`

Each returns a stable job ID.

`GET /progress/{job_id}` continues streaming SSE but its event payload expands to:

```json
{
  "stage": "split",
  "pct": 58.3,
  "stage_pct": 58.3,
  "overall_pct": 81.7,
  "message": "Cutting track 7 of 12",
  "track_index": 7,
  "track_count": 12,
  "track_title": "Example Track",
  "track_state": "cutting",
  "downloaded_bytes": null,
  "total_bytes": null,
  "speed_bytes_per_second": null,
  "eta_seconds": null,
  "file_path": null
}
```

The existing `pct` field remains as a stage-percentage alias for the current web client. All other new fields are optional.

Additional routes:

- `POST /jobs/{job_id}/cancel` — requests cooperative cancellation.
- `GET /jobs/{job_id}` — returns current or terminal job state after an SSE disconnect.

The terminal job response includes status, latest progress event, output paths, and error summary. Terminal jobs remain queryable until the engine restarts; durable user history belongs to SwiftData.

## Progress measurement

### Resolve

Resolve and tracklist fetching are indeterminate network operations. They use named steps and skeletons, not numeric percentages.

### Download

yt-dlp progress hooks provide:

- Downloaded bytes
- Total or estimated bytes
- Stage percentage
- Speed when available
- ETA when available

### Encode

ffmpeg runs with machine-readable progress output. `out_time` divided by known input duration produces actual encoding percentage.

### Split

Each completed cut advances `track_index / track_count`. The active row is `cutting`.

### Tag

The album tagger emits a callback after each file is tagged. The active row is `tagging`; completed rows become `ready`.

### Overall progress

The overall ring maps actual within-stage progress onto stable spans:

- Download: 0–40%
- Encode: 40–70%
- Split: 70–90%
- Tag and save: 90–100%

The UI labels only the active-stage percentage numerically. The weighted overall ring is visual and does not claim a whole-job ETA.

## Cancellation and interruption

Each job owns a cancellation token checked between pipeline stages and files. The in-process yt-dlp progress hook raises a dedicated cancellation exception; active ffmpeg subprocesses receive termination. Temporary directories are then cleaned and the job emits a terminal `cancelled` event.

If the app exits while it owns the engine, the engine receives SIGTERM. On the next launch, SwiftData jobs left in resolving or processing states become Interrupted. The first release restarts interrupted jobs from the beginning rather than resuming partial media.

Quitting while a job is active requires explicit confirmation. The app never silently terminates an active download.

## History model

SwiftData stores one record per job:

- Stable native history UUID
- Optional backend processing job ID
- Source URL and YouTube video ID
- Created, updated, completed, and imported timestamps
- Status
- Current or failed stage
- Error summary
- Artwork cache reference
- Editable metadata snapshot
- Tracklist snapshot and track count
- Output format
- Output paths
- Apple Music import status

History is capped by a user-configurable retention policy later; the first release retains all records. Missing output files are shown as missing rather than silently deleting history.

## Apple Music import

The completion CTA imports only after explicit user action.

`MusicImporter` uses Apple Events to ask Music to add the generated `.m4a` files to the library in track order. Embedded Album, Album Artist, artwork, track numbers, compilation, and gapless metadata cause Music to group the files as the intended album.

The first import may trigger the macOS Automation permission prompt. Outcomes:

- Success: mark imported, activate Music, and expose Open in Music.
- Permission denied: explain how to allow Setlist under Privacy & Security → Automation.
- Partial failure: report affected files and retain Reveal in Finder.
- Music unavailable: retain generated files and offer Reveal in Finder.

Import failure never changes or deletes generated files.

The app bundle includes an Apple Events usage description. The personal signing configuration includes the Apple Events automation entitlement when required by the selected signing mode.

## Error handling

- Invalid URL: inline validation without leaving the landing state.
- Resolve failure: preserve the URL and expose Retry.
- Artwork failure: continue with a placeholder.
- Tracklist lookup failure: preserve chapters/manual editing and show a non-blocking notice.
- Validation failure: identify exact track rows missing times or titles.
- Download/encode/split/tag failure: retain the failed stage and plain-language message in history.
- Engine unavailable: show native recovery UI and restart controls.
- SSE disconnect: query `GET /jobs/{job_id}` before declaring failure.
- Quit during processing: require confirmation, then cancel and clean up before terminating.
- Output missing: keep the history record and disable import/reveal actions.
- Import failure: preserve files and fallback actions.

Technical diagnostic details are available behind a disclosure control; they are not the primary error message.

## Accessibility

- Full keyboard navigation and visible focus.
- VoiceOver labels for progress, stage rail, track states, and all icon-only controls.
- Dynamic Type-compatible layout where available on macOS.
- Sufficient contrast over artwork-derived tints.
- Reduce Motion support as specified above.
- Progress changes are announced without flooding VoiceOver for every percentage update.
- No state is communicated only by color or animation.

## Testing

### Swift tests

- Workflow state transition unit tests.
- Codable request, response, and SSE event tests.
- API cancellation and reconnect tests.
- Backend ownership and lifecycle tests.
- SwiftData history persistence and interrupted-job migration tests.
- Tracklist editing and validation tests.
- MusicImporter success, permission denial, partial failure, and fallback tests.
- Reduced Motion presentation tests.

### Python tests

- Structured progress event serialization.
- yt-dlp byte and ETA mapping.
- ffmpeg progress parsing.
- Per-track split and tag callbacks.
- Cancellation during download, encode, split, and tag.
- Stable terminal job retrieval.
- Backward compatibility for existing web clients.

### Integration tests

- Start the engine from the native app and verify identity through `/health`.
- Resolve a fixture response and render the review state.
- Stream a deterministic fake processing job through every stage.
- Disconnect and reconcile through `GET /jobs/{job_id}`.
- Run the existing opt-in network smoke download.
- Verify an output album can be handed to a mocked Music importer in track order.

## Delivery milestones

### Milestone 1: Engine progress foundation

- Expand progress schema.
- Parse real download and encode progress.
- Emit per-track split/tag state.
- Add cancellation and terminal job retrieval.
- Preserve web-client compatibility.

### Milestone 2: Native workflow

- Build native app shell and Liquid Glass navigation.
- Add SwiftData history.
- Implement resolve loading and skeletons.
- Build metadata editor, scoped YouTube player, and tracklist editor.
- Remove the full-window `WKWebView`.

### Milestone 3: Processing and completion

- Build the full-window processing scene.
- Connect structured progress to track rows.
- Implement signature track-slip animation and Reduce Motion behavior.
- Add completion state and Apple Music importer.

### Milestone 4: Personal release polish

- Harden engine lifecycle and recovery.
- Complete keyboard and VoiceOver behavior.
- Profile animation and CPU usage.
- Run all automated and smoke tests.
- Build and ad-hoc sign the personal `.app`.
- Update user documentation.

## Acceptance criteria

- No full-window website is visible anywhere in the native app.
- The only web content is the scoped YouTube player.
- Users can paste a YouTube URL, resolve metadata, edit a tracklist, process it, and import generated tracks without opening a browser.
- Resolve and tracklist loading always show named, honest states.
- Download and encode show real progress.
- Split albums show the active track and status of every track.
- Recent history survives app and engine restarts and includes every terminal status.
- Cancelling cleans temporary files and leaves a Cancelled history record.
- Completion provides explicit Apple Music import and Finder fallback actions.
- Reduce Motion preserves all information without trajectory animation.
- Existing Python tests and hosted web behavior remain operational.
