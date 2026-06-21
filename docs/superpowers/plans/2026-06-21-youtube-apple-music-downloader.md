# YouTube → Apple Music Downloader (v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a local-only macOS web tool that turns one YouTube URL into one perfectly-tagged, lossless ALAC `.m4a` (with an AAC-256 toggle) saved to an output folder, with an editable AI-assisted metadata preview and live SSE progress.

**Architecture:** A Python 3.11+ FastAPI server (loopback `127.0.0.1:8765`) serves a static single-column SPA (`web/`). A framework-free reusable engine under `app/core/` (`resolver`, `metadata_ai`, `downloader`, `tagger`, `library`) does the work; `yt-dlp` is used as a library with progress hooks, `ffmpeg` encodes ALAC/AAC, `mutagen` (AtomicParsley fallback) writes MP4 atoms + cover. A `POST /resolve` returns editable proposed metadata + a square JPEG cover preview without downloading; after the user confirms, `POST /download` runs an in-memory FIFO job whose progress streams over `GET /progress/{job_id}` (SSE).

**Tech Stack:** Python 3.11+, FastAPI, uvicorn, yt-dlp, ffmpeg (subprocess), mutagen, Pillow, httpx, OpenAI SDK, Firecrawl (REST via httpx), python-dotenv, pydantic v2, pytest.

---

## Out of scope (v2 — do NOT build)

DJ-set splitting (chapter/description/comment/1001tracklists/fingerprint-driven multi-track albums) is **future v2**. The UI includes only a **greyed-out, disabled "Split into separate tracks (v2)" toggle** as an inert placeholder. Create **no** tasks, code, or tests for splitting.

## Resolved spec gaps / decisions (read before starting)

These were ambiguous or divergent between the design spec and the real environment; decisions are locked here so tasks stay consistent:

