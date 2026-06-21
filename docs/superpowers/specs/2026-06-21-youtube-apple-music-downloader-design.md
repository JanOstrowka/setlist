# YouTube → Apple Music Downloader — Design Spec (v1)

**Date:** 2026-06-21
**Status:** Approved for implementation (v1). v2 is a future roadmap, not part of the first build.
**Owner:** Personal / single-user tool.

---

## 1. Summary

A personal, local-only macOS tool with a tiny local web front-end. The user pastes a YouTube
URL; the tool downloads the highest-quality audio, converts it **losslessly to Apple-Music-compatible
ALAC `.m4a`**, embeds a square cover from the thumbnail plus AI-assisted metadata, and saves a fully
tagged file into an output folder to **drag into Apple Music manually**.

The user has the right/license to download the audio they target. Be a good network citizen:
respect rate limits and site ToS. (No further legal commentary.)

### Goals (v1)

- One URL in → one perfectly-tagged ALAC `.m4a` out, ready to drag into Apple Music.
- Lossless transcode from YouTube's best audio (no further quality loss beyond the already-lossy source).
- Editable metadata preview before saving, enriched by an LLM + Firecrawl web context.
- Reusable `app/core/` engine so a future CLI and the v2 set-splitter share the same code.

### Non-goals (v1)

- No automatic Apple Music library import (files-only; user drags in).
- No splitting of long sets into per-track albums (that is **v2**, stubbed in the UI only).
- No multi-user, auth, remote hosting, or playlist/batch queue UI (single URL at a time).
- No "hi-res"/upscaling claims — output is never represented as higher quality than the source.

---

## 2. Locked decisions (firm requirements)

| # | Decision | Requirement |
|---|----------|-------------|
| 1 | **Output model** | Files-only. **No** automatic Apple Music import. Write perfectly-tagged ALAC `.m4a` into an output folder (default `~/Music/YouTube Sets`) the user drags into Apple Music. |
| 2 | **Quality/format** | Download YouTube's genuinely best audio (often Opus ~160 kbps, itag 251). Convert **losslessly to ALAC `.m4a`** (ALAC is lossless, so no further loss is added; the source remains the quality ceiling). Apple Music cannot play Opus/WebM, which is why we transcode. Expose an **AAC-256 toggle** for smaller files. **Never** fake-upscale or claim larger-than-source quality. ALAC files are typically **~5–10× the source size**; surface this in the UI. |
| 3 | **Metadata** | Auto-fill a best guess, then show an **editable preview** before saving. Use an **LLM + Firecrawl web enrichment** to derive structured fields from the YouTube title/description/uploader/upload-date plus web context (festival/event/artist pages). LLM provider/model configurable via API key. **Default model: `gpt-4o-mini`** (cheap, fast; `claude-3-5-haiku`-class is the equivalent Anthropic default). If AI fails, **fall back to plain title parsing** and let the user edit manually. |
| 4 | **Front-end (Layout A)** | Single column: URL bar → editable preview card (square cover + Title, Artist, Album, Album Artist, Year, Genre) → a "Detected: bestaudio … → ALAC lossless" format/destination line → **Download & tag** button → live progress → small **Recent** list. Include a **greyed-out, disabled "Split into separate tracks (v2)" toggle** as a placeholder so v2 slots in without a redesign. |
| 5 | **Architecture** | Single-user **local web app**. **Python 3.11+ / FastAPI** backend serving a small static SPA (`web/` = `index.html` + `app.js` + `styles.css`). `yt-dlp` used **as a library** with progress hooks; progress streamed to the UI via **SSE**. `ffmpeg` for the ALAC encode; **mutagen** (with **AtomicParsley** as fallback) writes MP4 tag atoms + cover. Optional local **PO-token provider** sidecar for YouTube bot checks. Core logic lives in a reusable **`app/core/`** engine (`resolver`, `metadata_ai`, `downloader`, `tagger`, `library`) shared by a future CLI and the v2 splitter. |

---

## 3. Architecture

