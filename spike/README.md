# Modal feasibility spike

One question decides whether the cloud worker gets built: **does YouTube serve
audio to Modal's datacenter egress IPs, or does it bot-block them?** This spike
runs the repo's real engine (`app.core`: resolve → download → 60s ALAC encode →
tag → optional R2 upload) inside a Modal container and prints a per-stage
verdict.

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

# Retry with cookies if the plain run is bot-blocked:
modal run spike/modal_spike.py --url "https://www.youtube.com/watch?v=VIDEO_ID" --use-cookies
```

The first run builds the container image (a couple of minutes); later runs
reuse the cache. To pick up a newer yt-dlp release, prefix with
`MODAL_FORCE_BUILD=1`.

## 4. Reading the verdict

Each stage prints `ok`/`FAIL`, its duration, and a detail line (file sizes,
yt-dlp error text, the container's public egress IP). The bottom line is the
decision:

| Outcome | Meaning | Decision |
|---|---|---|
| `GREEN LIGHT` | Plain yt-dlp works from Modal IPs | Build the cloud worker as planned |
| `WORKS WITH COOKIES` | Only a signed-in session gets through | Build it, with the `youtube-cookies` secret wired into the worker |
| `BLOCKED EVEN WITH COOKIES` | Datacenter IP is hard-blocked | Evaluate a residential proxy or PO-token provider first (the engine already has a `POT_PROVIDER_URL` hook in `app.core.downloader`) |
| `FAILED for a non-bot reason` | Something else broke (bad URL, ffmpeg, R2 creds…) | Read the failing stage's detail; not an IP verdict |

Bot-blocking is detected from yt-dlp's error text ("Sign in to confirm",
403, 429, …) using the same classifier the app uses
(`app.core.resolver.augment_error`).

Run it a few times (and on different days) before trusting a green light —
Modal egress IPs rotate, and YouTube's blocking is probabilistic.

## What this spike deliberately skips

- Full-set transcode (only the first 60s is encoded — enough to prove ffmpeg/ALAC).
- Splitting and callbacks (already proven locally; nothing IP-dependent in them).
- `modal deploy` (this is an ephemeral `modal run` app; productionizing comes
  after a green light).