1. **OpenAI-only provider for v1.** The real `.env` (already created, gitignored) defines `OPENAI_API_KEY`, `FIRECRAWL_API_KEY`, `OPENAI_MODEL`, `OUTPUT_DIR`, `DEFAULT_FORMAT`, `PORT`. The spec's generic `LLM_PROVIDER`/`LLM_MODEL`/Anthropic switch is **not** implemented in v1; we read `OPENAI_MODEL` (default `gpt-4o-mini`). `.env.example` documents these keys plus optional `POT_PROVIDER_URL`.
2. **Firecrawl via stable REST (`POST https://api.firecrawl.dev/v1/search`) using `httpx`**, not the `firecrawl-py` SDK (whose method names/return types have churned across versions). Enrichment is best-effort and wrapped in try/except → empty context on any failure. This still satisfies "OpenAI + Firecrawl enrichment".
3. **SSE via Starlette's built-in `StreamingResponse`** (`media_type="text/event-stream"`), no extra `sse-starlette` dependency.
4. **Progress endpoint is `GET /progress/{job_id}`** (the spec's §3/§5.1 form). `POST /download` returns `{ "job_id": ... }`; the browser opens `EventSource("/progress/<job_id>")`.
5. **Pillow** is added for the §6.3 center-crop + JPEG re-encode (the spec's `pyproject` dep list was non-exhaustive).
6. **Download orchestration (download → encode → tag → save) lives in the web-layer `JobManager`** in `app/main.py`, calling independent `app/core/` functions. Each core function stays single-responsibility and reusable; we do **not** add an unlisted `pipeline.py`.
7. **`ResolveResponse` carries no `url` field** (matches spec §5.3). The browser reuses the URL the user typed for `POST /download`; provenance is preserved because `metadata.comment` is set to the canonical URL during `/resolve`.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `pyproject.toml` | Package metadata + runtime/dev dependencies (setuptools, `app*` packages). |
| `.env.example` | Documented, placeholder-only template for the gitignored `.env`. |
| `run.sh` | Create venv if missing, install, source `.env` for `PORT`, open browser, launch uvicorn on loopback. |
| `README.md` | Prereqs (ffmpeg/AtomicParsley), setup, usage, tests, notes, v2 out-of-scope. |
| `app/__init__.py` | Marks `app` as a package (empty). |
| `app/config.py` | `Config` dataclass + `load_config()` (reads `os.environ`) + `init_env()` (loads `.env`). No web imports. |
| `app/models.py` | Pydantic v2 schemas: `MetadataFields`, `ResolveRequest`, `ResolveResponse`, `DownloadRequest`, `ProgressEvent`. No web imports. |
| `app/core/__init__.py` | Marks `app.core` as a package (empty). |
| `app/core/resolver.py` | yt-dlp `extract_info` → `RawInfo`; best-audio label/summary; detected-line string; thumbnail fetch + square-JPEG crop + per-`video_id` cover cache; data-URI helpers. |
| `app/core/metadata_ai.py` | Title cleaning, plain-title fallback, OpenAI JSON proposal, Firecrawl context, AI-JSON→`MetadataFields` mapping, per-`video_id` JSON cache. |
| `app/core/downloader.py` | `download_audio()` (yt-dlp bestaudio + progress hook) and `encode()` (ffmpeg ALAC/AAC-256). |
| `app/core/tagger.py` | `write_tags()` mutagen MP4 atoms + JPEG `covr`; AtomicParsley cover fallback. |
| `app/core/library.py` | Filename sanitize, output path, save/move, output-dir creation, Recent JSON (cap 20, dedup). |
| `app/main.py` | FastAPI app, static mount, `JobManager` (FIFO worker + per-job event queues), routes `/`, `/resolve`, `/download`, `/progress/{job_id}`, `/recent`, `/reveal`, lifespan best-effort yt-dlp self-update. |
| `web/index.html` | Single-column Layout A markup. |
| `web/styles.css` | Layout A styling. |
| `web/app.js` | Resolve/download flow, SSE consumption, Recent list, Reveal-in-Finder, AAC toggle line recompute. |
| `tests/conftest.py` | Shared fixtures: `sample_jpeg`, ffmpeg-built `m4a_file` (skips if ffmpeg missing). |
| `tests/test_config_models.py` | Config defaults + model defaults. |
| `tests/test_tagger.py` | Atom round-trip (incl. `aART`, `trkn`, `pgap`, `cpil`, JPEG `covr`). |
| `tests/test_library.py` | Sanitize, output path, save, Recent cap/dedup. |
| `tests/test_resolver.py` | Square-JPEG crop, detected-line, data-URI round-trip. |
| `tests/test_metadata.py` | `clean_title`, `parse_title_fallback`, `_map_ai_json`. |
| `tests/test_downloader.py` | `encode()` to ALAC and AAC-256 (uses ffmpeg fixture). |
| `tests/test_api.py` | FastAPI `TestClient`: `/recent`, `/reveal` 404, `/progress` unknown-job 404. |
| `tests/test_smoke.py` | Optional network end-to-end against a Creative-Commons video (skipped unless `RUN_SMOKE=1`). |

---

## Task 1: Project scaffold & dependencies

**Files:**
- Create: `pyproject.toml`
- Create: `.env.example`
- Create: `app/__init__.py`
- Create: `app/core/__init__.py`
- Create: `web/.gitkeep`

- [ ] **Step 1: Create `pyproject.toml`**

```toml
[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

[project]
name = "yt-m-automation"
version = "0.1.0"
description = "Local YouTube -> Apple Music (ALAC) downloader with AI-assisted tagging"
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.110",
    "uvicorn[standard]>=0.29",
    "yt-dlp>=2024.1.0",
    "mutagen>=1.47",
    "pillow>=10.2",
    "httpx>=0.27",
    "python-dotenv>=1.0",
    "openai>=1.30",
    "pydantic>=2.6",
]

[project.optional-dependencies]
dev = ["pytest>=8.0"]

[tool.setuptools.packages.find]
include = ["app*"]

[tool.pytest.ini_options]
testpaths = ["tests"]
```

- [ ] **Step 2: Create `.env.example` (placeholders only — never real secrets)**

```bash
# Copy this file to `.env` and fill in your keys. `.env` is gitignored.

# OpenAI (required for AI metadata enrichment; without it the tool falls back to plain title parsing)
OPENAI_API_KEY=sk-your-openai-key-here
# Firecrawl (optional; without it, web enrichment is skipped)
FIRECRAWL_API_KEY=fc-your-firecrawl-key-here

# Settings
OPENAI_MODEL=gpt-4o-mini
OUTPUT_DIR=~/Music/YouTube Sets
DEFAULT_FORMAT=alac
PORT=8765

# Optional: local PO-token provider sidecar URL for YouTube bot checks (leave empty to disable)
POT_PROVIDER_URL=
```

- [ ] **Step 3: Create package dirs and empty markers**

These are empty files, so create them directly (no content needed). `web/` must exist before the UI task because `StaticFiles` requires the directory.

Run:

```bash
mkdir -p app/core web tests
touch app/__init__.py app/core/__init__.py web/.gitkeep
```

Expected: no output; `ls app app/core web tests` shows the created files/dirs.

- [ ] **Step 4: Create venv and install (editable, with dev extras)**

Run:

```bash
python3 -m venv .venv && source .venv/bin/activate && pip install -U pip && pip install -e ".[dev]"
```

Expected: ends with `Successfully installed ... yt-m-automation-0.1.0 ...` and no errors.

- [ ] **Step 5: Verify pytest collects an empty suite**

Run: `source .venv/bin/activate && pytest -q`
Expected: `no tests ran` (exit code 5) — confirms the package installs and pytest is wired. This is fine at this stage.

- [ ] **Step 6: Commit**

```bash
git add pyproject.toml .env.example app/__init__.py app/core/__init__.py web/.gitkeep
git commit -m "chore: scaffold package, deps, and env template"
```

---

## Task 2: Config & models (TDD)

**Files:**
- Create: `app/config.py`
- Create: `app/models.py`
- Test: `tests/test_config_models.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_config_models.py`:

```python
from app.config import load_config
from app.models import MetadataFields, DownloadRequest, ProgressEvent


def test_config_defaults(monkeypatch):
    for key in [
        "OPENAI_API_KEY", "FIRECRAWL_API_KEY", "OPENAI_MODEL",
        "OUTPUT_DIR", "DEFAULT_FORMAT", "PORT", "POT_PROVIDER_URL",
    ]:
        monkeypatch.delenv(key, raising=False)
    cfg = load_config()
    assert cfg.openai_model == "gpt-4o-mini"
    assert cfg.default_format == "alac"
    assert cfg.port == 8765
    assert cfg.openai_api_key is None
    assert cfg.firecrawl_api_key is None
    assert cfg.pot_provider_url is None
    assert str(cfg.output_dir).endswith("YouTube Sets")


def test_config_reads_environment(monkeypatch):
    monkeypatch.setenv("OPENAI_MODEL", "gpt-4o")
    monkeypatch.setenv("DEFAULT_FORMAT", "aac256")
    monkeypatch.setenv("PORT", "9000")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    cfg = load_config()
    assert cfg.openai_model == "gpt-4o"
    assert cfg.default_format == "aac256"
    assert cfg.port == 9000
    assert cfg.openai_api_key == "sk-test"


def test_metadata_defaults():
    meta = MetadataFields()
    assert meta.title == ""
    assert meta.year is None
    assert meta.compilation is False


def test_download_request_defaults():
    req = DownloadRequest(video_id="abc", url="https://x", metadata=MetadataFields())
    assert req.format == "alac"
    assert req.cover == "keep"


def test_progress_event_defaults():
    ev = ProgressEvent(stage="download", pct=42.0, message="x")
    assert ev.file_path is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_config_models.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.config'` (and `app.models`).

- [ ] **Step 3: Implement `app/config.py`**

```python
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv


def init_env(env_path: str | None = None) -> None:
    """Load variables from a .env file into os.environ. Call once at app startup.

    Not called by load_config(), so tests can control the environment directly.
    """
    load_dotenv(env_path)


def _expand(path_str: str) -> Path:
    return Path(os.path.expanduser(path_str)).resolve()


@dataclass(frozen=True)
class Config:
    openai_api_key: str | None
    firecrawl_api_key: str | None
    openai_model: str
    output_dir: Path
    default_format: str
    port: int
    pot_provider_url: str | None


def load_config() -> Config:
    return Config(
        openai_api_key=os.getenv("OPENAI_API_KEY") or None,
        firecrawl_api_key=os.getenv("FIRECRAWL_API_KEY") or None,
        openai_model=os.getenv("OPENAI_MODEL", "gpt-4o-mini"),
        output_dir=_expand(os.getenv("OUTPUT_DIR", "~/Music/YouTube Sets")),
        default_format=os.getenv("DEFAULT_FORMAT", "alac"),
        port=int(os.getenv("PORT", "8765")),
        pot_provider_url=os.getenv("POT_PROVIDER_URL") or None,
    )
```

- [ ] **Step 4: Implement `app/models.py`**

```python
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel


class MetadataFields(BaseModel):
    title: str = ""
    artist: str = ""
    album: str = ""
    album_artist: str = ""
    year: Optional[int] = None
    genre: str = ""
    comment: str = ""  # source YouTube URL (provenance)
    compilation: bool = False


class ResolveRequest(BaseModel):
    url: str


class ResolveResponse(BaseModel):
    video_id: str
    duration: int
    metadata: MetadataFields
    cover: str  # base64 JPEG data URI (square), or "" if unavailable
    formats: str
    detected_line: str
    has_chapters: bool


class DownloadRequest(BaseModel):
    video_id: str
    url: str
    metadata: MetadataFields
    format: Literal["alac", "aac256"] = "alac"
    cover: str = "keep"  # "keep" reuses the server-cached cover, or a data URI overrides it


class ProgressEvent(BaseModel):
    stage: Literal["queued", "download", "encode", "tag", "done", "error"]
    pct: float = 0.0
    message: str = ""
    file_path: Optional[str] = None
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pytest tests/test_config_models.py -v`
Expected: PASS — `5 passed`.

- [ ] **Step 6: Commit**

```bash
git add app/config.py app/models.py tests/test_config_models.py
git commit -m "feat: add config loader and pydantic models"
```

---

## Task 3: Tagger (TDD) + shared test fixtures

**Files:**
- Create: `tests/conftest.py`
- Create: `app/core/tagger.py`
- Test: `tests/test_tagger.py`

- [ ] **Step 1: Create shared fixtures `tests/conftest.py`**

```python
import shutil
import subprocess
from io import BytesIO
from pathlib import Path

import pytest
from PIL import Image


def has_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


@pytest.fixture
def sample_jpeg() -> bytes:
    img = Image.new("RGB", (300, 300), (180, 40, 40))
    buf = BytesIO()
    img.save(buf, format="JPEG", quality=90)
    return buf.getvalue()


@pytest.fixture
def m4a_file(tmp_path) -> Path:
    """A tiny real .m4a (AAC) built with ffmpeg; skips if ffmpeg is unavailable."""
    if not has_ffmpeg():
        pytest.skip("ffmpeg not installed")
    out = tmp_path / "sample.m4a"
    subprocess.run(
        [
            "ffmpeg", "-y", "-f", "lavfi",
            "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
            "-t", "1", "-c:a", "aac", "-b:a", "64k", str(out),
        ],
        check=True, capture_output=True,
    )
    return out
```

- [ ] **Step 2: Write the failing test `tests/test_tagger.py`**

```python
from mutagen.mp4 import MP4, MP4Cover

from app.core.tagger import write_tags
from app.models import MetadataFields


def test_write_tags_roundtrip(m4a_file, sample_jpeg):
    meta = MetadataFields(
        title="Sunset Set",
        artist="DJ Test",
        album="Tomorrowland 2025",
        album_artist="DJ Test",
        year=2025,
        genre="Electronic",
        comment="https://youtu.be/abc123",
        compilation=False,
    )
    write_tags(m4a_file, meta, sample_jpeg)

    audio = MP4(str(m4a_file))
    assert audio["\xa9nam"] == ["Sunset Set"]
    assert audio["\xa9ART"] == ["DJ Test"]
    assert audio["\xa9alb"] == ["Tomorrowland 2025"]
    assert audio["aART"] == ["DJ Test"]
    assert audio["\xa9day"] == ["2025"]
    assert audio["\xa9gen"] == ["Electronic"]
    assert audio["\xa9cmt"] == ["https://youtu.be/abc123"]
    assert audio["trkn"] == [(1, 1)]
    assert audio["disk"] == [(1, 1)]
    assert audio["pgap"] is True
    assert audio["cpil"] is False
    cover = audio["covr"][0]
    assert cover.imageformat == MP4Cover.FORMAT_JPEG
    assert bytes(cover) == sample_jpeg


def test_write_tags_compilation_true(m4a_file):
    meta = MetadataFields(title="VA Set", artist="Various", album="Fest", album_artist="Various Artists", compilation=True)
    write_tags(m4a_file, meta, None)
    audio = MP4(str(m4a_file))
    assert audio["cpil"] is True
    assert "covr" not in audio
```

- [ ] **Step 3: Run test to verify it fails**

Run: `pytest tests/test_tagger.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.core.tagger'`.

- [ ] **Step 4: Implement `app/core/tagger.py`**

```python
from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

from mutagen.mp4 import MP4, MP4Cover

from ..models import MetadataFields


def write_tags(
    m4a_path: Path | str,
    meta: MetadataFields,
    cover_jpeg: bytes | None = None,
    track: tuple[int, int] = (1, 1),
    disc: tuple[int, int] = (1, 1),
) -> None:
    """Write Apple-Music-friendly MP4 atoms (+ JPEG cover) to an existing .m4a.

    aART (Album Artist) + ©alb (Album) drive Apple Music album grouping; pgap=1
    keeps continuous mixes gapless. If mutagen fails to embed the cover, fall
    back to AtomicParsley.
    """
    path = Path(m4a_path)
    audio = MP4(str(path))
    audio["\xa9nam"] = [meta.title]
    audio["\xa9ART"] = [meta.artist]
    audio["\xa9alb"] = [meta.album]
    audio["aART"] = [meta.album_artist or meta.artist]
    if meta.year:
        audio["\xa9day"] = [str(meta.year)]
    if meta.genre:
        audio["\xa9gen"] = [meta.genre]
    if meta.comment:
        audio["\xa9cmt"] = [meta.comment]
    audio["trkn"] = [track]
    audio["disk"] = [disc]
    audio["cpil"] = bool(meta.compilation)
    audio["pgap"] = True
    if cover_jpeg:
        audio["covr"] = [MP4Cover(cover_jpeg, imageformat=MP4Cover.FORMAT_JPEG)]

    try:
        audio.save()
    except Exception:
        if not cover_jpeg:
            raise
        # Retry without the cover via mutagen, then embed the cover with AtomicParsley.
        audio.pop("covr", None)
        audio.save()
        _embed_cover_atomicparsley(path, cover_jpeg)


def _embed_cover_atomicparsley(path: Path, cover_jpeg: bytes) -> None:
    atomic = shutil.which("AtomicParsley")
    if not atomic:
        raise RuntimeError(
            "Cover embed failed via mutagen and AtomicParsley is not installed "
            "(install with: brew install atomicparsley)"
        )
    tmp = Path(tempfile.gettempdir()) / f"yt-m-cover-{path.stem}.jpg"
    tmp.write_bytes(cover_jpeg)
    try:
        proc = subprocess.run(
            [atomic, str(path), "--artwork", str(tmp), "--overWrite"],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"AtomicParsley failed: {proc.stderr.strip()[-200:]}")
    finally:
        tmp.unlink(missing_ok=True)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pytest tests/test_tagger.py -v`
Expected: PASS — `2 passed` (or `2 skipped` if ffmpeg is not installed; install ffmpeg with `brew install ffmpeg` to actually exercise it).

- [ ] **Step 6: Commit**

```bash
git add tests/conftest.py app/core/tagger.py tests/test_tagger.py
git commit -m "feat: add mutagen tagger with AtomicParsley cover fallback"
```

---

## Task 4: Library (filenames, save, Recent) (TDD)

**Files:**
- Create: `app/core/library.py`
- Test: `tests/test_library.py`

- [ ] **Step 1: Write the failing test `tests/test_library.py`**

```python
from pathlib import Path

from app.core.library import (
    sanitize_filename,
    output_path,
    save,
    ensure_output_dir,
    record_recent,
    load_recent,
)


def test_sanitize_replaces_illegal_chars():
    assert sanitize_filename("AC/DC: Live") == "AC-DC- Live"
    assert sanitize_filename("   ") == "untitled"


def test_output_path_format(tmp_path):
    p = output_path(tmp_path, "DJ Test", "Sunset Set", "abc123")
    assert p.name == "DJ Test - Sunset Set [abc123].m4a"
    assert p.parent == Path(tmp_path)


def test_output_path_sanitizes(tmp_path):
    p = output_path(tmp_path, "AC/DC", "Back: In", "xyz")
    assert p.name == "AC-DC - Back- In [xyz].m4a"


def test_save_moves_file(tmp_path):
    src = tmp_path / "src.m4a"
    src.write_bytes(b"data")
    dest = tmp_path / "out" / "final.m4a"
    result = save(src, dest)
    assert result == dest
    assert dest.exists()
    assert not src.exists()


def test_recent_caps_at_20_and_dedups(tmp_path):
    ensure_output_dir(tmp_path)
    for i in range(25):
        record_recent(tmp_path, {"path": f"/x/{i}.m4a", "title": str(i), "artist": "a", "album": "b"})
    # Re-record an existing path; it should move to the front, not duplicate.
    record_recent(tmp_path, {"path": "/x/24.m4a", "title": "24", "artist": "a", "album": "b"})
    items = load_recent(tmp_path)
    assert len(items) == 20
    assert items[0]["path"] == "/x/24.m4a"
    paths = [it["path"] for it in items]
    assert len(paths) == len(set(paths))


def test_load_recent_missing_returns_empty(tmp_path):
    assert load_recent(tmp_path) == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_library.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.core.library'`.

- [ ] **Step 3: Implement `app/core/library.py`**

```python
from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

_ILLEGAL = {"/": "-", ":": "-"}
_RECENT_FILE = ".yt-m-recent.json"
_RECENT_CAP = 20


def sanitize_filename(name: str) -> str:
    cleaned = name or ""
    for bad, good in _ILLEGAL.items():
        cleaned = cleaned.replace(bad, good)
    cleaned = cleaned.replace("\x00", "")
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip()
    return cleaned or "untitled"


def ensure_output_dir(output_dir: Path | str) -> Path:
    path = Path(output_dir).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    return path


def output_path(output_dir: Path | str, album_artist: str, title: str, video_id: str) -> Path:
    filename = f"{sanitize_filename(album_artist or 'Unknown Artist')} - {sanitize_filename(title or 'Untitled')} [{video_id}].m4a"
    return Path(output_dir).expanduser() / filename


def save(temp_file: Path | str, dest: Path | str) -> Path:
    dest_path = Path(dest)
    dest_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(temp_file), str(dest_path))
    return dest_path


def _recent_path(output_dir: Path | str) -> Path:
    return Path(output_dir).expanduser() / _RECENT_FILE


def load_recent(output_dir: Path | str) -> list[dict]:
    path = _recent_path(output_dir)
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, list) else []
    except (ValueError, OSError):
        return []


def record_recent(output_dir: Path | str, entry: dict, cap: int = _RECENT_CAP) -> None:
    items = [e for e in load_recent(output_dir) if e.get("path") != entry.get("path")]
    items.insert(0, entry)
    ensure_output_dir(output_dir)
    _recent_path(output_dir).write_text(json.dumps(items[:cap], indent=2))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_library.py -v`
Expected: PASS — `6 passed`.

- [ ] **Step 5: Commit**

```bash
git add app/core/library.py tests/test_library.py
git commit -m "feat: add library (filenames, save, recent list)"
```

---

## Task 5: Resolver (cover crop, detected line, yt-dlp info)

Pure helpers are unit-tested; the network `resolve()` is verified manually.

**Files:**
- Create: `app/core/resolver.py`
- Test: `tests/test_resolver.py`

- [ ] **Step 1: Write the failing test `tests/test_resolver.py`**

```python
from io import BytesIO

from PIL import Image

from app.core.resolver import (
    to_square_jpeg,
    detected_line,
    jpeg_to_data_uri,
    data_uri_to_bytes,
    augment_error,
)


def test_to_square_jpeg_makes_square_jpeg():
    img = Image.new("RGB", (640, 360), (10, 20, 30))
    buf = BytesIO()
    img.save(buf, format="PNG")
    out = to_square_jpeg(buf.getvalue())
    result = Image.open(BytesIO(out))
    assert result.width == result.height
    assert result.format == "JPEG"


def test_to_square_jpeg_caps_max_size():
    img = Image.new("RGB", (2000, 2000), (0, 0, 0))
    buf = BytesIO()
    img.save(buf, format="PNG")
    out = to_square_jpeg(buf.getvalue(), max_size=1400)
    result = Image.open(BytesIO(out))
    assert result.width == 1400 and result.height == 1400


def test_detected_line_alac_includes_size_note():
    line = detected_line("251 · opus · ~160 kbps", "alac", "/Music/YT")
    assert "ALAC lossless" in line
    assert "~5-10x" in line
    assert "/Music/YT" in line


def test_detected_line_aac_has_no_size_note():
    line = detected_line("251 · opus · ~160 kbps", "aac256", "/Music/YT")
    assert "AAC 256 kbps" in line
    assert "~5-10x" not in line


def test_data_uri_roundtrip():
    uri = jpeg_to_data_uri(b"hello-bytes")
    assert uri.startswith("data:image/jpeg;base64,")
    assert data_uri_to_bytes(uri) == b"hello-bytes"
    assert data_uri_to_bytes("aGVsbG8=") == b"hello"  # bare base64, no prefix


def test_augment_error_adds_pot_hint_for_bot_check():
    msg = augment_error(RuntimeError("Sign in to confirm you're not a bot"))
    assert "POT_PROVIDER_URL" in msg


def test_augment_error_passthrough_for_plain_error():
    msg = augment_error(ValueError("unsupported url"))
    assert msg == "unsupported url"
    assert "POT_PROVIDER_URL" not in msg
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_resolver.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.core.resolver'`.

- [ ] **Step 3: Implement `app/core/resolver.py`**

```python
from __future__ import annotations

import base64
import tempfile
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path

import httpx
from PIL import Image
from yt_dlp import YoutubeDL

_COVER_DIR = Path(tempfile.gettempdir()) / "yt-m-covers"


@dataclass
class RawInfo:
    video_id: str
    url: str
    title: str
    description: str
    uploader: str
    upload_date: str  # "YYYYMMDD" or ""
    thumbnail: str
    duration: int
    has_chapters: bool
    best_audio_label: str
    formats_summary: str


def _best_audio(formats: list[dict]) -> dict | None:
    audio_only = [
        f for f in formats
        if f.get("acodec") not in (None, "none") and f.get("vcodec") in (None, "none")
    ]
    candidates = audio_only or [f for f in formats if f.get("acodec") not in (None, "none")]
    if not candidates:
        return None
    return max(candidates, key=lambda f: (f.get("abr") or f.get("tbr") or 0))


def _best_audio_label(fmt: dict | None) -> str:
    if not fmt:
        return "unknown audio"
    parts = [str(fmt.get("format_id", "?"))]
    if fmt.get("acodec") and fmt["acodec"] != "none":
        parts.append(str(fmt["acodec"]))
    abr = fmt.get("abr") or fmt.get("tbr")
    if abr:
        parts.append(f"~{int(abr)} kbps")
    return " · ".join(parts)


def _formats_summary(fmt: dict | None) -> str:
    if not fmt:
        return "no audio-only stream detected"
    ext = fmt.get("ext", "?")
    return f"bestaudio {fmt.get('format_id', '?')} ({ext})"


def resolve(url: str) -> RawInfo:
    opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
    }
    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)
    formats = info.get("formats") or []
    best = _best_audio(formats)
    return RawInfo(
        video_id=info.get("id", "") or "",
        url=info.get("webpage_url") or url,
        title=info.get("title", "") or "",
        description=info.get("description", "") or "",
        uploader=info.get("uploader") or info.get("channel") or "",
        upload_date=info.get("upload_date", "") or "",
        thumbnail=info.get("thumbnail", "") or "",
        duration=int(info.get("duration") or 0),
        has_chapters=bool(info.get("chapters")),
        best_audio_label=_best_audio_label(best),
        formats_summary=_formats_summary(best),
    )


def detected_line(best_audio_label: str, fmt: str, output_dir: str) -> str:
    if fmt == "aac256":
        return f"Detected: bestaudio ({best_audio_label}) → AAC 256 kbps · {output_dir}"
    return (
        f"Detected: bestaudio ({best_audio_label}) → ALAC lossless · {output_dir}"
        f" · ALAC files are ~5-10x the source size"
    )


def fetch_thumbnail(url: str) -> bytes:
    resp = httpx.get(url, timeout=30, follow_redirects=True)
    resp.raise_for_status()
    return resp.content


def to_square_jpeg(data: bytes, max_size: int = 1400, quality: int = 90) -> bytes:
    img = Image.open(BytesIO(data)).convert("RGB")
    width, height = img.size
    side = min(width, height)
    left = (width - side) // 2
    top = (height - side) // 2
    img = img.crop((left, top, left + side, top + side))
    if side > max_size:
        img = img.resize((max_size, max_size))
    buf = BytesIO()
    img.save(buf, format="JPEG", quality=quality)
    return buf.getvalue()


def cover_cache_path(video_id: str) -> Path:
    _COVER_DIR.mkdir(parents=True, exist_ok=True)
    return _COVER_DIR / f"{video_id}.jpg"


def cache_cover_jpeg(video_id: str, jpeg: bytes) -> Path:
    path = cover_cache_path(video_id)
    path.write_bytes(jpeg)
    return path


def read_cached_cover(video_id: str) -> bytes | None:
    path = cover_cache_path(video_id)
    return path.read_bytes() if path.exists() else None


def jpeg_to_data_uri(jpeg: bytes) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(jpeg).decode("ascii")


def data_uri_to_bytes(uri: str) -> bytes:
    payload = uri.split(",", 1)[1] if "," in uri else uri
    return base64.b64decode(payload)


def augment_error(exc: Exception) -> str:
    """Turn an exception into a user-facing message, hinting at the PO-token
    provider when the failure looks like a YouTube bot/sign-in check."""
    message = str(exc) or exc.__class__.__name__
    lowered = message.lower()
    triggers = ("sign in", "bot", "confirm you", "403", "429", "rate", "captcha", "not a bot")
    if any(trigger in lowered for trigger in triggers):
        message += (
            " — YouTube may be applying a bot check. Set POT_PROVIDER_URL to a "
            "running PO-token provider sidecar and retry."
        )
    return message
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_resolver.py -v`
Expected: PASS — `7 passed`.

- [ ] **Step 5: Manually verify the network `resolve()` (optional but recommended)**

Run (uses network; pick any public video):

```bash
source .venv/bin/activate && python -c "from app.core.resolver import resolve; r = resolve('https://www.youtube.com/watch?v=aqz-KE-bpKQ'); print(r.video_id, r.duration, r.best_audio_label); print(r.title)"
```

Expected: prints a non-empty `video_id`, a positive duration, a best-audio label like `251 · opus · ~160 kbps`, and the video title. If YouTube blocks with a bot check, that is a known risk handled later via the optional PO-token provider — proceed.

- [ ] **Step 6: Commit**

```bash
git add app/core/resolver.py tests/test_resolver.py
git commit -m "feat: add resolver (yt-dlp info, square-jpeg cover, detected line)"
```

---

## Task 6: Metadata AI (title cleaning, fallback, AI mapping) (TDD)

Pure functions are unit-tested; OpenAI and Firecrawl calls are isolated and best-effort.

**Files:**
- Create: `app/core/metadata_ai.py`
- Test: `tests/test_metadata.py`

- [ ] **Step 1: Write the failing test `tests/test_metadata.py`**

```python
from app.core.resolver import RawInfo
from app.core.metadata_ai import clean_title, parse_title_fallback, _map_ai_json


def _raw(**overrides) -> RawInfo:
    base = dict(
        video_id="abc123",
        url="https://youtu.be/abc123",
        title="",
        description="",
        uploader="Some Channel",
        upload_date="20240115",
        thumbnail="",
        duration=3600,
        has_chapters=False,
        best_audio_label="251 · opus · ~160 kbps",
        formats_summary="",
    )
    base.update(overrides)
    return RawInfo(**base)


def test_clean_title_strips_noise():
    assert clean_title("Artist - Track [Official Video]") == "Artist - Track"
    assert clean_title("Big Set (Official Audio)") == "Big Set"
    assert clean_title("Name (Official Music Video)") == "Name"


def test_parse_title_fallback_splits_artist_and_title():
    raw = _raw(title="DJ Test - Sunset Set [Official Video]")
    meta = parse_title_fallback(raw)
    assert meta.artist == "DJ Test"
    assert meta.title == "Sunset Set"
    assert meta.album == "DJ Test - Sunset Set"
    assert meta.album_artist == "DJ Test"
    assert meta.year == 2024
    assert meta.comment == "https://youtu.be/abc123"


def test_parse_title_fallback_uses_uploader_when_no_separator():
    raw = _raw(title="Just A Title")
    meta = parse_title_fallback(raw)
    assert meta.artist == "Some Channel"
    assert meta.title == "Just A Title"


def test_map_ai_json_overrides_and_coerces():
    raw = _raw(title="DJ Test - Sunset Set")
    fallback = parse_title_fallback(raw)
    data = {
        "title": "Sunset Set",
        "artist": "DJ Test",
        "album": "Tomorrowland 2025",
        "album_artist": "Various Artists",
        "year": "2025",
        "genre": "Electronic",
        "compilation": True,
    }
    meta = _map_ai_json(data, fallback, raw)
    assert meta.album == "Tomorrowland 2025"
    assert meta.album_artist == "Various Artists"
    assert meta.year == 2025
    assert meta.genre == "Electronic"
    assert meta.compilation is True
    assert meta.comment == "https://youtu.be/abc123"


def test_map_ai_json_empty_fields_fall_back():
    raw = _raw(title="DJ Test - Sunset Set")
    fallback = parse_title_fallback(raw)
    data = {"title": "", "artist": "", "album": "", "album_artist": "", "year": None, "genre": "", "compilation": False}
    meta = _map_ai_json(data, fallback, raw)
    assert meta.title == fallback.title
    assert meta.artist == fallback.artist
    assert meta.album == fallback.album
    assert meta.year == fallback.year


def test_map_ai_json_bad_year_falls_back():
    raw = _raw(title="A - B")
    fallback = parse_title_fallback(raw)
    meta = _map_ai_json({"year": "not-a-year"}, fallback, raw)
    assert meta.year == fallback.year
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_metadata.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.core.metadata_ai'`.

- [ ] **Step 3: Implement `app/core/metadata_ai.py`**

```python
from __future__ import annotations

import json
import re
from pathlib import Path

import httpx

from ..config import Config
from ..models import MetadataFields
from .resolver import RawInfo

_CACHE_DIR = Path.home() / ".cache" / "yt-m-automation"

_NOISE = re.compile(
    r"[\[(]\s*(?:official\s*(?:music\s*)?(?:video|audio|lyric video)?|"
    r"lyrics?|audio|video|hd|4k|m/?v|visualizer|remastered)\s*[\])]",
    re.IGNORECASE,
)


def clean_title(title: str) -> str:
    cleaned = _NOISE.sub("", title or "")
    cleaned = re.sub(r"\s{2,}", " ", cleaned)
    return cleaned.strip(" -–—|·")


def parse_title_fallback(raw: RawInfo) -> MetadataFields:
    cleaned = clean_title(raw.title)
    artist, title = "", cleaned
    if " - " in cleaned:
        left, _, right = cleaned.partition(" - ")
        artist, title = left.strip(), right.strip()
    if not artist:
        artist = raw.uploader
    year = None
    if len(raw.upload_date) >= 4 and raw.upload_date[:4].isdigit():
        year = int(raw.upload_date[:4])
    return MetadataFields(
        title=title or cleaned,
        artist=artist,
        album=cleaned,
        album_artist=artist,
        year=year,
        genre="",
        comment=raw.url,
        compilation=False,
    )


def _map_ai_json(data: dict, fallback: MetadataFields, raw: RawInfo) -> MetadataFields:
    def pick(key: str, default: str) -> str:
        value = data.get(key)
        if isinstance(value, str):
            value = value.strip()
        return value or default

    raw_year = data.get("year")
    try:
        year = int(raw_year) if raw_year not in (None, "", "null") else fallback.year
    except (ValueError, TypeError):
        year = fallback.year

    return MetadataFields(
        title=pick("title", fallback.title),
        artist=pick("artist", fallback.artist),
        album=pick("album", fallback.album),
        album_artist=pick("album_artist", fallback.album_artist),
        year=year,
        genre=pick("genre", fallback.genre),
        comment=raw.url,
        compilation=bool(data.get("compilation", fallback.compilation)),
    )


def _firecrawl_context(query: str, api_key: str, limit: int = 3) -> str:
    try:
        resp = httpx.post(
            "https://api.firecrawl.dev/v1/search",
            headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
            json={"query": query, "limit": limit},
            timeout=30,
        )
        resp.raise_for_status()
        results = resp.json().get("data") or []
        lines = [
            f"- {item.get('title', '')}: {item.get('description', '')} ({item.get('url', '')})"
            for item in results[:limit]
        ]
        return "\n".join(lines)
    except Exception:
        return ""


def _openai_propose(raw: RawInfo, context: str, cfg: Config) -> dict | None:
    try:
        from openai import OpenAI

        client = OpenAI(api_key=cfg.openai_api_key)
        system = (
            "You extract music metadata as strict JSON with exactly these keys: "
            "title, artist, album, album_artist, year (integer or null), genre, "
            "compilation (boolean). For DJ sets or festival recordings, use the "
            "event/set name as the album and the performer as artist/album_artist. "
            "For various-artist compilations set album_artist to 'Various Artists' "
            "and compilation to true. Return ONLY the JSON object."
        )
        user = (
            f"YouTube title: {raw.title}\n"
            f"Uploader: {raw.uploader}\n"
            f"Upload date: {raw.upload_date}\n"
            f"Description (truncated): {raw.description[:1500]}\n\n"
            f"Web context:\n{context or 'none'}"
        )
        resp = client.chat.completions.create(
            model=cfg.openai_model,
            messages=[{"role": "system", "content": system}, {"role": "user", "content": user}],
            response_format={"type": "json_object"},
            temperature=0.2,
        )
        return json.loads(resp.choices[0].message.content)
    except Exception:
        return None


def _cache_path(video_id: str) -> Path:
    _CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return _CACHE_DIR / f"{video_id}.json"


def _load_cache(video_id: str) -> dict | None:
    path = _cache_path(video_id)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except (ValueError, OSError):
        return None


def _save_cache(video_id: str, data: dict) -> None:
    try:
        _cache_path(video_id).write_text(json.dumps(data, indent=2))
    except OSError:
        pass


def propose_metadata(raw: RawInfo, cfg: Config) -> MetadataFields:
    """Best-guess metadata: per-video cache → AI (OpenAI + optional Firecrawl) → plain title fallback."""
    cached = _load_cache(raw.video_id)
    if cached is not None:
        return MetadataFields(**cached)

    fallback = parse_title_fallback(raw)
    meta = fallback
    if cfg.openai_api_key:
        context = ""
        if cfg.firecrawl_api_key:
            context = _firecrawl_context(f"{clean_title(raw.title)} {raw.uploader}", cfg.firecrawl_api_key)
        data = _openai_propose(raw, context, cfg)
        if data:
            meta = _map_ai_json(data, fallback, raw)

    _save_cache(raw.video_id, meta.model_dump())
    return meta
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_metadata.py -v`
Expected: PASS — `6 passed`.

- [ ] **Step 5: Commit**

```bash
git add app/core/metadata_ai.py tests/test_metadata.py
git commit -m "feat: add AI metadata (title parse, OpenAI proposal, Firecrawl context)"
```

---

## Task 7: Downloader (yt-dlp bestaudio + ffmpeg encode)

`encode()` is unit-tested with the ffmpeg fixture; `download_audio()` is verified manually (needs network).

**Files:**
- Create: `app/core/downloader.py`
- Test: `tests/test_downloader.py`

- [ ] **Step 1: Write the failing test `tests/test_downloader.py`**

```python
from mutagen.mp4 import MP4

from app.core.downloader import encode


def test_encode_to_alac(m4a_file, tmp_path):
    dest = tmp_path / "out_alac.m4a"
    encode(m4a_file, dest, "alac")
    assert dest.exists() and dest.stat().st_size > 0
    assert MP4(str(dest)).info.length > 0


def test_encode_to_aac256(m4a_file, tmp_path):
    dest = tmp_path / "out_aac.m4a"
    encode(m4a_file, dest, "aac256")
    assert dest.exists() and dest.stat().st_size > 0
    assert MP4(str(dest)).info.length > 0
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_downloader.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.core.downloader'`.

- [ ] **Step 3: Implement `app/core/downloader.py`**

```python
from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Callable, Optional

from yt_dlp import YoutubeDL


def download_audio(
    url: str,
    workdir: Path,
    on_progress: Callable[[float], None],
    pot_provider_url: Optional[str] = None,
) -> Path:
    """Download the best audio-only stream into workdir. Returns the source file path.

    on_progress receives a 0-100 float. No postprocessing: we encode separately so
    the file stays untagged until mutagen writes the user-confirmed atoms.
    """
    state: dict[str, Optional[str]] = {"path": None}

    def hook(d: dict) -> None:
        status = d.get("status")
        if status == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate")
            done = d.get("downloaded_bytes") or 0
            if total:
                on_progress(min(99.0, done / total * 100.0))
        elif status == "finished":
            state["path"] = d.get("filename")
            on_progress(100.0)

    opts: dict = {
        "format": "bestaudio/best",
        "outtmpl": str(workdir / "%(id)s.%(ext)s"),
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "progress_hooks": [hook],
    }
    if pot_provider_url:
        # Requires the bgutil PO-token provider plugin to be installed.
        opts["extractor_args"] = {"youtube": {"getpot_bgutil_baseurl": [pot_provider_url]}}

    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=True)
        if not state["path"]:
            state["path"] = ydl.prepare_filename(info)

    path = state["path"]
    if not path or not Path(path).exists():
        raise RuntimeError("Download finished but the audio file was not found")
    return Path(path)


def encode(src: Path | str, dest: Path | str, fmt: str) -> None:
    """Transcode src to dest. fmt is 'alac' (lossless) or 'aac256'."""
    if fmt == "aac256":
        codec_args = ["-c:a", "aac", "-b:a", "256k"]
    else:
        codec_args = ["-c:a", "alac"]
    cmd = [
        "ffmpeg", "-y", "-i", str(src),
        "-vn", *codec_args, "-movflags", "+faststart",
        str(dest),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg encode failed: {proc.stderr.strip()[-300:]}")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_downloader.py -v`
Expected: PASS — `2 passed` (or `2 skipped` without ffmpeg).

- [ ] **Step 5: Commit**

```bash
git add app/core/downloader.py tests/test_downloader.py
git commit -m "feat: add downloader (yt-dlp bestaudio + ffmpeg ALAC/AAC encode)"
```

---

## Task 8: FastAPI app, FIFO JobManager, SSE routes

**Files:**
- Create: `app/main.py`
- Test: `tests/test_api.py`

- [ ] **Step 1: Implement `app/main.py`**

```python
from __future__ import annotations

import asyncio
import os
import queue
import subprocess
import sys
import tempfile
import threading
from contextlib import asynccontextmanager
from pathlib import Path
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .config import init_env, load_config
from .core import downloader, library, metadata_ai, resolver, tagger
from .models import DownloadRequest, ProgressEvent, ResolveRequest, ResolveResponse

init_env()
cfg = load_config()

WEB_DIR = Path(__file__).resolve().parent.parent / "web"


class JobManager:
    """Single-worker FIFO download queue with per-job event queues for SSE."""

    def __init__(self, config) -> None:
        self.cfg = config
        self.jobs: dict[str, "queue.Queue[ProgressEvent]"] = {}
        self.work: "queue.Queue[tuple[str, DownloadRequest]]" = queue.Queue()
        self._worker = threading.Thread(target=self._run, daemon=True)
        self._worker.start()

    def submit(self, req: DownloadRequest) -> str:
        job_id = uuid4().hex
        self.jobs[job_id] = queue.Queue()
        self._emit(job_id, ProgressEvent(stage="queued", pct=0.0, message="Queued"))
        self.work.put((job_id, req))
        return job_id

    def get_queue(self, job_id: str) -> "queue.Queue[ProgressEvent]":
        if job_id not in self.jobs:
            raise KeyError(job_id)
        return self.jobs[job_id]

    def _emit(self, job_id: str, event: ProgressEvent) -> None:
        self.jobs[job_id].put(event)

    def _run(self) -> None:
        while True:
            job_id, req = self.work.get()
            try:
                self._process(job_id, req)
            except Exception as exc:  # surface any pipeline failure to the UI
                self._emit(job_id, ProgressEvent(stage="error", pct=0.0, message=resolver.augment_error(exc)))

    def _process(self, job_id: str, req: DownloadRequest) -> None:
        with tempfile.TemporaryDirectory(prefix="yt-m-") as tmp:
            tmpdir = Path(tmp)

            self._emit(job_id, ProgressEvent(stage="download", pct=0.0, message="Starting download"))
            src = downloader.download_audio(
                req.url,
                tmpdir,
                lambda pct: self._emit(job_id, ProgressEvent(stage="download", pct=pct, message="Downloading audio")),
                self.cfg.pot_provider_url,
            )

            target = "ALAC (lossless)" if req.format == "alac" else "AAC 256 kbps"
            self._emit(job_id, ProgressEvent(stage="encode", pct=0.0, message=f"Encoding to {target}"))
            encoded = tmpdir / "encoded.m4a"
            downloader.encode(src, encoded, req.format)
            self._emit(job_id, ProgressEvent(stage="encode", pct=100.0, message="Encoded"))

            if req.cover == "keep":
                cover = resolver.read_cached_cover(req.video_id)
            else:
                try:
                    cover = resolver.to_square_jpeg(resolver.data_uri_to_bytes(req.cover))
                except Exception:
                    cover = None

            self._emit(job_id, ProgressEvent(stage="tag", pct=0.0, message="Writing tags"))
            tagger.write_tags(encoded, req.metadata, cover)
            self._emit(job_id, ProgressEvent(stage="tag", pct=100.0, message="Tags written"))

            library.ensure_output_dir(self.cfg.output_dir)
            dest = library.output_path(
                self.cfg.output_dir,
                req.metadata.album_artist or req.metadata.artist,
                req.metadata.title,
                req.video_id,
            )
            library.save(encoded, dest)
            library.record_recent(self.cfg.output_dir, {
                "path": str(dest),
                "title": req.metadata.title,
                "artist": req.metadata.artist,
                "album": req.metadata.album,
            })
            self._emit(job_id, ProgressEvent(stage="done", pct=100.0, message="Saved", file_path=str(dest)))


def _self_update_yt_dlp() -> None:
    try:
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "-U", "--quiet", "yt-dlp"],
            check=False, capture_output=True, timeout=180,
        )
    except Exception:
        pass


@asynccontextmanager
async def lifespan(_app: FastAPI):
    if os.getenv("YT_DLP_SELF_UPDATE", "1") == "1":
        threading.Thread(target=_self_update_yt_dlp, daemon=True).start()
    yield


app = FastAPI(lifespan=lifespan)
jobs = JobManager(cfg)
app.mount("/static", StaticFiles(directory=str(WEB_DIR)), name="static")


class RevealRequest(BaseModel):
    path: str


@app.get("/")
def index() -> FileResponse:
    return FileResponse(str(WEB_DIR / "index.html"))


@app.post("/resolve", response_model=ResolveResponse)
def resolve_endpoint(req: ResolveRequest) -> ResolveResponse:
    try:
        raw = resolver.resolve(req.url)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not resolve URL: {resolver.augment_error(exc)}")

    meta = metadata_ai.propose_metadata(raw, cfg)

    cover_uri = ""
    if raw.thumbnail:
        try:
            jpeg = resolver.to_square_jpeg(resolver.fetch_thumbnail(raw.thumbnail))
            resolver.cache_cover_jpeg(raw.video_id, jpeg)
            cover_uri = resolver.jpeg_to_data_uri(jpeg)
        except Exception:
            cover_uri = ""

    line = resolver.detected_line(raw.best_audio_label, cfg.default_format, str(cfg.output_dir))
    return ResolveResponse(
        video_id=raw.video_id,
        duration=raw.duration,
        metadata=meta,
        cover=cover_uri,
        formats=raw.formats_summary,
        detected_line=line,
        has_chapters=raw.has_chapters,
    )


@app.post("/download")
def download_endpoint(req: DownloadRequest) -> dict:
    job_id = jobs.submit(req)
    return {"job_id": job_id}


@app.get("/progress/{job_id}")
async def progress_endpoint(job_id: str) -> StreamingResponse:
    try:
        q = jobs.get_queue(job_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Unknown job")

    async def event_stream():
        while True:
            try:
                event = q.get_nowait()
            except queue.Empty:
                await asyncio.sleep(0.1)
                continue
            yield f"data: {event.model_dump_json()}\n\n"
            if event.stage in ("done", "error"):
                break
        jobs.jobs.pop(job_id, None)

    headers = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no", "Connection": "keep-alive"}
    return StreamingResponse(event_stream(), media_type="text/event-stream", headers=headers)


@app.get("/recent")
def recent_endpoint() -> list:
    return library.load_recent(cfg.output_dir)


@app.post("/reveal")
def reveal_endpoint(req: RevealRequest) -> dict:
    path = Path(req.path)
    if not path.exists():
        raise HTTPException(status_code=404, detail="File not found")
    try:
        subprocess.run(["open", "-R", str(path)], check=False)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return {"ok": True}
```

- [ ] **Step 2: Write the test `tests/test_api.py`**

```python
from fastapi.testclient import TestClient

from app.main import app


def test_recent_returns_list(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.get("/recent")
    assert resp.status_code == 200
    assert isinstance(resp.json(), list)


def test_reveal_missing_path_returns_404(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.post("/reveal", json={"path": "/no/such/file_xyz123.m4a"})
    assert resp.status_code == 404


def test_progress_unknown_job_returns_404(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.get("/progress/doesnotexist")
    assert resp.status_code == 404
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `pytest tests/test_api.py -v`
Expected: PASS — `3 passed`. (The `app` imports cleanly because `web/` exists from Task 1; routes that need network are not exercised here.)

- [ ] **Step 4: Run the whole suite so far**

Run: `pytest -q`
Expected: PASS — all tests pass (any ffmpeg-dependent ones may show as skipped if ffmpeg is absent). No failures.

- [ ] **Step 5: Commit**

```bash
git add app/main.py tests/test_api.py
git commit -m "feat: add FastAPI app, FIFO job manager, and SSE progress"
```

---

## Task 9: Web UI (single-column Layout A)

**Files:**
- Create: `web/index.html`
- Create: `web/styles.css`
- Create: `web/app.js`

- [ ] **Step 1: Create `web/index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>YouTube → Apple Music</title>
  <link rel="stylesheet" href="/static/styles.css" />
</head>
<body>
  <main class="container">
    <h1>YouTube → Apple Music</h1>
    <p class="sub">Paste a URL, review the metadata, and save a tagged ALAC file to drag into Apple Music.</p>

    <section class="row">
      <input id="url" type="text" placeholder="https://www.youtube.com/watch?v=…" autocomplete="off" />
      <button id="resolveBtn">Resolve</button>
    </section>

    <p id="status" class=""></p>

    <section id="preview" class="card hidden">
      <div class="preview-grid">
        <img id="cover" class="cover" alt="cover preview" />
        <div class="fields">
          <label>Title <input id="title" type="text" /></label>
          <label>Artist <input id="artist" type="text" /></label>
          <label>Album <input id="album" type="text" /></label>
          <label>Album Artist <input id="albumArtist" type="text" /></label>
          <div class="two">
            <label>Year <input id="year" type="number" inputmode="numeric" /></label>
            <label>Genre <input id="genre" type="text" /></label>
          </div>
          <label class="check"><input id="compilation" type="checkbox" /> Compilation (various artists)</label>
          <label class="check"><input id="aac256" type="checkbox" /> AAC 256 kbps (smaller files)</label>
          <label class="check disabled" title="Coming in v2">
            <input type="checkbox" disabled /> Split into separate tracks (v2)
          </label>
        </div>
      </div>
      <p id="detected" class="detected"></p>
      <button id="downloadBtn" class="primary">Download &amp; tag</button>
    </section>

    <section id="progress" class="card hidden">
      <div class="bar-track"><div id="bar" class="bar"></div></div>
      <p id="progressMsg"></p>
      <button id="revealDone" class="ghost" style="display:none">Reveal in Finder</button>
    </section>

    <section class="recent">
      <h2>Recent</h2>
      <ul id="recent"></ul>
    </section>
  </main>
  <script src="/static/app.js"></script>
</body>
</html>
```

- [ ] **Step 2: Create `web/styles.css`**

```css
:root {
  --bg: #0f1115;
  --card: #181b22;
  --line: #262b35;
  --text: #e8eaed;
  --muted: #9aa3b2;
  --accent: #fa2d6e;
  --ok: #3ddc84;
  --err: #ff6b6b;
}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
}

.container { max-width: 640px; margin: 0 auto; padding: 32px 20px 64px; }

h1 { font-size: 24px; margin: 0 0 4px; }
.sub { color: var(--muted); margin: 0 0 24px; }

.row { display: flex; gap: 8px; }

input[type="text"], input[type="number"] {
  width: 100%;
  padding: 10px 12px;
  background: #11141a;
  border: 1px solid var(--line);
  border-radius: 8px;
  color: var(--text);
}

button {
  padding: 10px 16px;
  border: 1px solid var(--line);
  border-radius: 8px;
  background: #20242d;
  color: var(--text);
  cursor: pointer;
  white-space: nowrap;
}
button:hover { border-color: #3a414d; }
button:disabled { opacity: 0.5; cursor: not-allowed; }
button.primary { background: var(--accent); border-color: var(--accent); color: #fff; width: 100%; margin-top: 8px; }
button.ghost { background: transparent; }

.card { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px; margin-top: 16px; }
.hidden { display: none; }

.preview-grid { display: grid; grid-template-columns: 160px 1fr; gap: 16px; }
.cover { width: 160px; height: 160px; object-fit: cover; border-radius: 8px; background: #11141a; border: 1px solid var(--line); }

.fields { display: flex; flex-direction: column; gap: 8px; }
.fields label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--muted); }
.fields .two { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
.fields .check { flex-direction: row; align-items: center; gap: 8px; font-size: 13px; color: var(--text); }
.fields .check.disabled { color: var(--muted); }

.detected { color: var(--muted); font-size: 13px; margin: 14px 0 4px; }

.bar-track { height: 8px; background: #11141a; border-radius: 999px; overflow: hidden; }
.bar { height: 100%; width: 0; background: var(--ok); transition: width 0.2s ease; }
#progressMsg { color: var(--muted); font-size: 13px; }

#status { min-height: 18px; font-size: 13px; }
#status.err { color: var(--err); }

.recent { margin-top: 28px; }
.recent h2 { font-size: 14px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; }
.recent ul { list-style: none; padding: 0; margin: 0; }
.recent li { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 8px 0; border-bottom: 1px solid var(--line); font-size: 14px; }

@media (max-width: 520px) {
  .preview-grid { grid-template-columns: 1fr; }
  .cover { width: 100%; height: auto; aspect-ratio: 1 / 1; }
}
```

- [ ] **Step 3: Create `web/app.js`**

```javascript
const $ = (id) => document.getElementById(id);
const state = { videoId: "", url: "", detectedAlac: "" };

async function resolve() {
  const url = $("url").value.trim();
  if (!url) return;
  setStatus("Resolving…");
  $("resolveBtn").disabled = true;
  try {
    const res = await fetch("/resolve", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url }),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ detail: res.statusText }));
      throw new Error(err.detail || "Resolve failed");
    }
    const data = await res.json();
    state.videoId = data.video_id;
    state.url = url;
    state.detectedAlac = data.detected_line;
    $("cover").src = data.cover || "";
    $("title").value = data.metadata.title || "";
    $("artist").value = data.metadata.artist || "";
    $("album").value = data.metadata.album || "";
    $("albumArtist").value = data.metadata.album_artist || "";
    $("year").value = data.metadata.year ?? "";
    $("genre").value = data.metadata.genre || "";
    $("compilation").checked = !!data.metadata.compilation;
    updateDetected();
    show("preview");
    setStatus("");
  } catch (err) {
    setStatus("Error: " + err.message, true);
  } finally {
    $("resolveBtn").disabled = false;
  }
}