```
Browser (web/ SPA)
   │  fetch JSON + EventSource(SSE)
   ▼
FastAPI app (app/main.py)  ── 127.0.0.1:8765, local only
   │
   ├─ POST /resolve   → core.resolver + core.metadata_ai
   ├─ POST /download  → core.downloader → core.tagger → core.library
   └─ GET  /progress/{job_id} (SSE)
   │
   ▼
app/core/ engine (no FastAPI imports — reusable by CLI + v2)
   resolver.py · metadata_ai.py · downloader.py · tagger.py · library.py
   │
   ├─ yt-dlp (library)   → extract_info / download (+ progress hooks)
   ├─ ffmpeg (subprocess)→ ALAC / AAC-256 encode
   ├─ mutagen / AtomicParsley → MP4 atoms + cover
   ├─ LLM SDK (openai / anthropic) + firecrawl-py → metadata enrichment
   └─ optional PO-token provider sidecar (HTTP) for bot checks
```

**Runtime choices (concrete defaults):**

| Concern | Default |
|---------|---------|
| Bind address | `127.0.0.1:8765` (loopback only; never `0.0.0.0`) |
| Python | 3.11+ |
| Concurrency | One active download at a time; further requests queued FIFO in-memory |
| `yt-dlp` freshness | Best-effort self-update on launch (`pip install -U yt-dlp`, non-blocking; skip silently on failure) |
| System prereqs | `ffmpeg` and (optionally) `AtomicParsley` installed via Homebrew |
| Process model | Single uvicorn process; `run.sh` starts it and opens the browser |

`app/core/` MUST NOT import FastAPI or any web-layer types — it exchanges plain dataclasses/pydantic
models and callbacks (e.g. a `progress_hook(event)` callable) so the CLI and v2 splitter reuse it directly.

---

## 4. Project structure

```
yt-m-automation/
├─ pyproject.toml        # fastapi, uvicorn, yt-dlp, mutagen, httpx, python-dotenv, firecrawl-py, openai/anthropic
├─ .env.example          # API keys + settings (documented; real .env is gitignored)
├─ run.sh                # start server + open browser
├─ app/
│  ├─ main.py            # routes: /resolve, /download, /progress (SSE)
│  ├─ config.py          # settings loaded from .env
│  ├─ core/              # reusable engine (also for CLI + v2)
│  │  ├─ resolver.py     # yt-dlp info + thumbnail
│  │  ├─ metadata_ai.py  # LLM + Firecrawl → structured fields
│  │  ├─ downloader.py   # yt-dlp → ALAC, progress hooks
│  │  ├─ tagger.py       # mutagen atoms + cover
│  │  └─ library.py      # output folder + filenames
│  └─ models.py          # pydantic schemas
├─ web/                  # index.html + app.js + styles.css (single-column UI)
└─ tests/                # test_metadata.py, test_tagger.py
```

---

## 5. v1 data flow (core behavior)

1. **Resolve** — Paste URL → `POST /resolve`. `resolver.py` runs yt-dlp `extract_info(download=False)` →
   title, description, uploader, upload_date, thumbnail URL, available formats, chapters.
2. **Propose metadata** — `metadata_ai.py` feeds that text (+ Firecrawl web context) to the LLM → structured
   fields; the thumbnail is fetched and **center-cropped to a square** for the cover preview.
3. **Preview** — `/resolve` returns the editable proposal to the UI: proposed cover + fields + detected-format line.
4. **Confirm & download** — User edits, confirms → `POST /download`. `downloader.py` runs yt-dlp to fetch
   `bestaudio`, then `ffmpeg` transcodes to **ALAC** (or **AAC-256** if toggled); the thumbnail is converted to
   **JPEG**; `tagger.py` (mutagen) writes the **user-confirmed** tags + cover; `library.py` saves the file to the
   output folder. Progress streams over `GET /progress/{job_id}` (SSE).
5. **Done** — Tagged `.m4a` sits in the output folder, ready to drag into Apple Music.

