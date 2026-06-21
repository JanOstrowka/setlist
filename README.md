# Setlist

A personal, local-only macOS tool: YouTube → Apple Music. Paste a YouTube URL → download
the best audio → transcode losslessly to Apple-Music-compatible **ALAC `.m4a`** (or AAC-256)
→ embed a square JPEG cover + AI-assisted, editable metadata → save a fully tagged file you
drag into Apple Music. Files-only: nothing is auto-imported.

> The product name ("Setlist") lives in a single place — `APP_NAME` in `app/config.py`,
> mirrored here and in `pyproject.toml`. The web UI is rendered from an `__APP_NAME__`
> placeholder, so renaming touches one constant.

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