function updateDetected() {
  let line = state.detectedAlac;
  if ($("aac256").checked) {
    line = line
      .replace("→ ALAC lossless", "→ AAC 256 kbps")
      .replace(" · ALAC files are ~5-10x the source size", "");
  }
  $("detected").textContent = line;
}

async function download() {
  if (!state.videoId) return;
  const body = {
    video_id: state.videoId,
    url: state.url,
    format: $("aac256").checked ? "aac256" : "alac",
    cover: "keep",
    metadata: {
      title: $("title").value,
      artist: $("artist").value,
      album: $("album").value,
      album_artist: $("albumArtist").value,
      year: $("year").value ? parseInt($("year").value, 10) : null,
      genre: $("genre").value,
      comment: state.url,
      compilation: $("compilation").checked,
    },
  };
  $("downloadBtn").disabled = true;
  $("revealDone").style.display = "none";
  show("progress");
  setBar(0);
  setStatus("");
  $("progressMsg").textContent = "Starting…";
  try {
    const res = await fetch("/download", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error("Download request failed");
    const { job_id } = await res.json();
    const es = new EventSource(`/progress/${job_id}`);
    es.onmessage = (e) => {
      const ev = JSON.parse(e.data);
      $("progressMsg").textContent = `${ev.stage}: ${ev.message}`;
      if (["download", "encode", "tag"].includes(ev.stage)) setBar(ev.pct);
      if (ev.stage === "done") {
        setBar(100);
        es.close();
        onDone(ev.file_path);
      }
      if (ev.stage === "error") {
        es.close();
        setStatus("Error: " + ev.message, true);
        $("downloadBtn").disabled = false;
      }
    };
    es.onerror = () => {
      es.close();
      $("downloadBtn").disabled = false;
    };
  } catch (err) {
    setStatus("Error: " + err.message, true);
    $("downloadBtn").disabled = false;
  }
}

function onDone(path) {
  $("progressMsg").textContent = "Saved ✓";
  $("downloadBtn").disabled = false;
  const reveal = $("revealDone");
  reveal.style.display = "inline-block";
  reveal.onclick = () => revealPath(path);
  loadRecent();
}

async function revealPath(path) {
  await fetch("/reveal", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ path }),
  });
}