> **Tagging order:** download → encode **untagged**, then write the final atoms with **mutagen after the user
> confirms**. (Do not rely on yt-dlp/ffmpeg embedding, which is unreliable for ALAC + thumbnail + chapters.)

### 5.1 API endpoints

| Method · Path | Request (body) | Response |
|---|---|---|
| `POST /resolve` | `{ "url": str }` | `ResolveResponse`: proposed metadata fields, `cover` (base64 JPEG data URI, square), `formats` summary, `detected_line` str, `video_id`, `duration`, `has_chapters` bool |
| `POST /download` | `DownloadRequest`: confirmed metadata fields + `format` (`"alac"` \| `"aac256"`) + `video_id` + `cover` (`"keep"` to reuse the server-cached cover, or a data URI to override) | `{ "job_id": str }` (download runs async) |
| `GET /progress/{job_id}` | — (SSE) | `text/event-stream` of progress events (see §5.2) |
| `GET /` and `GET /static/*` | — | Serves `web/index.html` and assets |

### 5.2 SSE progress events

`/progress/{job_id}` emits JSON events: `{ "stage": "download"|"encode"|"tag"|"done"|"error", "pct": 0-100, "message": str }`.
`download` percentages come from the yt-dlp progress hook; `encode`/`tag` report coarse start/finish.
A terminal `done` event includes the final saved file path; an `error` event includes a clear, user-facing message.

### 5.3 Pydantic models (`app/models.py`)

- `MetadataFields`: `title, artist, album, album_artist, year:int|None, genre, comment(source URL), compilation:bool`
- `ResolveResponse`: `video_id, duration, metadata: MetadataFields, cover:str, formats:str, detected_line:str, has_chapters:bool`
- `DownloadRequest`: `video_id, url, metadata: MetadataFields, format: Literal["alac","aac256"], cover: str`
- `ProgressEvent`: `stage, pct, message, file_path: str|None`

---

## 6. Metadata & Apple Music album cohesion

### 6.1 MP4 atom mapping

| Field | MP4 atom | Notes |
|-------|----------|-------|
| Title | `©nam` | |
| Artist | `©ART` | Per-track performing artist |
| Album | `©alb` | The set/event name (or cleaned title) |
| **Album Artist** | **`aART`** | **Drives Apple Music album grouping** — keep consistent across a set |
| Year | `©day` | 4-digit year string |
| Genre | `©gen` | |
| Source URL | `©cmt` (Comment) | Original YouTube URL for provenance |
| Cover | `covr` | **JPEG only** (square-cropped) |
| Track | `trkn` | `(n, total)` |
| Disc | `disk` | `(1, 1)` |
| Compilation | `cpil` | `1` for various-artist sets, else `0` |
| Gapless | `pgap` | `1` (gapless) |

### 6.2 Album cohesion rules

Apple Music groups tracks into **one album by `Album` (`©alb`) + `Album Artist` (`aART`)** — **not** by the
per-track artist (`©ART`). Therefore the tool MUST always:

- Set a **consistent `aART`** across every file intended to be one album.
- Set a **sequential `trkn`** (in v1 a single track is `(1, 1)`).
- Set **`pgap = 1`** (gapless) so continuous mixes play seamlessly.
- Offer **`cpil = 1`** for various-artist sets (UI checkbox, default off in v1).

### 6.3 Cover art

YouTube serves 16:9 **WebP**; WebP/PNG cover embedding into `.m4a` is unreliable. The tool MUST:

1. **Center-crop** the thumbnail to a **square**.
2. Re-encode to **JPEG** (quality 90, max 1400×1400) before embedding into `covr`.

`/resolve` caches this cropped JPEG to a temp path keyed by `video_id` and returns it as a data URI for preview.
On `/download`, `cover = "keep"` embeds that cached file; a data URI instead overrides it with the user's choice.

### 6.4 Field defaults (no ambiguity)

