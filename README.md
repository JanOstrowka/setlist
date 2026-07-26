# Setlist

A personal macOS tool: YouTube → Apple Music. Paste a YouTube URL → download
the best audio → transcode losslessly to Apple-Music-compatible **ALAC `.m4a`** (or AAC-256)
→ embed a square JPEG cover + AI-assisted, editable metadata → save a fully tagged file you
drag into Apple Music. Files-only: nothing is auto-imported.

Three ways to use it (all end with files in `~/Music` on your Mac):

- **Local**: `./run.sh` → <http://127.0.0.1:8765> (loopback only, no config needed).
- **Native Mac app** (macOS 26+): `./scripts/build_macos_app.sh`, then open `dist/Setlist.app`.
  A fully native SwiftUI experience over the same local backend: paste-first landing,
  review workspace with a YouTube preview, per-track production progress, and an
  Add to Apple Music finish.
- **Hosted site**: <https://list-setlist.vercel.app> — the same UI served from Vercel,
  talking to the local helper directly, optionally routing jobs through n8n for an
  audit trail. See `docs/hosted-site.md`.
- **iPhone share sheet**: an Apple Shortcut posts to n8n, which drives the Mac over a
  Tailscale Funnel with a form-based approval step. See `docs/n8n-integration.md`.

> The product name ("Setlist") lives in a single place — `APP_NAME` in `app/config.py`,
> mirrored here and in `pyproject.toml`. The web UI is rendered from an `__APP_NAME__`
> placeholder, so renaming touches one constant.

## Prerequisites

- macOS, Python 3.11+
- **ffmpeg** (required): `brew install ffmpeg`
- **AtomicParsley** (optional cover fallback): `brew install atomicparsley`
- Xcode Command Line Tools (only required to build the menu bar app)

## Setup

```bash
cp .env.example .env   # then edit .env and add your keys
./run.sh               # creates .venv, installs, opens the browser
```

`run.sh` starts the server on `http://127.0.0.1:8765` (loopback only) and opens your browser.

### Native Mac app (macOS 26+)

Build and open the native app:

```bash
./scripts/build_macos_app.sh
open dist/Setlist.app
```

The app lives in the menu bar and opens a native SwiftUI window — the Python backend
runs invisibly as the media engine. Highlights:

- **Paste-first landing** with URL validation and a durable **Recent** sidebar
  (SwiftData) that remembers every set: queued, processing, completed, failed,
  cancelled, and interrupted.
- **Review workspace**: native metadata editor, editable tracklist with cue
  validation and drag reordering, and an embedded YouTube preview player that
  seeks to any cue (the only web view in the app, scoped to YouTube).
- **Production scene**: stage rail (Download → Encode → Split → Tag), live overall
  percent with download speed/ETA, and per-track cutting/tagging/ready statuses.
  One set is produced at a time.
- **Completion**: finished tracks flow into your Mac, then an **Add to Apple Music**
  CTA imports them via Music automation (macOS asks for permission the first time);
  Reveal in Finder is one click away. Nothing is imported without your say-so.
- **Safety**: the app attaches only to a server that identifies itself as the
  Setlist engine; quitting during production asks first, cancels the job cleanly,
  and interrupted sets are recovered into Recent on the next launch. Reduce Motion
  swaps animations for crossfades.

The build keeps the Python backend in the source checkout; rebuild the app after
moving the repository. A later distribution build can bundle the backend, ffmpeg,
signing, and notarization into a portable `.app`.

To run it automatically at login instead (the "helper" behind the hosted site):

```bash
./helper/install.sh    # launchd LaunchAgent; logs to ~/Library/Logs/setlist-helper.log
./helper/uninstall.sh  # stop + remove
```

## Configuration (`.env`)

