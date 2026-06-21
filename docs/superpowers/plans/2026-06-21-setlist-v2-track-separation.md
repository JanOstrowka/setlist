# Setlist v2 — Track Separation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Activate the greyed-out "Split into separate tracks" toggle so a resolved YouTube DJ-set/mix can be cut **losslessly** into a cohesive **gapless album** of per-track `.m4a` files, with an editable tracklist sourced (in priority order) from YouTube chapters → description timestamps → manual paste.

**Architecture:** Reuse the framework-free `app/core/` engine. Two new core modules: `tracklist.py` (parse + normalize the three sources into a typed `Tracklist`/`Track`) and `splitter.py` (compute per-track end = next start, last = file end; cut with `ffmpeg -ss START -to END -i full.m4a -c copy`). The full set is downloaded + encoded **once**, then split and tagged as one album (`tagger.tag_album` reuses the existing `write_tags`). The web layer adds a `/parse-tracklist` helper and a `/download-split` job that reuses the existing FIFO `JobManager` + SSE, emitting per-track progress. The v1 single-track flow is unchanged when the toggle is OFF.

**Save layout (NEW — applies to BOTH v1 single-track and v2 split):** Files are organized as `OUTPUT_DIR/<Artist>/<Set>/…` where **Artist = Album Artist (fallback Artist)** and **Set = Album (fallback Title)**. A single track saves to `<Set>/<Title>.m4a`; a split album saves to `<Set>/01 - Track.m4a`, `02 - …`. Each set folder also gets a standalone `cover.jpg` (the same square JPEG embedded into the audio) for setting Apple Music *playlist* artwork. Default `OUTPUT_DIR` is the Apple Music media folder `~/Music/Music/Media/Music`.

**Tech Stack:** Python 3.11+ (3.14 in the live `.venv`), FastAPI, yt-dlp (library), ffmpeg (subprocess, stream-copy cutting), mutagen (MP4 atoms), Pillow, pydantic v2, pytest. Vanilla JS/HTML/CSS UI (no build step).

---

## Scope: build vs. defer

**Build (v2):**
- Tracklist sources in priority order: (1) YouTube chapters, (2) description timestamps, (3) manual paste/edit.
- Editable tracklist UI (rows of start · title · artist; add/remove/reorder/edit) reusing the v1 album-level metadata fields (Album, Album Artist, Year, Genre, Cover).
- Lossless splitter + gapless-album tagging (consistent `©alb`/`aART`, sequential `trkn=(n,total)`, `disk=(1,1)`, `pgap=1`, `cpil=1` when track artists differ).
- New save layout `OUTPUT_DIR/<Artist>/<Set>/…` for v1 + v2, plus standalone `cover.jpg` per set folder.

**Defer (DO NOT build — leave a clean extension point + "Future" note):**
- Automated **1001tracklists scraping** (Cloudflare-Turnstile-gated, no official API).
- **Audio fingerprinting** (AudD / Panako).
Both are documented as future tracklist sources behind the same `Tracklist`/`Track` interface, so they can be added as additional `parse_*()` producers later without touching the splitter/tagger/UI.

---

## Resolved decisions (read before starting)