| Field | Default when AI/web yields nothing |
|-------|------------------------------------|
| Title | Cleaned video title (strip `[Official]`, bracketed noise, leading/trailing separators) |
| Artist | AI-derived primary artist → else channel/uploader name |
| Album | AI-derived set/event name → else cleaned video title |
| Album Artist | Same as Artist (for VA sets, `"Various Artists"`) |
| Year | Original release year if found → else upload-date year |
| Genre | AI-derived genre → else empty string (user fills) |
| Comment | Source YouTube URL (always set) |
| Compilation | `false` (user opts in) |

### 6.5 Output filename

`library.py` writes: `"<Album Artist> - <Title> [<video_id>].m4a"`, with characters illegal on macOS/APFS
(`/`, `:`) replaced by `-`. Collisions are avoided via the `[<video_id>]` suffix; an exact-path re-download
overwrites in place.

---

## 7. Front-end (Layout A)

Single static SPA in `web/` (`index.html` + `app.js` + `styles.css`), no framework/build step. Vertical
single-column flow:

1. **URL bar** + "Resolve" action.
2. **Editable preview card**: square cover (left/top) + fields — **Title, Artist, Album, Album Artist, Year, Genre**, a **Compilation** checkbox, and AAC-256 toggle.
3. **Detected line**, e.g. `Detected: bestaudio (251 · opus · ~160 kbps) → ALAC lossless · ~/Music/YouTube Sets`
   (switches to `→ AAC 256 kbps` when the toggle is on). Includes the **~5–10× size** note for ALAC.
4. **Download & tag** button.
5. **Live progress** (consumes the SSE stream; per-stage bar + message).
6. **Recent** list (last 20 saved files; persisted to a small local JSON; click reveals the file in Finder).
7. **Greyed-out, disabled "Split into separate tracks (v2)"** toggle placeholder — present but inert in v1.

UI states: idle → resolving → preview (editable) → downloading (progress) → done (with "Reveal in Finder") / error.

---

## 8. Config & secrets

`.env` (gitignored) holds secrets; `.env.example` (committed) documents **every** key with safe placeholders.

| Setting | Env key | Default |
|---------|---------|---------|
| LLM API key | `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` | — (required for AI enrichment; without it the tool falls back to title parsing) |
| LLM provider | `LLM_PROVIDER` | `openai` |
| LLM model | `LLM_MODEL` | `gpt-4o-mini` |
| Firecrawl API key | `FIRECRAWL_API_KEY` | — (optional; without it, web enrichment is skipped) |
| Output folder | `OUTPUT_DIR` | `~/Music/YouTube Sets` |
| Default format | `DEFAULT_FORMAT` | `alac` (UI toggle switches to `aac256`) |
| PO-token provider | `POT_PROVIDER_URL` | empty/disabled (set to the sidecar URL to enable) |
| Server port | `PORT` | `8765` |

Behavioral notes: the output folder is created on first run if missing. yt-dlp self-updates best-effort on
launch. The optional PO-token provider sidecar (Brainicism/bgutil-ytdlp-pot-provider) is **off by default** and
enabled only when `POT_PROVIDER_URL` is set.

---

## 9. Error handling, testing & risks

### 9.1 Error handling

- Each stage (**resolve / download / encode / tag**) fails gracefully with a clear UI message via an SSE `error` event.
- Partial/temp files (incomplete download, intermediate audio, temp cover) are **cleaned up** on failure.
- **AI failure** (no key, timeout, bad JSON) falls back to plain title parsing; the preview is still fully editable.
- Network/bot-check failures suggest enabling the PO-token provider in the message.

### 9.2 Testing

- **Unit:** `test_metadata.py` (title parsing + AI-JSON → `MetadataFields` mapping, including defaults) and
  `test_tagger.py` (mutagen writes the correct atoms; round-trip read-back asserts `aART`, `trkn`, `pgap`, `covr` JPEG).
- **Smoke:** end-to-end run against a short **Creative-Commons** video → asserts a valid ALAC `.m4a` with cover.
- **Manual:** drag the output into Apple Music and confirm it **imports cleanly as one album** (correct grouping/cover).