| Key | Default | Notes |
|-----|---------|-------|
| `OPENAI_API_KEY` | — | Required for AI metadata; without it, falls back to title parsing |
| `FIRECRAWL_API_KEY` | — | Optional web enrichment; skipped if unset |
| `OPENAI_MODEL` | `gpt-4o-mini` | Cheap, fast default |
| `OUTPUT_DIR` | `~/Music/YouTube Sets` | Output folder you drag into Apple Music; created on first run |
| `DEFAULT_FORMAT` | `alac` | UI toggle switches to `aac256` |
| `PORT` | `8765` | Loopback server port |
| `POT_PROVIDER_URL` | empty | Optional PO-token provider sidecar for YouTube bot checks |
| `CORS_ORIGINS` | empty | Browser origins allowed to call the API cross-origin (the hosted site); empty disables CORS |
| `API_AUTH_TOKEN` | empty | Bearer token required when the API is exposed through a tunnel (`docs/n8n-integration.md`) |

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
swift test --package-path macos  # native app tests (workflow, API contract, UI state)
RUN_SMOKE=1 pytest tests/test_smoke.py -v   # optional end-to-end network test
```

## Notes

- ALAC is lossless: it adds no quality beyond YouTube's already-lossy source, and produces files
  ~5-10× the source size. Use the **AAC 256** toggle for smaller files. Output is never represented
  as higher quality than the source.
- yt-dlp self-updates best-effort on launch; set `YT_DLP_SELF_UPDATE=0` to disable.
- If YouTube throws bot checks, set `POT_PROVIDER_URL` to a running PO-token provider sidecar.

## Output layout

Files are organized as `OUTPUT_DIR/<Artist>/<Set>/…`:

- **Artist** = Album Artist (falls back to Artist).
- **Set** = Album (falls back to Title).
- Single track → `<Set>/<Title> [<video_id>].m4a` (the `[<video_id>]` suffix keeps two different source videos with the same Artist/Set/Title from overwriting each other).
- Split album → `<Set>/01 - Track.m4a`, `02 - …`.
- Each set folder also gets a standalone `cover.jpg` (the same square cover embedded in the audio) for setting Apple Music *playlist* artwork.

## Splitting sets into tracks (v2)

Toggle **Split into separate tracks** in the preview to cut a long mix/DJ set into a
cohesive **gapless album**:

1. Resolve a URL. If it has YouTube **chapters** or **description timestamps**, an
   editable tracklist is proposed automatically (chapters preferred).
2. Or paste a **1001tracklists URL** in the preview and click **Fetch tracklist**: the
   page is fetched through Firecrawl (it renders JS and bypasses the Cloudflare bot
   wall), and the ordered tracks + cue times fill the editor automatically (the set
   artist/title fill Album Artist/Album). The split toggle flips on for you.
4. Edit start times (`m:ss` / `h:mm:ss`), titles, and artists; add/remove/reorder rows.
   You can also **paste** a tracklist by hand — formats `N. Artist - Title [time]`,
   `Artist - Title`, and `time Title` are recognized; fill in any missing times.
5. **Download & split** downloads + encodes the set once, cuts each track **losslessly**
   (`ffmpeg -c copy`, no re-encode), and tags them as one album: shared Album/Album Artist,
   sequential track numbers, `pgap=1` (gapless), and `cpil=1` when track artists differ.

Output goes to `OUTPUT_DIR/<Album Artist>/<Album>/NN - Track.m4a` with a shared `cover.jpg`.

### Tracklist sources

The tracklist layer (`app/core/tracklist.py`) is source-agnostic. Each source is a
`parse_*()` producer returning the same `Track`/`Tracklist` types:

- **YouTube chapters** and **description timestamps** (`tracklist.py`).
- **Manual paste/edit** (`tracklist.py`).
- **1001tracklists** (`tracklist_1001.py`): paste the tracklist URL and it is fetched via
  Firecrawl (the site is Cloudflare-Turnstile-gated with no official API) and parsed into
  ordered tracks with cue times. Requires `FIRECRAWL_API_KEY`.

Still deferred behind the same interface: **audio fingerprinting** (AudD / Panako).