async function loadRecent() {
  try {
    const res = await fetch("/recent");
    const items = await res.json();
    const ul = $("recent");
    ul.innerHTML = "";
    items.forEach((it) => {
      const li = document.createElement("li");
      const span = document.createElement("span");
      span.textContent = `${it.artist || ""} — ${it.title || ""}`;
      const btn = document.createElement("button");
      btn.className = "ghost";
      btn.textContent = "Reveal";
      btn.onclick = () => revealPath(it.path);
      li.appendChild(span);
      li.appendChild(btn);
      ul.appendChild(li);
    });
  } catch (e) {
    /* ignore */
  }
}

function setBar(pct) {
  $("bar").style.width = Math.max(0, Math.min(100, pct)) + "%";
}

function setStatus(msg, isError) {
  const el = $("status");
  el.textContent = msg || "";
  el.className = isError ? "err" : "";
}

function show(id) {
  $(id).classList.remove("hidden");
}

window.addEventListener("DOMContentLoaded", () => {
  $("resolveBtn").addEventListener("click", resolve);
  $("downloadBtn").addEventListener("click", download);
  $("aac256").addEventListener("change", updateDetected);
  $("url").addEventListener("keydown", (e) => {
    if (e.key === "Enter") resolve();
  });
  loadRecent();
});
```

- [ ] **Step 4: Verify the server serves the UI**

Run (starts the server, waits, checks `/`, then stops it):

```bash
source .venv/bin/activate && YT_DLP_SELF_UPDATE=0 uvicorn app.main:app --host 127.0.0.1 --port 8765 & SERVER_PID=$!; sleep 3; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8765/; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8765/static/app.js; kill $SERVER_PID
```

Expected: prints `200` then `200` (index page and the static JS both serve). Then the server is stopped.

- [ ] **Step 5: Commit**

```bash
git add web/index.html web/styles.css web/app.js
git commit -m "feat: add single-column Layout A web UI with SSE progress"
```

---

## Task 10: run.sh, README, smoke test & final verification

**Files:**
- Create: `run.sh`
- Create: `README.md`
- Create: `tests/test_smoke.py`

- [ ] **Step 1: Create `run.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Create the virtualenv on first run and install the app.
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
# shellcheck disable=SC1091
source .venv/bin/activate
pip install -q -e . >/dev/null