### 9.3 Risks & mitigations

| Risk | Mitigation |
|------|------------|
| YouTube throttling / bot checks / PO tokens | Keep yt-dlp current (self-update) + optional PO-token provider sidecar |
| ALAC file size (~5–10× source) | AAC-256 toggle; size note shown in UI |
| 1001tracklists fragility | **v2-only**, never a hard dependency (see §10) |
| AI cost | Cheap default model (`gpt-4o-mini`) + **per-video cache** (local JSON keyed by `video_id`) to avoid repeat calls |
| Cover embed failures (WebP/PNG) | Always convert to square JPEG; AtomicParsley fallback if mutagen `covr` write fails |

---

## 10. v2 roadmap (FUTURE — not in the first build)

> Same screen; the greyed-out "Split into separate tracks" toggle **activates**. Reuses `app/core/` directly.

**Tracklist source — reliability priority (highest first):**

| Rank | Source | How | Reliability |
|------|--------|-----|-------------|
| ① | **YouTube chapters** | yt-dlp `--split-chapters` or read `chapters` from info JSON | **Primary** — exact timestamps |
| ② | Description timestamps | Regex parse of the description | Good when present |
| ③ | Top comments | Parse pinned/top comments | Hit-or-miss |
| ④ | 1001tracklists | Track **names/artists only** | **Never a hard dependency** — Cloudflare-Turnstile-gated, no official API, unreliable/missing cue times; realistic access is a **user-run bookmarklet** |
| ⑤ | Audio fingerprinting | **AudD** paid API (simplest) **or** open-source **Panako** (built for tempo-shifted DJ sets) | Last-resort boundary finder |

**v2 flow:** show an **editable tracklist** (start time · title · artist per cut) → cut **losslessly** from the
single downloaded ALAC with **`ffmpeg -ss START -to END -i set.m4a -c copy`** (no re-encode) → tag each piece as
one cohesive **gapless** album (consistent `aART`, sequential `trkn`, `pgap=1`, `cpil=1` for VA sets).

---

## 11. Appendix — reference recipe & tooling

> Reference material from prior research. The v1 build uses the **preview-then-mutagen** order (download/encode
> untagged, then write final atoms after the user confirms), so the all-in-one yt-dlp recipe below is a reference,
> not the exact production path.

**Detect streams:**

```bash
yt-dlp -F URL      # 251 = opus/webm · 140 = m4a/AAC
```

**v1 download recipe (reference):**

```bash
yt-dlp -f "bestaudio/best" --extract-audio --audio-format alac --audio-quality 0 \
  --embed-thumbnail --convert-thumbnails jpg --embed-metadata --embed-chapters \
  -o "%(title)s [%(id)s].%(ext)s" URL
```

- `--convert-thumbnails jpg` is **required** (WebP fails to embed).
- Ensure **mutagen** or **AtomicParsley** is installed (the ffmpeg cover fallback errors on ALAC + thumbnail + chapters).
- Production path: **download → encode untagged → mutagen writes confirmed atoms** (so the editable preview drives the final tags).

**v2 chapter split (reference):**

```bash
# Native chapter split
yt-dlp -f bestaudio --extract-audio --audio-format alac --split-chapters \
  -o "chapter:%(title)s/%(section_number)02d - %(section_title)s.%(ext)s" URL

# Or lossless cut from an already-downloaded set
ffmpeg -ss START -to END -i set.m4a -c copy "NN - Track.m4a"
```

**PO-token provider:** Brainicism/bgutil-ytdlp-pot-provider.

**Useful repos to borrow from:**

| Repo | Borrow |
|------|--------|
| alexta69/metube | UI / queue patterns |
| meeb/tubesync | yt-dlp option set |
| beetbox/beets | MP4 tagging reference |
| Rouzax/TrackSplit | chapter splitting (v2) |
| crisbal/album-splitter | timestamp-list splitting (v2) |
| JorenSix/Panako · AudD/ACRCloud | audio fingerprinting (v2) |
