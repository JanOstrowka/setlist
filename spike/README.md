# Modal feasibility spike

One question decides whether the cloud worker gets built: **does YouTube serve
audio to Modal's datacenter egress IPs, or does it bot-block them?** This spike
runs the repo's real engine (`app.core`: resolve → download → 60s ALAC encode →
tag → optional R2 upload) inside a Modal container and prints a per-stage
verdict. `--pot` adds a credential-free counter to bot checks: the bgutil
PO-token (proof-of-origin) provider running as an in-container sidecar.

Cost: effectively $0 — one short run uses a few CPU-minutes, well within
Modal's ~$30/month free credits.

## 1. One-time setup

```bash
pip install modal        # in the repo venv: .venv/bin/pip install modal
modal setup              # opens the browser to authenticate
```

Run everything below **from the repo root** (the image bundles the local
`app/` package, which Modal locates via Python imports).

## 2. Optional secrets

Both are optional; the spike detects and attaches them automatically.

**Cloudflare R2** (tests the upload + presigned-link stage):

```bash
modal secret create r2-credentials \
  R2_ACCOUNT_ID=... \
  R2_ACCESS_KEY_ID=... \
  R2_SECRET_ACCESS_KEY=... \
  R2_BUCKET=...
```

**YouTube cookies** (fallback if plain downloads are bot-blocked). Export
cookies.txt with a browser extension such as "Get cookies.txt LOCALLY" —
ideally from a private/incognito window you log in with and then close, so the
session isn't invalidated by normal browsing. Then:

```bash
modal secret create youtube-cookies YOUTUBE_COOKIES_TXT="$(cat /path/to/cookies.txt)"
```

## 3. Run it

```bash
# Canary (default URL is "Me at the zoo", 19s, public):
modal run spike/modal_spike.py

# A real set — use any public music video/set you'd actually download:
modal run spike/modal_spike.py --url "https://www.youtube.com/watch?v=VIDEO_ID"

# Credential-free retry if the plain run is bot-blocked (PO-token provider):
modal run spike/modal_spike.py --url "https://www.youtube.com/watch?v=VIDEO_ID" --pot

# Cookie fallback (needs the youtube-cookies secret):
modal run spike/modal_spike.py --url "https://www.youtube.com/watch?v=VIDEO_ID" --use-cookies
```

The first run builds the container image (a couple of minutes); later runs
reuse the cache. To pick up a newer yt-dlp release, prefix with
`MODAL_FORCE_BUILD=1`.

## 3b. PO-token mode (`--pot`)

`--pot` switches to an image that additionally contains Node.js 22, the
[bgutil PO-token provider](https://github.com/Brainicism/bgutil-ytdlp-pot-provider)
server (cloned and built at tag `1.3.1`), and the matching
`bgutil-ytdlp-pot-provider==1.3.1` pip plugin, which hooks into yt-dlp's
PO Token Provider framework (yt-dlp ≥ 2025.05.22). At function start the spike:

1. launches `node /opt/bgutil-provider/server/build/main.js` as a background
   subprocess (HTTP server on `127.0.0.1:4416`, the plugin's default);
2. polls `GET /ping` for up to 30s and reports a `pot-provider` stage;
3. runs the normal pipeline. On the default port the plugin auto-detects the
   server for **every** yt-dlp call (resolve included). The download stage also
   passes the URL through the engine's `POT_PROVIDER_URL` hook
   (`app.core.downloader.download_audio(pot_provider_url=...)`), which sets the
   `youtubepot-bgutilhttp:base_url` extractor arg — the same wiring the
   production worker would use.

Keep the server clone tag and the pip plugin version in lockstep
(`POT_PROVIDER_VERSION` in `modal_spike.py`); the bgutil README requires
matching versions.

## 4. Reading the verdict

Each stage prints `ok`/`FAIL`, its duration, and a detail line (file sizes,
yt-dlp error text, the container's public egress IP). The bottom line is the
decision:

| Outcome | Meaning | Decision |
|---|---|---|
| `GREEN LIGHT` | Plain yt-dlp works from Modal IPs | Build the cloud worker as planned |
| `GREEN LIGHT (PO TOKENS)` | Credential-free downloads work with the bgutil sidecar | Build it, with Node + provider + plugin baked into the worker image |
| `WORKS WITH COOKIES` | Only a signed-in session gets through | Build it, with the `youtube-cookies` secret wired into the worker |
| `BLOCKED EVEN WITH PO TOKENS` | PO tokens don't rehabilitate the datacenter IP | Residential proxy (~$2–8/mo, yt-dlp `proxy` option) or cookies |
| `BLOCKED EVEN WITH COOKIES` | Datacenter IP is hard-blocked | Evaluate a residential proxy before building |
| `FAILED for a non-bot reason` | Something else broke (bad URL, ffmpeg, R2 creds…) | Read the failing stage's detail; not an IP verdict |

Bot-blocking is detected from yt-dlp's error text ("Sign in to confirm",
403, 429, …) using the same classifier the app uses
(`app.core.resolver.augment_error`).

Run it a few times (and on different days) before trusting a green light —
Modal egress IPs rotate, and YouTube's blocking is probabilistic.

## Results so far

| Date | Mode | URL | Egress IP | Outcome |
|---|---|---|---|---|
| 2026-07 (earlier) | plain | canary | 18.217.59.17 (AWS) | **BOT-BLOCKED** at resolve ("Sign in to confirm you're not a bot") |
| 2026-07-12 | `--pot` | canary (Me at the zoo) | 35.241.153.189 | **all stages ok** — resolve, download, 60s ALAC, tag, R2 upload + presigned URL |
| 2026-07-12 | `--pot` | Fred again.. Boiler Room London (1h+) | 20.151.251.197 | **BOT-BLOCKED** at resolve, same "Sign in to confirm" error |
| 2026-07-12 | `--pot` + `MODAL_FORCE_BUILD=1` | same 1h+ set | 4.227.104.157 | **BOT-BLOCKED** at resolve (yt-dlp 2026.07.04, latest) |

**Verdict: PO tokens work only partially.** The provider starts and yt-dlp
consumes its tokens (the trivial canary passes end-to-end, R2 leg included),
but YouTube still bot-blocks the resolve step for real, high-value videos from
datacenter IPs. PO tokens make traffic look more legitimate; they don't
rehabilitate a flagged IP range (the bgutil README itself warns of this).
For the production worker that means:

1. **Residential/rotating proxy** (~$2–8/mo) — set yt-dlp's `proxy` option (or
   `HTTP(S)_PROXY` env) to `http://user:pass@gateway:port`; keep the PO-token
   sidecar on top, since proxied traffic still benefits from it.
2. **Cookies** (`--use-cookies` + the `youtube-cookies` secret) — works but ties
   downloads to a real account, which the project prefers to avoid.

## What this spike deliberately skips

- Full-set transcode (only the first 60s is encoded — enough to prove ffmpeg/ALAC).
- Splitting and callbacks (already proven locally; nothing IP-dependent in them).
- `modal deploy` (this is an ephemeral `modal run` app; productionizing comes
  after a green light).