# Load PORT (and any other settings) from .env if present.
set -a
[ -f .env ] && source .env
set +a
PORT="${PORT:-8765}"

# Open the browser shortly after the server starts.
( sleep 1.5; open "http://127.0.0.1:${PORT}" >/dev/null 2>&1 || true ) &

exec uvicorn app.main:app --host 127.0.0.1 --port "${PORT}"
```

- [ ] **Step 2: Make `run.sh` executable**

Run: `chmod +x run.sh`
Expected: no output; `ls -l run.sh` shows the `x` permission bits.

- [ ] **Step 3: Create `tests/test_smoke.py` (optional, network; skipped by default)**

```python
import os
import shutil

import pytest
from mutagen.mp4 import MP4

from app.core import downloader, tagger
from app.core.resolver import resolve, fetch_thumbnail, to_square_jpeg
from app.models import MetadataFields

# Big Buck Bunny — Creative Commons.
CC_URL = os.getenv("SMOKE_URL", "https://www.youtube.com/watch?v=aqz-KE-bpKQ")


@pytest.mark.skipif(os.getenv("RUN_SMOKE") != "1", reason="set RUN_SMOKE=1 to run the network smoke test")
def test_end_to_end_download_encode_tag(tmp_path):
    if not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg not installed")

    raw = resolve(CC_URL)
    src = downloader.download_audio(raw.url, tmp_path, lambda pct: None)

    out = tmp_path / "out.m4a"
    downloader.encode(src, out, "alac")

    cover = None
    if raw.thumbnail:
        cover = to_square_jpeg(fetch_thumbnail(raw.thumbnail))

    meta = MetadataFields(
        title=raw.title or "Smoke Test",
        artist=raw.uploader or "Smoke",
        album="Smoke Album",
        album_artist=raw.uploader or "Smoke",
        year=2025,
        genre="",
        comment=raw.url,
        compilation=False,
    )
    tagger.write_tags(out, meta, cover)

    audio = MP4(str(out))
    assert audio.info.length > 0
    assert audio["\xa9nam"][0]
    assert audio["pgap"] is True
    if cover:
        assert "covr" in audio
