# Hosted site + local helper + n8n orchestration

The Setlist UI is deployed as a static site; the heavy lifting (yt-dlp, ffmpeg,
tagging, saving to `~/Music`) stays on your Mac in a small local **helper** (the
same FastAPI app as always). n8n Cloud sits in the middle as a visible
orchestrator for download jobs.

Live site: **<https://list-setlist.vercel.app>** (Vercel project `setlist`;
`setlist.vercel.app` and `setlist-app.vercel.app` were already taken globally,
so the public domain is `list-setlist.vercel.app` — `setlist-dusky.vercel.app`
and `setlist-jandesign.vercel.app` are auto-assigned equivalents).

## Request flow

```
Browser (https://list-setlist.vercel.app, on the Mac running the helper)
 ├─ resolve / auto-tracklist / recents / SSE progress
 │    → DIRECT to http://127.0.0.1:8765 (fast; CORS-allowed; no token needed —
 │      loopback requests without X-Forwarded-For are auth-exempt)
 │
 └─ Download click (metadata + tracklist already reviewed in the UI = the
    human-in-the-loop; no n8n form needed)
      → POST n8n webhook /setlist-submit  (X-N8N-Auth header)
          → n8n validates token → builds job → calls the helper through the
            Tailscale Funnel URL (/download or /download-split, Bearer token,
            callback_url = n8n's wait-webhook resume URL)
          → n8n replies { status:"started", job_id, execution_id }
      → the site opens the helper's LOCAL SSE stream /progress/{job_id}
        for the live bar (SSE terminal event is the UI's source of truth;
        the n8n execution log is the audit trail)
      → helper finishes → POSTs the completion summary to callback_url
        → n8n resumes → Completion Summary node ends the execution
Files land in ~/Music/YouTube Sets on the Mac.
```

If n8n isn't configured in the site's Settings, the Download click goes
straight to the helper (`direct` mode) — same behavior as the local UI.

## Pieces

| Piece | Where | Notes |
|---|---|---|
| Hosted site | `site/` → Vercel | Plain static files, no build step. `app.js` + `styles.css` are shared verbatim with `web/` (synced by `scripts/build_site.py`, guarded by `tests/test_site.py`). `site.js`/`site.css` add helper detection, Settings, and the n8n submit path. |
| Local helper | `app/` (FastAPI) | Same app as `./run.sh`. New: `GET /health` (public liveness ping) and CORS (below). |
| Helper autostart | `helper/install.sh` | launchd LaunchAgent `com.setlist.helper` — see below. |
| Orchestrator | n8n Cloud workflow `HlTQdjrTUZ3D11aM` | Draft until you paste tokens + publish; see `docs/n8n-integration.md`. |

## Backend config (`.env`)

| Key | Value | Purpose |
|---|---|---|
| `CORS_ORIGINS` | `https://list-setlist.vercel.app,https://setlist-dusky.vercel.app` | Comma-separated browser origins allowed to call the helper cross-origin. Empty = CORS disabled (pure-local behavior, unchanged). |

The CORS layer also answers Chrome's **Private Network Access** preflight
(`Access-Control-Request-Private-Network` → `Access-Control-Allow-Private-Network:
true`), so the public-HTTPS-page → 127.0.0.1 path keeps working as Chrome
tightens enforcement. Auth is untouched: the site's requests arrive at loopback
without `X-Forwarded-For`, so they stay token-exempt like the local UI.

## Site settings (no secrets in the deployed code)

The static site ships zero personal values. Click the gear (or the status pill):

- **Helper URL** — default `http://127.0.0.1:8765`; change if you changed `PORT`.
- **n8n webhook URL + token** — paste once; stored only in that browser's
  `localStorage`. With both set, Download routes via n8n; otherwise direct.
  (This is the deliberate design choice: a webhook token baked into public
  static JS would be readable by anyone, and per-browser storage is exactly
  what a future multi-user "bring your own helper + n8n" model needs.)

## Helper install (single-user; runs at login)

```bash
./helper/install.sh     # venv + LaunchAgent ~/Library/LaunchAgents/com.setlist.helper.plist
./helper/uninstall.sh   # stop + remove
```

- Runs `uvicorn app.main:app` on 127.0.0.1:`$PORT` with the repo as working dir
  (so `.env` loads), `KeepAlive` restarts it if it dies, and logs to
  `~/Library/Logs/setlist-helper.log`.
- The installer refuses to fight an already-running `./run.sh` on the same port
  (override with `SETLIST_INSTALL_FORCE=1` to install without starting now).
- No code-signing/notarization — that's the later multi-user distribution step.

## Browser compatibility

- **Chrome / Edge / Brave (Chromium)**: HTTPS pages may fetch `http://127.0.0.1`
  (loopback is "potentially trustworthy", mixed-content exempt). Chrome's
  Private Network Access adds a special preflight, which the helper answers
  (see above). Newer Chrome may additionally show a one-time **"access devices
  on your local network?"** permission prompt — allow it.
- **Safari**: blocks HTTPS→`http://127.0.0.1` as mixed content. The site detects
  the failed ping on Safari and suggests using Chrome or opening the local UI at
  <http://127.0.0.1:8765> directly.
- Verified in a Chromium browser: helper detection, cross-origin resolve
  against a CORS-enabled helper, and the n8n submit path (mocked webhook).

## Deploying site changes

```bash
.venv/bin/python scripts/build_site.py   # re-sync shared app.js/styles.css
cd site && vercel deploy --prod --yes    # project "setlist" (already linked)
```

Vercel deployment protection is disabled for this project (the site is a public
static page; the helper/n8n hold the actual secrets).