1. **`/resolve` always includes a proposed `tracklist`.** Building it from chapters/description is pure and cheap (the data already comes from the single `extract_info` call), so we always return it and the UI simply reveals it when the toggle is ON. This avoids a second network round-trip when the user toggles split on after resolving. (Superset of the spec's "include when split is requested".)
2. **`/parse-tracklist`** is a pure, no-network endpoint for the manual-paste box: it parses + normalizes pasted text into a `Tracklist`.
3. **`/download-split`** is a separate endpoint (does not overload `/download`), reusing the same `JobManager`/SSE. It downloads + encodes the full set **once**, then splits + tags.
4. **`Track.start` is `Optional[float]`** because manual paste may omit timestamps (user fills them in). The splitter and `/download-split` validate that every start is present and raise a clear error otherwise.
5. **Lossless cut uses input-side seeking:** `ffmpeg -ss <start> -to <end> -i full.m4a -c copy -map 0:a`. With **both** `-ss` and `-to` placed **before** `-i`, `-to` is an absolute position in the input timeline, yielding the `[start, end)` segment. The splitter test asserts per-segment durations, locking this behavior.
6. **Save layout `OUTPUT_DIR/<Artist>/<Set>/…`** replaces v1's flat `"<Album Artist> - <Title> [<id>].m4a"`. The `[video_id]` suffix is dropped; folder structure disambiguates. Re-downloading the same set overwrites in place.
7. **Default `OUTPUT_DIR = ~/Music/Music/Media/Music`** (Apple Music media folder). The real `.env` is already set by the user to the absolute form and is gitignored — **never read, touch, or stage `.env`.**
8. **Standalone `cover.jpg`** is written into each set folder whenever a cover is available (skipped silently if none); the cover is still embedded into the audio as before.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `app/config.py` | `Config.output_dir` default | Modify: default → `~/Music/Music/Media/Music` |
| `.env.example` | Documented template | Modify: `OUTPUT_DIR` default comment/value |
| `app/models.py` | Pydantic schemas | Modify: add `Track`, `Tracklist`, `SplitDownloadRequest`; add `"split"` to `ProgressEvent.stage`; add `ResolveResponse.tracklist` |
| `app/core/library.py` | Filenames, save, recent, cover | Modify: `sanitize_filename` hardening; add `set_output_dir`, `single_track_path`, `track_filename`, `write_cover`; remove `output_path` |
| `app/core/resolver.py` | yt-dlp info | Modify: add `RawInfo.chapters` + populate it |
| `app/core/tracklist.py` | Parse/normalize 3 sources → `Tracklist` | **Create** |
| `app/core/splitter.py` | End-time computation + lossless cut | **Create** |
| `app/core/tagger.py` | MP4 atoms | Modify: add `tag_album()` |
| `app/main.py` | Routes + JobManager | Modify: v1 save path; `/resolve` tracklist; `/parse-tracklist`; `/download-split`; `_process_split` |
| `web/index.html` | UI markup | Modify: activate split toggle; add tracklist editor |
| `web/styles.css` | UI styling | Modify: tracklist editor styles |
| `web/app.js` | UI logic | Modify: tracklist editor, manual paste, split download |
| `README.md` | Docs | Modify: v2 usage + layout |
| `tests/test_config_models.py` | Config/model defaults | Modify: new default; new models |
| `tests/test_library.py` | Library | Modify: `<Artist>/<Set>/` structure, `cover.jpg`, helpers |
| `tests/test_tracklist.py` | Tracklist parsing/normalize | **Create** |
| `tests/test_splitter.py` | Splitter (synthetic audio) | **Create** |
| `tests/test_tagger_album.py` | Album tagging cohesion | **Create** |
| `tests/test_api.py` | API | Modify: `/parse-tracklist`, `/download-split` validation |

---

## Task 1: Output location + `<Artist>/<Set>/` save layout (v1 + v2 foundation)

Changes the default output folder and the on-disk organization for the **existing v1 single-track flow** (v2 reuses the same helpers). Also adds the standalone `cover.jpg` writer.

**Files:**
- Modify: `app/config.py`
- Modify: `.env.example`
- Modify: `app/core/library.py`
- Modify: `app/main.py` (v1 `_process` save path + cover.jpg)
- Modify: `tests/test_config_models.py`
- Modify: `tests/test_library.py`

- [ ] **Step 1: Update the failing library tests**

Replace the body of `tests/test_library.py` with (note the new imports and the `<Artist>/<Set>/` assertions):

```python
from pathlib import Path

from app.core.library import (
    sanitize_filename,
    set_output_dir,
    single_track_path,
    track_filename,
    write_cover,
    save,
    ensure_output_dir,
    record_recent,
    load_recent,
)


def test_sanitize_replaces_illegal_chars():
    assert sanitize_filename("AC/DC: Live") == "AC-DC- Live"
    assert sanitize_filename("   ") == "untitled"


def test_sanitize_strips_trailing_dots_and_spaces():
    assert sanitize_filename("Set Name. ") == "Set Name"
    assert sanitize_filename(".hidden") == "hidden"


def test_sanitize_strips_control_chars():
    assert sanitize_filename("a\x00b\x1fc") == "abc"


def test_set_output_dir_structure(tmp_path):
    d = set_output_dir(tmp_path, "DJ Test", "DJ Test", "Sunset Set", "Sunset Set")
    assert d == Path(tmp_path) / "DJ Test" / "Sunset Set"


def test_set_output_dir_falls_back(tmp_path):
    # album_artist empty -> artist; album empty -> title
    d = set_output_dir(tmp_path, "", "The Artist", "", "The Title")
    assert d == Path(tmp_path) / "The Artist" / "The Title"


def test_set_output_dir_sanitizes(tmp_path):
    d = set_output_dir(tmp_path, "AC/DC", "AC/DC", "Back: In", "x")
    assert d == Path(tmp_path) / "AC-DC" / "Back- In"


def test_single_track_path(tmp_path):
    p = single_track_path(tmp_path, "DJ Test", "DJ Test", "Sunset Set", "Opening")
    assert p == Path(tmp_path) / "DJ Test" / "Sunset Set" / "Opening.m4a"


def test_track_filename():
    assert track_filename(1, "Intro") == "01 - Intro.m4a"
    assert track_filename(12, "AC/DC") == "12 - AC-DC.m4a"
    assert track_filename(3, "") == "03 - Untitled.m4a"


def test_write_cover_writes_jpg(tmp_path):
    set_dir = tmp_path / "Artist" / "Set"
    p = write_cover(set_dir, b"jpeg-bytes")
    assert p == set_dir / "cover.jpg"
    assert p.read_bytes() == b"jpeg-bytes"


def test_write_cover_skips_when_none(tmp_path):
    assert write_cover(tmp_path / "x", None) is None
    assert not (tmp_path / "x" / "cover.jpg").exists()


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
    record_recent(tmp_path, {"path": "/x/24.m4a", "title": "24", "artist": "a", "album": "b"})
    items = load_recent(tmp_path)
    assert len(items) == 20
    assert items[0]["path"] == "/x/24.m4a"
    paths = [it["path"] for it in items]
    assert len(paths) == len(set(paths))


def test_load_recent_missing_returns_empty(tmp_path):
    assert load_recent(tmp_path) == []
```

- [ ] **Step 2: Update the config default test**

In `tests/test_config_models.py`, change the two assertions that reference `"YouTube Sets"`:

- In `test_config_defaults`, replace:

```python
    assert str(cfg.output_dir).endswith("YouTube Sets")
```

with:

```python
    assert str(cfg.output_dir).endswith("Media/Music")
```

- In `test_output_dir_expands_tilde`, replace both the `setenv` line and the final assertion:

```python
    monkeypatch.setenv("OUTPUT_DIR", "~/Music/Music/Media/Music")
    cfg = load_config()
    assert cfg.output_dir.is_absolute()
    assert "~" not in str(cfg.output_dir)
    assert str(cfg.output_dir).startswith(os.path.expanduser("~"))
    assert str(cfg.output_dir).endswith("Media/Music")
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `pytest tests/test_library.py tests/test_config_models.py -q`
Expected: FAIL — `ImportError` for `set_output_dir`/`single_track_path`/`track_filename`/`write_cover`, and config assertions fail on the old `YouTube Sets` default.

- [ ] **Step 4: Update `app/config.py` default**

Change the `output_dir` line in `load_config()`:

```python
        output_dir=_expand(os.getenv("OUTPUT_DIR", "~/Music/Music/Media/Music")),
```

- [ ] **Step 5: Update `.env.example`**

Replace the `OUTPUT_DIR` line:

```bash
OUTPUT_DIR="~/Music/Music/Media/Music"
```

- [ ] **Step 6: Rewrite `app/core/library.py`**

Replace the whole file with (hardened `sanitize_filename`; new `<Artist>/<Set>/` helpers; `write_cover`; `output_path` removed):

```python
from __future__ import annotations

import json
import re
import shutil
from pathlib import Path

_ILLEGAL = {"/": "-", ":": "-"}
_RECENT_FILE = ".setlist-recent.json"
_RECENT_CAP = 20


def sanitize_filename(name: str) -> str:
    """Make a string safe + readable as a single macOS/APFS path component."""
    cleaned = name or ""
    for bad, good in _ILLEGAL.items():
        cleaned = cleaned.replace(bad, good)
    cleaned = re.sub(r"[\x00-\x1f]", "", cleaned)        # strip control chars
    cleaned = re.sub(r"\s{2,}", " ", cleaned).strip()    # collapse whitespace
    cleaned = cleaned.strip(" .")                        # no leading/trailing dots or spaces
    return cleaned or "untitled"


def ensure_output_dir(output_dir: Path | str) -> Path:
    path = Path(output_dir).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    return path


def set_output_dir(
    output_dir: Path | str,
    album_artist: str,
    artist: str,
    album: str,
    title: str,
) -> Path:
    """Folder for one set/album: OUTPUT_DIR/<Artist>/<Set>/.

    Artist = Album Artist (fallback Artist); Set = Album (fallback Title).
    """
    artist_name = sanitize_filename(album_artist or artist or "Unknown Artist")
    set_name = sanitize_filename(album or title or "Untitled")
    return Path(output_dir).expanduser() / artist_name / set_name


def single_track_path(
    output_dir: Path | str,
    album_artist: str,
    artist: str,
    album: str,
    title: str,
) -> Path:
    """v1 single track destination: OUTPUT_DIR/<Artist>/<Set>/<Title>.m4a."""
    set_dir = set_output_dir(output_dir, album_artist, artist, album, title)
    return set_dir / f"{sanitize_filename(title or 'Untitled')}.m4a"


def track_filename(index: int, title: str) -> str:
    """v2 per-track filename inside the set folder: 'NN - Title.m4a'."""
    return f"{index:02d} - {sanitize_filename(title or 'Untitled')}.m4a"


def write_cover(set_dir: Path | str, cover_jpeg: bytes | None) -> Path | None:
    """Write a standalone cover.jpg into the set folder (for Apple Music playlist
    artwork). No-op when there is no cover; never raises on a missing cover."""
    if not cover_jpeg:
        return None
    folder = ensure_output_dir(set_dir)
    path = folder / "cover.jpg"
    path.write_bytes(cover_jpeg)
    return path


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

- [ ] **Step 7: Update `app/main.py` v1 save path + cover.jpg**

In `JobManager._process`, replace the save/record block (the part from `library.ensure_output_dir(...)` through the `done` emit) with:

```python
            dest = library.single_track_path(
                self.cfg.output_dir,
                req.metadata.album_artist,
                req.metadata.artist,
                req.metadata.album,
                req.metadata.title,
            )
            library.save(encoded, dest)
            library.write_cover(dest.parent, cover)
            library.record_recent(self.cfg.output_dir, {
                "path": str(dest),
                "title": req.metadata.title,
                "artist": req.metadata.artist,
                "album": req.metadata.album,
            })
            self._emit(job_id, ProgressEvent(stage="done", pct=100.0, message="Saved", file_path=str(dest)))
```

(`cover` is already computed just above this block in `_process`.)

- [ ] **Step 8: Run the tests to verify they pass**

Run: `pytest tests/test_library.py tests/test_config_models.py tests/test_api.py -q`
Expected: PASS — all green. (`test_api.py` imports `app.main`, confirming the v1 save edit is valid.)

- [ ] **Step 9: Run the full suite**

Run: `pytest -q`
Expected: PASS — `33 passed, 1 skipped` (same totals; v1 behavior changed but tests updated).

- [ ] **Step 10: Commit**

```bash
git add app/config.py .env.example app/core/library.py app/main.py tests/test_library.py tests/test_config_models.py
git commit -m "feat: organize output as <Artist>/<Set>/ with cover.jpg; default to Apple Music media folder"
```

---

## Task 2: Data models — `Track`, `Tracklist`, `SplitDownloadRequest` (TDD)

**Files:**
- Modify: `app/models.py`
- Test: `tests/test_models_v2.py`

- [ ] **Step 1: Write the failing test `tests/test_models_v2.py`**

```python
from app.models import (
    Track,
    Tracklist,
    SplitDownloadRequest,
    MetadataFields,
    ProgressEvent,
    ResolveResponse,
)


def test_track_defaults():
    t = Track()
    assert t.start is None
    assert t.title == ""
    assert t.artist == ""
    assert t.end is None


def test_tracklist_defaults():
    tl = Tracklist()
    assert tl.source == "none"
    assert tl.tracks == []


def test_split_download_request_defaults():
    req = SplitDownloadRequest(
        video_id="abc",
        url="https://x",
        metadata=MetadataFields(),
        tracks=[Track(start=0.0, title="A")],
    )
    assert req.format == "alac"
    assert req.cover == "keep"
    assert req.tracks[0].title == "A"


def test_progress_event_accepts_split_stage():
    ev = ProgressEvent(stage="split", pct=50.0, message="Cut 1/2")
    assert ev.stage == "split"


def test_resolve_response_tracklist_optional():
    resp = ResolveResponse(
        video_id="v", duration=10, metadata=MetadataFields(),
        cover="", formats="", detected_line="", has_chapters=False,
    )
    assert resp.tracklist is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_models_v2.py -q`
Expected: FAIL — `ImportError: cannot import name 'Track'`.

- [ ] **Step 3: Update `app/models.py`**

Change the import line and add the new models. Replace the file's contents with:

```python
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field


class MetadataFields(BaseModel):
    title: str = ""
    artist: str = ""
    album: str = ""
    album_artist: str = ""
    year: Optional[int] = None
    genre: str = ""
    comment: str = ""  # source YouTube URL (provenance)
    compilation: bool = False


class Track(BaseModel):
    start: Optional[float] = None  # seconds from set start; None until user fills a manual row
    title: str = ""
    artist: str = ""
    end: Optional[float] = None  # exclusive end in seconds; computed by the splitter


class Tracklist(BaseModel):
    source: Literal["chapters", "description", "manual", "none"] = "none"
    tracks: list[Track] = Field(default_factory=list)


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
    tracklist: Optional[Tracklist] = None  # proposed split tracklist (chapters/description/none)


class DownloadRequest(BaseModel):
    video_id: str
    url: str
    metadata: MetadataFields
    format: Literal["alac", "aac256"] = "alac"
    cover: str = "keep"  # "keep" reuses the server-cached cover, or a data URI overrides it


class SplitDownloadRequest(BaseModel):
    video_id: str
    url: str
    metadata: MetadataFields  # album-level fields shared across tracks
    tracks: list[Track]
    format: Literal["alac", "aac256"] = "alac"
    cover: str = "keep"


class ProgressEvent(BaseModel):
    stage: Literal["queued", "download", "encode", "split", "tag", "done", "error"]
    pct: float = 0.0
    message: str = ""
    file_path: Optional[str] = None
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_models_v2.py -q`
Expected: PASS — `5 passed`.

- [ ] **Step 5: Commit**

```bash
git add app/models.py tests/test_models_v2.py
git commit -m "feat: add Track/Tracklist/SplitDownloadRequest models and split progress stage"
```

---

## Task 3: Resolver chapters + `tracklist.py` (TDD)

Adds raw chapter data to `RawInfo`, then the parser/normalizer for the three sources.

**Files:**
- Modify: `app/core/resolver.py`
- Create: `app/core/tracklist.py`
- Test: `tests/test_tracklist.py`

- [ ] **Step 1: Write the failing test `tests/test_tracklist.py`**

```python
from app.core.resolver import RawInfo
from app.core.tracklist import (
    parse_chapters,
    parse_description,
    parse_manual,
    normalize,
    build_tracklist,
    parse_manual_tracklist,
)
from app.models import Track


def _raw(**overrides) -> RawInfo:
    base = dict(
        video_id="v", url="u", title="", description="", uploader="C",
        upload_date="20240101", thumbnail="", duration=3600, has_chapters=False,
        best_audio_label="", formats_summary="", chapters=[],
    )
    base.update(overrides)
    return RawInfo(**base)


def test_parse_chapters_splits_artist_title():
    chs = [
        {"start_time": 0.0, "end_time": 120.0, "title": "DJ A - Intro"},
        {"start_time": 120.0, "end_time": 240.0, "title": "Second"},
    ]
    tracks = parse_chapters(chs)
    assert tracks[0].start == 0.0 and tracks[0].artist == "DJ A" and tracks[0].title == "Intro"
    assert tracks[1].artist == "" and tracks[1].title == "Second"


def test_parse_description_mm_ss_and_hh_mm_ss():
    desc = "0:00 Artist One - First\n3:24 Second Track\n1:02:33 Closing"
    tracks = parse_description(desc)
    assert [t.start for t in tracks] == [0.0, 204.0, 3753.0]
    assert tracks[0].artist == "Artist One" and tracks[0].title == "First"
    assert tracks[1].title == "Second Track"


def test_parse_description_brackets_and_index():
    desc = "1. [12:34] Bracketed\n2) 1:00 A - B\nrandom line without time"
    tracks = parse_description(desc)
    assert len(tracks) == 2
    assert tracks[0].start == 754.0 and tracks[0].title == "Bracketed"
    assert tracks[1].start == 60.0 and tracks[1].artist == "A" and tracks[1].title == "B"


def test_parse_manual_three_formats():
    text = "1. Artist - Title [1:23]\nSecond Artist - Second Title\n2:00 Third Title"
    tracks = parse_manual(text)
    assert tracks[0].start == 83.0 and tracks[0].artist == "Artist" and tracks[0].title == "Title"
    assert tracks[1].start is None and tracks[1].artist == "Second Artist" and tracks[1].title == "Second Title"
    assert tracks[2].start == 120.0 and tracks[2].title == "Third Title"


def test_normalize_sorts_and_dedups():
    tracks = [Track(start=120, title="B"), Track(start=0, title="A"), Track(start=120, title="B dup")]
    out = normalize(tracks, 3600)
    assert [t.start for t in out] == [0, 120]
    assert out[0].title == "A"


def test_normalize_drops_beyond_duration():
    tracks = [Track(start=0, title="A"), Track(start=5000, title="too late")]
    out = normalize(tracks, 3600)
    assert [t.start for t in out] == [0]


def test_normalize_keeps_manual_order_when_starts_missing():
    tracks = [Track(start=None, title="First"), Track(start=None, title="Second")]
    out = normalize(tracks)
    assert [t.title for t in out] == ["First", "Second"]


def test_build_tracklist_prefers_chapters():
    raw = _raw(chapters=[{"start_time": 0, "end_time": 10, "title": "Ch"}], description="0:00 Desc")
    tl = build_tracklist(raw)
    assert tl.source == "chapters" and tl.tracks[0].title == "Ch"


def test_build_tracklist_falls_back_to_description():
    raw = _raw(chapters=[], description="0:00 Foo\n2:00 Bar")
    tl = build_tracklist(raw)
    assert tl.source == "description" and len(tl.tracks) == 2


def test_build_tracklist_empty_when_nothing():
    raw = _raw(chapters=[], description="no timestamps here")
    tl = build_tracklist(raw)
    assert tl.source == "none" and tl.tracks == []


def test_parse_manual_tracklist_normalizes():
    tl = parse_manual_tracklist("2:00 B\n0:00 A", 3600)
    assert tl.source == "manual"
    assert [t.start for t in tl.tracks] == [0.0, 120.0]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_tracklist.py -q`
Expected: FAIL — `TypeError: __init__() got an unexpected keyword argument 'chapters'` (RawInfo) and `ModuleNotFoundError: No module named 'app.core.tracklist'`.

- [ ] **Step 3: Add `chapters` to `RawInfo` in `app/core/resolver.py`**

Change the import at the top:

```python
from dataclasses import dataclass, field
```

Add the field to the end of the `RawInfo` dataclass (after `formats_summary`):

```python
    formats_summary: str
    chapters: list[dict] = field(default_factory=list)
```

Populate it inside `resolve()` in the `return RawInfo(...)` call (add as the last argument):

```python
        best_audio_label=_best_audio_label(best),
        formats_summary=_formats_summary(best),
        chapters=info.get("chapters") or [],
    )
```

- [ ] **Step 4: Create `app/core/tracklist.py`**

```python
from __future__ import annotations

import re
from typing import Optional

from ..models import Track, Tracklist
from .resolver import RawInfo

# Future tracklist sources (deferred): 1001tracklists scraping (Cloudflare-gated)
# and audio fingerprinting (AudD/Panako) would each add another parse_*() producer
# returning list[Track]; build_tracklist() would consult them after description.

_LEADING_INDEX = re.compile(r"^\s*\d{1,3}[.)]\s+")
_LEADING_TS = re.compile(r"^\s*\[?(\d{1,2}:\d{2}(?::\d{2})?)\]?\s*[-–—)]?\s*")
_TRAILING_TS = re.compile(r"[\[(]?(\d{1,2}:\d{2}(?::\d{2})?)[\])]?\s*$")


def _to_seconds(ts: str) -> float:
    parts = [int(p) for p in ts.split(":")]
    if len(parts) == 3:
        h, m, s = parts
    else:
        h, m, s = 0, parts[0], parts[1]
    return float(h * 3600 + m * 60 + s)


def _split_label(label: str) -> tuple[str, str]:
    """Split 'Artist - Title' into (artist, title); plain text → ('', title)."""
    label = label.strip(" -–—|·:\t")
    if " - " in label:
        left, _, right = label.partition(" - ")
        return left.strip(), right.strip()
    return "", label.strip()


def parse_chapters(chapters: list[dict]) -> list[Track]:
    tracks: list[Track] = []
    for ch in chapters or []:
        start = ch.get("start_time")
        if start is None:
            continue
        artist, title = _split_label((ch.get("title") or "").strip())
        tracks.append(Track(start=float(start), title=title, artist=artist))
    return tracks


def parse_description(description: str) -> list[Track]:
    tracks: list[Track] = []
    for line in (description or "").splitlines():
        m = _LEADING_TS.match(line)
        if m:
            rest = line[m.end():]
        else:
            stripped = _LEADING_INDEX.sub("", line)
            m = _LEADING_TS.match(stripped)
            if not m:
                continue
            rest = stripped[m.end():]
        artist, title = _split_label(rest)
        if not title and not artist:
            continue
        tracks.append(Track(start=_to_seconds(m.group(1)), title=title, artist=artist))
    return tracks


def parse_manual(text: str) -> list[Track]:
    tracks: list[Track] = []
    for line in (text or "").splitlines():
        body = _LEADING_INDEX.sub("", line.strip())
        if not body:
            continue
        start: Optional[float] = None
        ml = _LEADING_TS.match(body)
        mt = _TRAILING_TS.search(body)
        if ml:
            start = _to_seconds(ml.group(1))
            body = body[ml.end():].strip()
        elif mt:
            start = _to_seconds(mt.group(1))
            body = body[: mt.start()].strip()
        artist, title = _split_label(body)
        if not title and not artist:
            continue
        tracks.append(Track(start=start, title=title, artist=artist))
    return tracks


def normalize(tracks: list[Track], total_duration: Optional[float] = None) -> list[Track]:
    """Sort by start (when all present), dedupe, drop rows past the file end.

    When some starts are missing (manual paste), preserve input order and only
    drop exact-duplicate label rows.
    """
    cleaned = [t for t in tracks if (t.title or t.artist or t.start is not None)]
    if cleaned and all(t.start is not None for t in cleaned):
        ordered = sorted(cleaned, key=lambda t: t.start)
        out: list[Track] = []
        seen: set[float] = set()
        for t in ordered:
            key = round(float(t.start), 2)
            if key in seen:
                continue
            if total_duration and t.start >= total_duration:
                continue
            seen.add(key)
            out.append(t)
        return out
    out2: list[Track] = []
    seen2: set = set()
    for t in cleaned:
        key = (t.start, t.title.strip().lower(), t.artist.strip().lower())
        if key in seen2:
            continue
        seen2.add(key)
        out2.append(t)
    return out2


def build_tracklist(raw: RawInfo) -> Tracklist:
    """Best available auto tracklist: chapters → description timestamps → empty."""
    chapter_tracks = parse_chapters(raw.chapters)
    if chapter_tracks:
        return Tracklist(source="chapters", tracks=normalize(chapter_tracks, raw.duration or None))
    desc_tracks = parse_description(raw.description)
    if desc_tracks:
        return Tracklist(source="description", tracks=normalize(desc_tracks, raw.duration or None))
    return Tracklist(source="none", tracks=[])


def parse_manual_tracklist(text: str, total_duration: Optional[float] = None) -> Tracklist:
    return Tracklist(source="manual", tracks=normalize(parse_manual(text), total_duration))
```

- [ ] **Step 5: Run test to verify it passes**

Run: `pytest tests/test_tracklist.py -q`
Expected: PASS — `11 passed`.

- [ ] **Step 6: Run the resolver + metadata tests (regression for the `RawInfo` change)**

Run: `pytest tests/test_resolver.py tests/test_metadata.py -q`
Expected: PASS — unchanged (the new `chapters` field has a default).

- [ ] **Step 7: Commit**

```bash
git add app/core/resolver.py app/core/tracklist.py tests/test_tracklist.py
git commit -m "feat: parse tracklists from chapters/description/manual paste"
```

---

## Task 4: Lossless splitter (TDD with synthetic audio)

**Files:**
- Create: `app/core/splitter.py`
- Test: `tests/test_splitter.py`

- [ ] **Step 1: Write the failing test `tests/test_splitter.py`**

```python
import shutil
import subprocess
from pathlib import Path

import pytest
from mutagen.mp4 import MP4

from app.core.splitter import compute_end_times, split_file
from app.models import Track


def _has_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


@pytest.fixture
def long_m4a(tmp_path) -> Path:
    """A 6-second AAC .m4a built with ffmpeg; skips if ffmpeg is unavailable."""
    if not _has_ffmpeg():
        pytest.skip("ffmpeg not installed")
    out = tmp_path / "full.m4a"
    subprocess.run(
        [
            "ffmpeg", "-y", "-f", "lavfi",
            "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
            "-t", "6", "-c:a", "aac", "-b:a", "96k", str(out),
        ],
        check=True, capture_output=True,
    )
    return out


def test_compute_end_times_fills_gaps():
    tracks = [Track(start=0, title="A"), Track(start=2, title="B"), Track(start=4, title="C")]
    out = compute_end_times(tracks, 6.0)
    assert [t.end for t in out] == [2.0, 4.0, 6.0]


def test_compute_end_times_sorts_first():
    tracks = [Track(start=4, title="C"), Track(start=0, title="A"), Track(start=2, title="B")]
    out = compute_end_times(tracks, 6.0)
    assert [t.start for t in out] == [0, 2, 4]
    assert [t.end for t in out] == [2.0, 4.0, 6.0]


def test_split_file_creates_ordered_segments(long_m4a, tmp_path):
    tracks = [Track(start=0, title="A"), Track(start=2, title="B"), Track(start=4, title="C")]
    out_dir = tmp_path / "cuts"
    files = split_file(long_m4a, tracks, out_dir, total_duration=6.0)
    assert [f.name for f in files] == ["01 - A.m4a", "02 - B.m4a", "03 - C.m4a"]
    for f in files:
        assert f.exists()
        dur = MP4(str(f)).info.length
        assert 1.5 < dur < 2.6  # ~2s each (stream-copy boundaries snap to packets)


def test_split_file_probes_duration_when_missing(long_m4a, tmp_path):
    tracks = [Track(start=0, title="A"), Track(start=3, title="B")]
    files = split_file(long_m4a, tracks, tmp_path / "cuts")
    assert len(files) == 2
    assert 2.6 < MP4(str(files[1])).info.length < 3.4  # last = file end (~6s) - 3s ≈ 3s


def test_split_file_rejects_missing_start(long_m4a, tmp_path):
    tracks = [Track(start=0, title="A"), Track(start=None, title="B")]
    with pytest.raises(ValueError):
        split_file(long_m4a, tracks, tmp_path / "cuts", total_duration=6.0)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_splitter.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.core.splitter'`.

- [ ] **Step 3: Create `app/core/splitter.py`**

```python
from __future__ import annotations

import subprocess
from pathlib import Path
from typing import Callable, Optional

from mutagen.mp4 import MP4

from ..models import Track
from . import library


def _probe_duration(path: Path | str) -> float:
    return float(MP4(str(path)).info.length)


def compute_end_times(tracks: list[Track], total_duration: float) -> list[Track]:
    """Return tracks sorted by start with `end` filled: end = next start;
    the last track's end is the file end (total_duration)."""
    ordered = sorted(tracks, key=lambda t: (t.start if t.start is not None else 0.0))
    result: list[Track] = []
    for i, t in enumerate(ordered):
        end = ordered[i + 1].start if i + 1 < len(ordered) else total_duration
        result.append(t.model_copy(update={"end": float(end)}))
    return result


def _cut(full: Path, start: float, end: float, dest: Path) -> None:
    """Lossless stream-copy cut of [start, end). Both -ss and -to are input
    options (before -i), so -to is an absolute position in the input timeline."""
    cmd = [
        "ffmpeg", "-y",
        "-ss", f"{start:.3f}",
        "-to", f"{end:.3f}",
        "-i", str(full),
        "-c", "copy", "-map", "0:a",
        "-movflags", "+faststart",
        str(dest),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg split failed: {proc.stderr.strip()[-300:]}")


def split_file(
    full: Path | str,
    tracks: list[Track],
    out_dir: Path | str,
    total_duration: Optional[float] = None,
    on_track: Optional[Callable[[int, int, str], None]] = None,
) -> list[Path]:
    """Cut `full` into per-track .m4a files in `out_dir` named 'NN - Title.m4a'.

    `on_track(index, total, title)` (1-based) reports per-track progress.
    Raises ValueError if any track is missing a start time.
    """
    if any(t.start is None for t in tracks):
        raise ValueError("Every track needs a start time before splitting")
    full = Path(full)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    if total_duration is None:
        total_duration = _probe_duration(full)

    timed = compute_end_times(tracks, total_duration)
    files: list[Path] = []
    total = len(timed)
    for i, t in enumerate(timed, start=1):
        dest = out / library.track_filename(i, t.title)
        _cut(full, float(t.start), float(t.end), dest)
        files.append(dest)
        if on_track:
            on_track(i, total, t.title)
    return files
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_splitter.py -q`
Expected: PASS — `5 passed` (or skips for the ffmpeg-dependent ones if ffmpeg is missing; it is installed here).

- [ ] **Step 5: Commit**

```bash
git add app/core/splitter.py tests/test_splitter.py
git commit -m "feat: add lossless splitter (ffmpeg stream-copy by tracklist)"
```

---

## Task 5: Gapless album tagging (TDD)

**Files:**
- Modify: `app/core/tagger.py`
- Test: `tests/test_tagger_album.py`

- [ ] **Step 1: Write the failing test `tests/test_tagger_album.py`**

```python
import shutil
import subprocess
from pathlib import Path

import pytest
from mutagen.mp4 import MP4

from app.core.tagger import tag_album
from app.models import MetadataFields, Track


def _has_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


@pytest.fixture
def three_m4a(tmp_path) -> list[Path]:
    if not _has_ffmpeg():
        pytest.skip("ffmpeg not installed")
    files = []
    for i in range(3):
        out = tmp_path / f"{i}.m4a"
        subprocess.run(
            [
                "ffmpeg", "-y", "-f", "lavfi",
                "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
                "-t", "1", "-c:a", "aac", "-b:a", "64k", str(out),
            ],
            check=True, capture_output=True,
        )
        files.append(out)
    return files


def test_tag_album_various_artists_sets_compilation(three_m4a):
    tracks = [
        Track(start=0, title="One", artist="A"),
        Track(start=10, title="Two", artist="B"),
        Track(start=20, title="Three", artist="A"),
    ]
    album = MetadataFields(album="Live Set", album_artist="DJ X", year=2025,
                           genre="Electronic", comment="https://youtu.be/x")
    tag_album(three_m4a, tracks, album, cover_jpeg=None)
    for i, f in enumerate(three_m4a, start=1):
        a = MP4(str(f))
        assert a["\xa9alb"] == ["Live Set"]
        assert a["aART"] == ["DJ X"]
        assert a["trkn"][0] == (i, 3)
        assert a["disk"][0] == (1, 1)
        assert a["pgap"] is True
        assert a["cpil"] is True  # track artists differ → various-artists set
        assert a["\xa9cmt"] == ["https://youtu.be/x"]
    first = MP4(str(three_m4a[0]))
    assert first["\xa9nam"] == ["One"]
    assert first["\xa9ART"] == ["A"]


def test_tag_album_single_artist_not_compilation(three_m4a):
    tracks = [Track(start=0, title="One", artist="A"),
              Track(start=10, title="Two", artist="A"),
              Track(start=20, title="Three", artist="A")]
    album = MetadataFields(album="Live Set", album_artist="A")
    tag_album(three_m4a, tracks, album)
    for f in three_m4a:
        assert MP4(str(f))["cpil"] is False


def test_tag_album_track_artist_falls_back_to_album_artist(three_m4a):
    tracks = [Track(start=0, title="One"), Track(start=10, title="Two"), Track(start=20, title="Three")]
    album = MetadataFields(album="Live Set", album_artist="DJ X")
    tag_album(three_m4a, tracks, album)
    for f in three_m4a:
        assert MP4(str(f))["\xa9ART"] == ["DJ X"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pytest tests/test_tagger_album.py -q`
Expected: FAIL — `ImportError: cannot import name 'tag_album'`.

- [ ] **Step 3: Add `tag_album()` to `app/core/tagger.py`**

Add the `Track` import and the new function (append to the file; keep `write_tags` unchanged). Update the import line at the top:

```python
from ..models import MetadataFields, Track
```

Append:

```python
def tag_album(
    files: list[Path],
    tracks: list[Track],
    album_meta: MetadataFields,
    cover_jpeg: bytes | None = None,
) -> None:
    """Tag a set of cut files as ONE cohesive gapless album.

    Shared across tracks: ©alb (album), aART (album artist), ©day, ©gen, ©cmt,
    covr, disk=(1,1), pgap=1. Per track: ©nam (title), ©ART (track artist,
    falling back to album artist), sequential trkn=(n, total). cpil=1 when the
    track artists differ (various-artists set) or album_meta.compilation is set.
    """
    total = len(files)
    distinct_artists = {(t.artist or "").strip() for t in tracks if (t.artist or "").strip()}
    various = len(distinct_artists) > 1
    for i, (path, track) in enumerate(zip(files, tracks), start=1):
        per_track = album_meta.model_copy(update={
            "title": track.title or album_meta.title or f"Track {i}",
            "artist": track.artist or album_meta.album_artist or album_meta.artist,
            "compilation": various or album_meta.compilation,
        })
        write_tags(path, per_track, cover_jpeg, track=(i, total), disc=(1, 1))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pytest tests/test_tagger_album.py -q`
Expected: PASS — `3 passed`.

- [ ] **Step 5: Commit**

```bash
git add app/core/tagger.py tests/test_tagger_album.py
git commit -m "feat: tag split tracks as one cohesive gapless album"
```

---

## Task 6: Routes — `/resolve` tracklist, `/parse-tracklist`, `/download-split` (TDD)

**Files:**
- Modify: `app/main.py`
- Test: `tests/test_api.py`

- [ ] **Step 1: Add the failing API tests to `tests/test_api.py`**

Append these tests (keep the existing ones). Update the top import to add models:

```python
from app.models import SplitDownloadRequest, MetadataFields, Track
```

Append:

```python
def test_parse_tracklist_returns_manual_source(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.post("/parse-tracklist", json={"text": "0:00 A - One\n2:00 B - Two", "duration": 3600})
    assert resp.status_code == 200
    data = resp.json()
    assert data["source"] == "manual"
    assert [t["start"] for t in data["tracks"]] == [0.0, 120.0]
    assert data["tracks"][0]["artist"] == "A" and data["tracks"][0]["title"] == "One"


def test_parse_tracklist_empty_text(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.post("/parse-tracklist", json={"text": "", "duration": 0})
    assert resp.status_code == 200
    assert resp.json()["tracks"] == []


def test_download_split_rejects_empty_tracks(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.post("/download-split", json={
        "video_id": "abc", "url": "https://x",
        "metadata": MetadataFields().model_dump(), "tracks": [],
    })
    assert resp.status_code == 400


def test_download_split_accepts_tracks_returns_job(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.post("/download-split", json={
        "video_id": "abc", "url": "https://x",
        "metadata": MetadataFields(album="Set", album_artist="DJ").model_dump(),
        "tracks": [Track(start=0.0, title="A").model_dump()],
    })
    assert resp.status_code == 200
    assert "job_id" in resp.json()
```

(The accepted-job test enqueues a job; with no network the worker will emit an `error` event off-thread, which is harmless to the assertion. The job_id is returned synchronously.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `pytest tests/test_api.py -q`
Expected: FAIL — 404s for `/parse-tracklist` and `/download-split` (routes don't exist yet).

- [ ] **Step 3: Wire the new routes + split processing in `app/main.py`**

3a. Update the core import to include the new modules:

```python
from .core import downloader, library, metadata_ai, resolver, splitter, tagger, tracklist
```

3b. Update the models import:

```python
from .models import (
    DownloadRequest,
    ProgressEvent,
    ResolveRequest,
    ResolveResponse,
    SplitDownloadRequest,
    Tracklist,
)
```

3c. In `JobManager._run`, dispatch split jobs. Replace the body of `_run` with:

```python
    def _run(self) -> None:
        while True:
            job_id, req = self.work.get()
            try:
                if isinstance(req, SplitDownloadRequest):
                    self._process_split(job_id, req)
                else:
                    self._process(job_id, req)
            except Exception as exc:  # surface any pipeline failure to the UI
                self._emit(job_id, ProgressEvent(stage="error", pct=0.0, message=resolver.augment_error(exc)))
```

3d. Update the `submit` type hint (accept either request) — change its signature line:

```python
    def submit(self, req: "DownloadRequest | SplitDownloadRequest") -> str:
```

3e. Add `_process_split` immediately after `_process` (inside `JobManager`):

```python
    def _process_split(self, job_id: str, req: SplitDownloadRequest) -> None:
        with tempfile.TemporaryDirectory(prefix="setlist-") as tmp:
            tmpdir = Path(tmp)

            self._emit(job_id, ProgressEvent(stage="download", pct=0.0, message="Starting download"))
            src = downloader.download_audio(
                req.url,
                tmpdir,
                lambda pct: self._emit(job_id, ProgressEvent(stage="download", pct=pct, message="Downloading full set")),
                self.cfg.pot_provider_url,
            )

            target = "ALAC (lossless)" if req.format == "alac" else "AAC 256 kbps"
            self._emit(job_id, ProgressEvent(stage="encode", pct=0.0, message=f"Encoding full set to {target}"))
            full = tmpdir / "full.m4a"
            downloader.encode(src, full, req.format)
            self._emit(job_id, ProgressEvent(stage="encode", pct=100.0, message="Encoded"))

            if req.cover == "keep":
                cover = resolver.read_cached_cover(req.video_id)
            else:
                try:
                    cover = resolver.to_square_jpeg(resolver.data_uri_to_bytes(req.cover))
                except Exception:
                    cover = None

            tracks = tracklist.normalize(req.tracks)
            if not tracks:
                raise RuntimeError("No valid tracks to split")
            if any(t.start is None for t in tracks):
                raise RuntimeError("Some tracks are missing start times; fill them in before splitting")

            total = len(tracks)
            self._emit(job_id, ProgressEvent(stage="split", pct=0.0, message=f"Splitting into {total} tracks"))
            cut_dir = tmpdir / "cuts"

            def on_track(i: int, n: int, title: str) -> None:
                self._emit(job_id, ProgressEvent(stage="split", pct=i / n * 100.0, message=f"Cut {i}/{n}: {title or 'Untitled'}"))

            files = splitter.split_file(full, tracks, cut_dir, on_track=on_track)

            self._emit(job_id, ProgressEvent(stage="tag", pct=0.0, message="Tagging album"))
            tagger.tag_album(files, tracks, req.metadata, cover)
            self._emit(job_id, ProgressEvent(stage="tag", pct=100.0, message="Tagged"))

            set_dir = library.set_output_dir(
                self.cfg.output_dir,
                req.metadata.album_artist,
                req.metadata.artist,
                req.metadata.album,
                req.metadata.title,
            )
            library.ensure_output_dir(set_dir)
            for f in files:
                library.save(f, set_dir / f.name)
            library.write_cover(set_dir, cover)
            library.record_recent(self.cfg.output_dir, {
                "path": str(set_dir),
                "title": req.metadata.album or req.metadata.title,
                "artist": req.metadata.album_artist or req.metadata.artist,
                "album": req.metadata.album,
            })
            self._emit(job_id, ProgressEvent(stage="done", pct=100.0, message=f"Saved {total} tracks", file_path=str(set_dir)))
```

3f. In `resolve_endpoint`, build and attach the tracklist. Replace the `return ResolveResponse(...)` block with:

```python
    tl = tracklist.build_tracklist(raw)
    return ResolveResponse(
        video_id=raw.video_id,
        duration=raw.duration,
        metadata=meta,
        cover=cover_uri,
        formats=raw.formats_summary,
        detected_line=line,
        has_chapters=raw.has_chapters,
        tracklist=tl,
    )
```

3g. Add the two new endpoints (place after `download_endpoint`). Also add the `ParseTracklistRequest` model near `RevealRequest`:

```python
class ParseTracklistRequest(BaseModel):
    text: str
    duration: int = 0


@app.post("/parse-tracklist", response_model=Tracklist)
def parse_tracklist_endpoint(req: ParseTracklistRequest) -> Tracklist:
    return tracklist.parse_manual_tracklist(req.text, req.duration or None)


@app.post("/download-split")
def download_split_endpoint(req: SplitDownloadRequest) -> dict:
    if not req.tracks:
        raise HTTPException(status_code=400, detail="No tracks provided")
    job_id = jobs.submit(req)
    return {"job_id": job_id}
```

- [ ] **Step 4: Run the API tests to verify they pass**

Run: `pytest tests/test_api.py -q`
Expected: PASS — existing 3 + new 4 = `7 passed`.

- [ ] **Step 5: Run the full suite**

Run: `pytest -q`
Expected: PASS — all green; only the network smoke test skipped.

- [ ] **Step 6: Commit**

```bash
git add app/main.py tests/test_api.py
git commit -m "feat: add tracklist to resolve, parse-tracklist, and download-split routes"
```

---

## Task 7: Web UI — activate split toggle + editable tracklist

**Files:**
- Modify: `web/index.html`
- Modify: `web/styles.css`
- Modify: `web/app.js`

- [ ] **Step 1: Replace `web/index.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>__APP_NAME__</title>
  <link rel="stylesheet" href="/static/styles.css" />
</head>
<body>
  <main class="container">
    <h1>__APP_NAME__</h1>
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
          <label class="check"><input id="split" type="checkbox" /> Split into separate tracks</label>
        </div>
      </div>

      <section id="tracklist" class="tracklist hidden">
        <div class="tl-head">
          <h3>Tracklist <span id="tlSource" class="tl-source"></span></h3>
          <button id="addTrackBtn" class="ghost" type="button">+ Add track</button>
        </div>
        <div id="trackRows" class="track-rows"></div>
        <details class="paste">
          <summary>Paste a tracklist (e.g. from 1001tracklists)</summary>
          <textarea id="pasteBox" rows="5" placeholder="1. Artist - Title [12:34]&#10;Artist - Title&#10;1:02:33 Title"></textarea>
          <button id="parseBtn" class="ghost" type="button">Parse pasted tracklist</button>
          <p class="hint">Recognizes <code>N. Artist - Title [time]</code>, <code>Artist - Title</code>, and <code>time Title</code>. Missing times can be filled in above.</p>
        </details>
      </section>

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

- [ ] **Step 2: Append tracklist styles to `web/styles.css`**

Append at the end:

```css
.tracklist { margin-top: 16px; border-top: 1px solid var(--line); padding-top: 14px; }
.tl-head { display: flex; align-items: center; justify-content: space-between; }
.tl-head h3 { font-size: 14px; margin: 0; }
.tl-source { color: var(--muted); font-size: 12px; font-weight: 400; margin-left: 6px; }
.track-rows { display: flex; flex-direction: column; gap: 6px; margin: 10px 0; }
.track-row { display: grid; grid-template-columns: 72px 1fr 1fr auto; gap: 6px; align-items: center; }
.track-row input { padding: 7px 8px; font-size: 13px; }
.track-row .start { text-align: center; }
.row-btns { display: flex; gap: 2px; }
.row-btns button { padding: 4px 8px; font-size: 12px; line-height: 1; }
.paste { margin-top: 8px; }
.paste summary { color: var(--muted); font-size: 13px; cursor: pointer; }
.paste textarea { width: 100%; margin-top: 8px; padding: 10px 12px; background: #11141a; border: 1px solid var(--line); border-radius: 8px; color: var(--text); font: 13px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; resize: vertical; }
.paste .hint { color: var(--muted); font-size: 12px; margin: 6px 0 0; }
.paste code { background: #11141a; padding: 1px 5px; border-radius: 4px; font-size: 11px; }
```

- [ ] **Step 3: Replace `web/app.js`**

```javascript
const $ = (id) => document.getElementById(id);
const state = { videoId: "", url: "", detectedAlac: "", duration: 0 };
const tl = { source: "none", tracks: [] };

function secondsToClock(s) {
  if (s == null || s === "" || isNaN(s)) return "";
  s = Math.max(0, Math.round(s));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  const pad = (n) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(sec)}` : `${m}:${pad(sec)}`;
}

function clockToSeconds(str) {
  const t = (str || "").trim();
  if (!t) return null;
  const parts = t.split(":").map((p) => parseInt(p, 10));
  if (parts.some((n) => isNaN(n))) return null;
  let h = 0, m = 0, s = 0;
  if (parts.length === 3) [h, m, s] = parts;
  else if (parts.length === 2) [m, s] = parts;
  else [s] = parts;
  return h * 3600 + m * 60 + s;
}

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
    state.duration = data.duration || 0;
    $("cover").src = data.cover || "";
    $("title").value = data.metadata.title || "";
    $("artist").value = data.metadata.artist || "";
    $("album").value = data.metadata.album || "";
    $("albumArtist").value = data.metadata.album_artist || "";
    $("year").value = data.metadata.year ?? "";
    $("genre").value = data.metadata.genre || "";
    $("compilation").checked = !!data.metadata.compilation;
    setTracklist(data.tracklist || { source: "none", tracks: [] });
    updateDetected();
    updateSplitVisibility();
    show("preview");
    setStatus("");
  } catch (err) {
    setStatus("Error: " + err.message, true);
  } finally {
    $("resolveBtn").disabled = false;
  }
}

function setTracklist(data) {
  tl.source = data.source || "none";
  tl.tracks = (data.tracks || []).map((t) => ({
    start: t.start ?? null,
    title: t.title || "",
    artist: t.artist || "",
  }));
  renderTracklist();
}

function renderTracklist() {
  const sourceLabel = {
    chapters: "from YouTube chapters",
    description: "from description timestamps",
    manual: "from pasted text",
    none: "none found — add or paste below",
  }[tl.source] || "";
  $("tlSource").textContent = sourceLabel ? `(${sourceLabel})` : "";
  const rows = $("trackRows");
  rows.innerHTML = "";
  tl.tracks.forEach((t, i) => {
    const row = document.createElement("div");
    row.className = "track-row";

    const start = document.createElement("input");
    start.className = "start";
    start.value = secondsToClock(t.start);
    start.placeholder = "0:00";
    start.addEventListener("change", () => { t.start = clockToSeconds(start.value); });

    const title = document.createElement("input");
    title.value = t.title;
    title.placeholder = "Title";
    title.addEventListener("change", () => { t.title = title.value; });

    const artist = document.createElement("input");
    artist.value = t.artist;
    artist.placeholder = "Artist";
    artist.addEventListener("change", () => { t.artist = artist.value; });

    const btns = document.createElement("div");
    btns.className = "row-btns";
    btns.appendChild(iconBtn("↑", () => moveTrack(i, -1)));
    btns.appendChild(iconBtn("↓", () => moveTrack(i, 1)));
    btns.appendChild(iconBtn("✕", () => removeTrack(i)));

    row.append(start, title, artist, btns);
    rows.appendChild(row);
  });
}

function iconBtn(label, onClick) {
  const b = document.createElement("button");
  b.type = "button";
  b.className = "ghost";
  b.textContent = label;
  b.addEventListener("click", onClick);
  return b;
}

function readRowsFromDOM() {
  // Inputs already write back on change; this is a safety re-sync before submit.
  const rows = $("trackRows").querySelectorAll(".track-row");
  rows.forEach((row, i) => {
    const [start, title, artist] = row.querySelectorAll("input");
    tl.tracks[i].start = clockToSeconds(start.value);
    tl.tracks[i].title = title.value;
    tl.tracks[i].artist = artist.value;
  });
}

function addTrack() {
  readRowsFromDOM();
  tl.tracks.push({ start: null, title: "", artist: "" });
  renderTracklist();
}

function removeTrack(i) {
  readRowsFromDOM();
  tl.tracks.splice(i, 1);
  renderTracklist();
}

function moveTrack(i, dir) {
  readRowsFromDOM();
  const j = i + dir;
  if (j < 0 || j >= tl.tracks.length) return;
  [tl.tracks[i], tl.tracks[j]] = [tl.tracks[j], tl.tracks[i]];
  renderTracklist();
}

async function parsePasted() {
  const text = $("pasteBox").value;
  if (!text.trim()) return;
  try {
    const res = await fetch("/parse-tracklist", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text, duration: state.duration }),
    });
    if (!res.ok) throw new Error("Parse failed");
    setTracklist(await res.json());
  } catch (err) {
    setStatus("Error: " + err.message, true);
  }
}

function updateSplitVisibility() {
  $("tracklist").classList.toggle("hidden", !$("split").checked);
  $("downloadBtn").textContent = $("split").checked ? "Download & split" : "Download & tag";
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

function albumMetadata() {
  return {
    title: $("title").value,
    artist: $("artist").value,
    album: $("album").value,
    album_artist: $("albumArtist").value,
    year: $("year").value ? parseInt($("year").value, 10) : null,
    genre: $("genre").value,
    comment: state.url,
    compilation: $("compilation").checked,
  };
}

async function download() {
  if (!state.videoId) return;
  if ($("split").checked) return downloadSplit();
  const body = {
    video_id: state.videoId,
    url: state.url,
    format: $("aac256").checked ? "aac256" : "alac",
    cover: "keep",
    metadata: albumMetadata(),
  };
  startProgress();
  try {
    const res = await fetch("/download", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error("Download request failed");
    const { job_id } = await res.json();
    streamProgress(job_id);
  } catch (err) {
    setStatus("Error: " + err.message, true);
    $("downloadBtn").disabled = false;
  }
}

async function downloadSplit() {
  readRowsFromDOM();
  const tracks = tl.tracks
    .map((t) => ({ start: t.start, title: t.title, artist: t.artist }))
    .filter((t) => t.title || t.artist || t.start != null);
  if (tracks.length === 0) {
    setStatus("Add at least one track to split.", true);
    return;
  }
  if (tracks.some((t) => t.start == null)) {
    setStatus("Every track needs a start time before splitting.", true);
    return;
  }
  const body = {
    video_id: state.videoId,
    url: state.url,
    format: $("aac256").checked ? "aac256" : "alac",
    cover: "keep",
    metadata: albumMetadata(),
    tracks,
  };
  startProgress();
  try {
    const res = await fetch("/download-split", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ detail: res.statusText }));
      throw new Error(err.detail || "Split request failed");
    }
    const { job_id } = await res.json();
    streamProgress(job_id);
  } catch (err) {
    setStatus("Error: " + err.message, true);
    $("downloadBtn").disabled = false;
  }
}

function startProgress() {
  $("downloadBtn").disabled = true;
  $("revealDone").style.display = "none";
  show("progress");
  setBar(0);
  setStatus("");
  $("progressMsg").textContent = "Starting…";
}

function streamProgress(jobId) {
  const es = new EventSource(`/progress/${jobId}`);
  es.onmessage = (e) => {
    const ev = JSON.parse(e.data);
    $("progressMsg").textContent = `${ev.stage}: ${ev.message}`;
    if (["download", "encode", "split", "tag"].includes(ev.stage)) setBar(ev.pct);
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
  $("split").addEventListener("change", updateSplitVisibility);
  $("addTrackBtn").addEventListener("click", addTrack);
  $("parseBtn").addEventListener("click", parsePasted);
  $("url").addEventListener("keydown", (e) => {
    if (e.key === "Enter") resolve();
  });
  loadRecent();
});
```

- [ ] **Step 4: Verify the UI serves and is wired (no port 8765; the dev server there must stay up)**

Run (uses an alternate port to avoid the running dev server on 8765):

```bash
source .venv/bin/activate && YT_DLP_SELF_UPDATE=0 uvicorn app.main:app --host 127.0.0.1 --port 8799 & SERVER_PID=$!; sleep 3; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8799/; curl -s http://127.0.0.1:8799/ | grep -c 'id="split"'; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8799/static/app.js; kill $SERVER_PID
```

Expected: `200`, then `1` (the split toggle is present and has an id), then `200`. Server is stopped afterward.

- [ ] **Step 5: Commit**

```bash
git add web/index.html web/styles.css web/app.js
git commit -m "feat: activate split toggle with editable tracklist editor + manual paste"
```

---

## Task 8: README, full verification, push

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update `README.md`**

Replace the `OUTPUT_DIR` row in the configuration table:

```markdown
| `OUTPUT_DIR` | `~/Music/Music/Media/Music` | Apple Music media folder; created on first run |
```

Replace the entire "## Out of scope (v2)" section at the end with:

````markdown
## Output layout

Files are organized as `OUTPUT_DIR/<Artist>/<Set>/…`:

- **Artist** = Album Artist (falls back to Artist).
- **Set** = Album (falls back to Title).
- Single track → `<Set>/<Title>.m4a`.
- Split album → `<Set>/01 - Track.m4a`, `02 - …`.
- Each set folder also gets a standalone `cover.jpg` (the same square cover embedded in the audio) for setting Apple Music *playlist* artwork.

## Splitting sets into tracks (v2)

Toggle **Split into separate tracks** in the preview to cut a long mix/DJ set into a
cohesive **gapless album**:

1. Resolve a URL. If it has YouTube **chapters** or **description timestamps**, an
   editable tracklist is proposed automatically (chapters preferred).
2. Edit start times (`m:ss` / `h:mm:ss`), titles, and artists; add/remove/reorder rows.
   You can also **paste** a tracklist (e.g. from 1001tracklists) — formats
   `N. Artist - Title [time]`, `Artist - Title`, and `time Title` are recognized; fill
   in any missing times.
3. **Download & split** downloads + encodes the set once, cuts each track **losslessly**
   (`ffmpeg -c copy`, no re-encode), and tags them as one album: shared Album/Album Artist,
   sequential track numbers, `pgap=1` (gapless), and `cpil=1` when track artists differ.

Output goes to `OUTPUT_DIR/<Album Artist>/<Album>/NN - Track.m4a` with a shared `cover.jpg`.

### Future tracklist sources (not yet built)

The tracklist layer (`app/core/tracklist.py`) is source-agnostic. Two sources are
deferred behind the same `Track`/`Tracklist` interface and can be added later as extra
parsers: **1001tracklists scraping** (Cloudflare-Turnstile-gated, no official API) and
**audio fingerprinting** (AudD / Panako).
````

- [ ] **Step 2: Run the full test suite**

Run: `pytest -q`
Expected: PASS — all unit tests pass (the lossless splitter + album tagging tests exercise ffmpeg, which is installed); only `tests/test_smoke.py` is skipped. No failures.

- [ ] **Step 3: Confirm `.env` is not staged and the tree is clean**

Run: `git status --porcelain && git status` 
Expected: README is the only change to commit at this step; `.env` must NOT appear anywhere in the output (it is gitignored).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document <Artist>/<Set>/ layout and v2 track splitting"
```

- [ ] **Step 5: Push to origin/main**

Run: `git push origin main`
Expected: push succeeds; `git status` shows the branch up to date with `origin/main`.

---

## Final verification checklist (run after Task 8)

- [ ] `pytest -q` → all pass, only the network smoke test skipped.
- [ ] `.env` never read/staged; `git status` clean; all task commits pushed to `origin/main`.
- [ ] The dev server on port 8765 (terminal `539269`) was never killed/restarted or bound.
- [ ] Manual: restart `./run.sh`, paste a **chaptered** set URL, toggle **Split into separate tracks** → an editable tracklist appears (source: chapters). **Download & split** streams `download → encode → split → tag → done`, then **Reveal in Finder** opens `OUTPUT_DIR/<Album Artist>/<Album>/` containing `01 - ….m4a`, `02 - …`, and `cover.jpg`.
- [ ] Manual: dragging the set folder into Apple Music imports it as one gapless album with correct grouping, track order, and cover.
- [ ] Manual: with the toggle **OFF**, a normal single-track download still works and lands at `OUTPUT_DIR/<Artist>/<Set>/<Title>.m4a` with `cover.jpg`.

---

## Self-Review

**Spec coverage:**
- Tracklist sources (chapters → description → manual): Task 3 (`parse_chapters`, `parse_description`, `parse_manual`, `build_tracklist`). ✅
- Deferred 1001tracklists scraping + fingerprinting with extension point + Future note: Task 3 module docstring + README. ✅
- Activate toggle + editable tracklist reusing album-level fields: Task 7. ✅
- `tracklist.py` + typed `Tracklist`/`Track` in `models.py`: Tasks 2–3. ✅
- `splitter.py` lossless cut (end = next start, last = file end): Task 4. ✅
- Reuse `tagger.py` for cohesive gapless album (`©alb`/`aART`, `trkn`, `disk`, `pgap`, `cpil` when artists differ, per-track `©nam`/`©ART`, shared `covr`, `©cmt`): Task 5. ✅
- Save into album subfolder: Tasks 1 + 6 (`set_output_dir` → `<Artist>/<Set>/`). ✅
- Extend resolve with proposed tracklist + split download path reusing JobManager + SSE with per-track progress: Task 6. ✅
- v1 single-track flow unchanged when toggle OFF: Task 7 (`download()` branches only when `#split` checked); v1 `_process` untouched except the save-path refinement requested by the user. ✅
- Save-layout refinements (default `~/Music/Music/Media/Music`, `<Artist>/<Set>/`, standalone `cover.jpg`): Tasks 1, 6, 8. ✅
- Tests for parsing, splitter (synthetic audio), album tagging cohesion; network tests skippable; existing suite stays green: Tasks 1–6. ✅

**Type consistency:** `Track(start, title, artist, end)`, `Tracklist(source, tracks)`, `set_output_dir(output_dir, album_artist, artist, album, title)`, `track_filename(index, title)`, `write_cover(set_dir, cover_jpeg)`, `compute_end_times(tracks, total_duration)`, `split_file(full, tracks, out_dir, total_duration=None, on_track=None)`, `tag_album(files, tracks, album_meta, cover_jpeg=None)`, `build_tracklist(raw)`, `parse_manual_tracklist(text, total_duration=None)` are used consistently across tasks and routes. `RawInfo.chapters` added (Task 3) is consumed by `build_tracklist`. `ProgressEvent.stage` gains `"split"` (Task 2), emitted in Task 6 and consumed in Task 7.

**Placeholder scan:** No TBD/placeholder steps; every code step contains complete code and exact test commands.