```

- [ ] **Step 4: Create `README.md`**

````markdown
# YouTube → Apple Music Downloader (v1)

A personal, local-only macOS tool. Paste a YouTube URL → download the best audio →
transcode losslessly to Apple-Music-compatible **ALAC `.m4a`** (or AAC-256) → embed a
square JPEG cover + AI-assisted, editable metadata → save a fully tagged file you drag
into Apple Music. Files-only: nothing is auto-imported.

## Prerequisites

- macOS, Python 3.11+
- **ffmpeg** (required): `brew install ffmpeg`
- **AtomicParsley** (optional cover fallback): `brew install atomicparsley`

## Setup

```bash
cp .env.example .env   # then edit .env and add your keys
./run.sh               # creates .venv, installs, opens the browser
```

`run.sh` starts the server on `http://127.0.0.1:8765` (loopback only) and opens your browser.

## Configuration (`.env`)

| Key | Default | Notes |
|-----|---------|-------|
| `OPENAI_API_KEY` | — | Required for AI metadata; without it, falls back to title parsing |
| `FIRECRAWL_API_KEY` | — | Optional web enrichment; skipped if unset |
| `OPENAI_MODEL` | `gpt-4o-mini` | Cheap, fast default |
| `OUTPUT_DIR` | `~/Music/YouTube Sets` | Created on first run |
| `DEFAULT_FORMAT` | `alac` | UI toggle switches to `aac256` |
| `PORT` | `8765` | Loopback server port |
| `POT_PROVIDER_URL` | empty | Optional PO-token provider sidecar for YouTube bot checks |

