# Development

Everything that is not needed to *use* Setlist: running from source, the build
pipeline, configuration keys, tests, and how the output is laid out. For install and
usage see the [README](../README.md).

## Layout

- `app/` — Python media engine: FastAPI server (`main.py`), download/encode/split/tag
  pipeline (`core/`), and the web UI (`web/`).
- `macos/` — the native SwiftUI app (Swift 6.2 package). The Swift app launches the
  Python engine as a child process and talks to it over loopback HTTP.
- `scripts/` — `build_macos_app.sh`, `build_dmg.sh`, `make_icon.py`.
- `helper/` — launchd LaunchAgent that runs the engine at login (for the hosted site).
- `tests/` — pytest suite; Swift tests live in `macos/Tests`.

The product name lives in one place — `APP_NAME` in `app/config.py`, mirrored in
`pyproject.toml`. The web UI is rendered from an `__APP_NAME__` placeholder.

## Ways to run it

All end with files in `~/Music` on your Mac:

- **Packaged app** — `./scripts/build_macos_app.sh` builds the same portable
  `dist/Setlist.app` as the release (see [Building the Mac app](#building-the-mac-app)).
- **Source-linked app** — `BUNDLE_ENGINE=0 ./scripts/build_macos_app.sh` builds an app
  that runs `./run.sh` from this checkout and reads `.env`, for fast iteration on the
  Swift side.
- **Web UI** — `./run.sh` → <http://127.0.0.1:8765> (loopback only). Needs
  `brew install ffmpeg`.
- **Hosted site** — <https://list-setlist.vercel.app>: the same web UI served from
  Vercel, talking to the local engine, optionally routing jobs through n8n. See
  [hosted-site.md](hosted-site.md).
- **iPhone share sheet** — an Apple Shortcut posts to n8n, which drives the Mac over a
  Tailscale Funnel with a form-based approval step. See
  [n8n-integration.md](n8n-integration.md).

### Prerequisites (source)

- macOS, Python 3.11+
- **ffmpeg** for `./run.sh` (`brew install ffmpeg`) — the packaged app ships its own
- **AtomicParsley** (optional cover fallback): `brew install atomicparsley`
- Xcode 27 / Swift 6.2 and [`uv`](https://docs.astral.sh/uv/) (`brew install uv`) for
  the Mac app

### Web UI from source

```bash
cp .env.example .env   # then edit .env and add your keys
./run.sh               # creates .venv, installs, opens the browser
```

To run the engine automatically at login instead (the "helper" behind the hosted site):

```bash
./helper/install.sh    # launchd LaunchAgent; logs to ~/Library/Logs/setlist-helper.log
./helper/uninstall.sh  # stop + remove
```

## Building the Mac app

```bash
./scripts/build_macos_app.sh      # → dist/Setlist.app (portable, ~300 MB)
./scripts/build_dmg.sh            # → dist/Setlist-<version>-arm64.dmg (+ .sha256)
```

The portable build bundles a relocatable CPython (via `uv`), the backend and its
dependencies, and static `ffmpeg`/`ffprobe` (pinned, checksummed downloads from
[martin-riedl.de](https://ffmpeg.martin-riedl.de)) under
`Setlist.app/Contents/Resources/engine`, precompiles bytecode, and code-signs every
binary. Nothing inside the bundle is written at run time: user settings live in
`~/Library/Application Support/Setlist/settings.env`, and `yt-dlp` self-updates into
`…/Setlist/packages`, which shadows the bundled copy. The engine log is
`~/Library/Logs/Setlist/backend.log`.

Knobs:

| Variable | Default | Effect |
|----------|---------|--------|
| `CODESIGN_IDENTITY` | `-` (ad-hoc) | `"Developer ID Application: …"` signs with a real identity, enables the hardened runtime, and signs the DMG (then notarize with `xcrun notarytool`) |
| `BUNDLE_ENGINE` | `1` | `0` skips the engine bundle and links the app to this checkout (`./run.sh` + `.env`) |
| `PYTHON_VERSION` | pinned in the script | CPython version fetched through `uv` |
| `FFMPEG_BUILD` / `FFMPEG_DIR` | pinned in the script | Static ffmpeg build to download, or a local directory with `ffmpeg` + `ffprobe` |
| `SKIP_BUILD` (`build_dmg.sh`) | unset | Package the existing `dist/Setlist.app` instead of rebuilding |

### Publishing a release

1. Bump `version` in `pyproject.toml`.
2. `./scripts/build_dmg.sh`.
3. `gh release create v<version> dist/Setlist-<version>-arm64.dmg dist/Setlist-<version>-arm64.dmg.sha256`

The README download button always points at the latest release.

## Configuration (`.env` / `settings.env`)

Source builds read `.env` in the checkout; the packaged app reads
`~/Library/Application Support/Setlist/settings.env` (created on first launch, edited by
the Settings window). Same keys. None is required — Setlist runs with no account or API
key; the ones marked *web UI / API* only matter when the engine serves other clients.

| Key | Default | Notes |
|-----|---------|-------|
| `FIRECRAWL_API_KEY` | — | *Web UI / API.* Lets the browser UI fetch 1001tracklists through Firecrawl; the Mac app renders the page itself |
| `OUTPUT_DIR` | `~/Music/YouTube Sets` | Where finished sets land; created on first run |
| `DEFAULT_FORMAT` | `alac` | UI toggle switches to `aac256` |
| `PORT` | `8765` | Loopback server port |
| `YT_DLP_SELF_UPDATE` | `1` | `0` disables the best-effort `yt-dlp` update on launch |
| `POT_PROVIDER_URL` | empty | Advanced. PO-token provider sidecar for YouTube bot checks |
| `CORS_ORIGINS` | empty | *Web UI / API.* Browser origins allowed to call the API cross-origin (the hosted site); empty disables CORS |
| `API_AUTH_TOKEN` | empty | *Web UI / API.* Bearer token required when the API is exposed through a tunnel ([n8n-integration.md](n8n-integration.md)) |

## Tests

```bash
pip install -e ".[dev]"
pytest -q                                   # unit tests (ffmpeg-dependent ones skip if ffmpeg is missing)
swift test --package-path macos             # native app tests (workflow, API contract, UI state)
RUN_SMOKE=1 pytest tests/test_smoke.py -v   # optional end-to-end network test
```

## How the output is built

Apple Music groups an album by **Album** (`©alb`) + **Album Artist** (`aART`); Setlist
sets a consistent `aART`, sequential `trkn`, and `pgap=1` (gapless) so files import as
one album.

### Output layout

Files are organized as `OUTPUT_DIR/<Artist>/<Set>/…`:

- **Artist** = Album Artist (falls back to Artist).
- **Set** = Album (falls back to Title).
- Single track → `<Set>/<Title> [<video_id>].m4a` (the `[<video_id>]` suffix keeps two
  different source videos with the same Artist/Set/Title from overwriting each other).
- Split album → `<Set>/01 - Track.m4a`, `02 - …`.
- Each set folder also gets a standalone `cover.jpg` (the same square cover embedded in
  the audio) for setting Apple Music *playlist* artwork.

### Splitting a set into tracks

1. Resolve a URL. If it has YouTube **chapters** or **description timestamps**, an
   editable tracklist is proposed automatically (chapters preferred).
2. Otherwise the native app searches 1001tracklists for the set and, if it finds it,
   fills the editor. You can also paste a 1001tracklists URL, or paste a tracklist by
   hand — `N. Artist - Title [time]`, `Artist - Title`, and `time Title` are recognized.
3. Edit start times (`m:ss` / `h:mm:ss`), titles, and artists; add/remove/reorder rows.
4. **Download** downloads + encodes the set once, cuts each track **losslessly**
   (`ffmpeg -c copy`, no re-encode), and tags them as one album: shared Album/Album
   Artist, sequential track numbers, `pgap=1`, and `cpil=1` when track artists differ.

### Tracklist sources

The tracklist layer (`app/core/tracklist.py`) is source-agnostic. Each source is a
`parse_*()` producer returning the same `Track`/`Tracklist` types:

- **YouTube chapters** and **description timestamps** (`tracklist.py`).
- **Manual paste/edit** (`tracklist.py`).
- **1001tracklists**: the native app renders the page in an invisible WebKit view and
  reads the rows straight from the DOM (`TracklistWebFetcher.swift`) — no key needed.
  The web UI path (`tracklist_1001.py`) goes through Firecrawl instead (the site is
  Cloudflare-Turnstile-gated with no official API) and needs `FIRECRAWL_API_KEY`.

Still deferred behind the same interface: **audio fingerprinting** (AudD / Panako).

## Notes

- ALAC is lossless: it adds no quality beyond YouTube's already-lossy source and
  produces files ~5–10× the source size. Use **AAC 256** for smaller files. Output is
  never represented as higher quality than the source.
- If YouTube throws bot checks, set `POT_PROVIDER_URL` to a running PO-token provider
  sidecar.