## Usage

1. Paste a YouTube URL, click **Resolve**.
2. Review/edit Title, Artist, Album, Album Artist, Year, Genre, Compilation; optionally toggle **AAC 256**.
3. Click **Download & tag**; watch live progress.
4. When done, **Reveal in Finder** and drag the `.m4a` into Apple Music.

Apple Music groups an album by **Album** (`©alb`) + **Album Artist** (`aART`); the tool sets a
consistent `aART`, `trkn=(1,1)`, and `pgap=1` (gapless) so files import cleanly.

## Tests

```bash
pip install -e ".[dev]"
pytest -q                 # unit tests (ffmpeg-dependent ones skip if ffmpeg is missing)
RUN_SMOKE=1 pytest tests/test_smoke.py -v   # optional end-to-end network test
```

## Notes

- ALAC is lossless: it adds no quality beyond YouTube's already-lossy source, and produces files
  ~5-10× the source size. Use the **AAC 256** toggle for smaller files. Output is never represented
  as higher quality than the source.
- yt-dlp self-updates best-effort on launch; set `YT_DLP_SELF_UPDATE=0` to disable.
- If YouTube throws bot checks, set `POT_PROVIDER_URL` to a running PO-token provider sidecar.

## Out of scope (v2)

Splitting long DJ sets into per-track albums is a future v2 feature. The UI shows a disabled
"Split into separate tracks (v2)" placeholder; it does nothing in v1.
````

- [ ] **Step 5: Run the full test suite**

Run: `pytest -q`
Expected: PASS — all unit tests pass; `tests/test_smoke.py` shows `1 skipped` (network test off by default); ffmpeg-dependent tests pass if ffmpeg is installed (else skipped). No failures.

- [ ] **Step 6: Commit**

```bash
git add run.sh README.md tests/test_smoke.py
git commit -m "feat: add run.sh launcher, README, and optional smoke test"
```

---

## Final verification checklist (run after Task 10)

- [ ] `pytest -q` → all pass / appropriate skips, no failures.
- [ ] `./run.sh` opens the browser; pasting a URL shows an editable preview with a square cover and a `Detected: …` line.
- [ ] Toggling **AAC 256** flips the detected line to `→ AAC 256 kbps` and removes the size note.
- [ ] **Download & tag** streams `download → encode → tag → done`, then **Reveal in Finder** opens the saved `.m4a`.
- [ ] Dragging the output into Apple Music imports it as one album with the correct cover and grouping.
