# n8n Cloud integration — orchestrated Setlist jobs (hosted site + Apple Shortcut)

One webhook, two entry paths:

```
A) Hosted site (https://list-setlist.vercel.app — see docs/hosted-site.md)
   You review/edit metadata + tracklist IN the site (that's the human-in-the-loop),
   then click Download:
   → POST https://your-instance.app.n8n.cloud/webhook/setlist-submit  (header X-N8N-Auth)
     body: { url, video_id, format, split, metadata, tracks }   ← full approved job
     → n8n validates the token → builds the job → calls the Mac helper through the
       tunnel (/download or /download-split, callback_url = n8n's resume URL)
     → n8n replies { status:"started", job_id, execution_id } — the site attaches to
       the helper's LOCAL SSE stream for the live progress bar
     → helper finishes → callback resumes n8n → Completion Summary (audit trail)

B) iPhone share sheet (Apple Shortcut)
   → POST the same webhook with just { url }
     → n8n calls the Mac app through the tunnel: /resolve + /auto-tracklist
     → n8n replies to the Shortcut with an approval-form link
   → you open the form, review/edit metadata + tracklist, approve
     → n8n starts /download-split (complete tracklist) or /download (otherwise)
     → same callback → Completion Summary
Files land in ~/Music/YouTube Sets on the Mac — nothing needs to be downloaded.
```

The n8n workflow is **"Setlist — YouTube to Apple Music"** (ID `HlTQdjrTUZ3D11aM`,
<https://your-instance.app.n8n.cloud/workflow/<id>>). It is a **draft**;
publish it after the setup below.

---

## 1. Mac app: auth + completion callback (already implemented)

Two features in the FastAPI app support this integration:

- **Bearer-token auth** — when `API_AUTH_TOKEN` is set in `.env`, every API route requires
  `Authorization: Bearer <token>`. Exceptions (no token needed):
  - the UI shell and assets: `/`, `/favicon.ico`, `/static/*`;
  - **direct local requests** (loopback with no `X-Forwarded-For` header), so the browser UI at
    `http://127.0.0.1:8765` keeps working untouched. Tunnels (Tailscale, cloudflared, ngrok)
    always add `X-Forwarded-For`, so tunneled traffic must present the token.
- **Completion callback** — `POST /download` and `POST /download-split` accept an optional
  `callback_url`. When the job finishes (done or error) the worker POSTs:

  ```json
  { "job_id": "…", "status": "done|error", "output_paths": ["…"], "error": "" }
  ```

  Delivery is best-effort (3 attempts, 2 s apart) and never crashes the job. n8n passes its
  Wait-node resume URL here.

Both tokens live in `.env` (gitignored):

| Key | Purpose | Where else it goes |
|---|---|---|
| `API_AUTH_TOKEN` | Protects the Mac app behind the tunnel | n8n Config node → `macApiToken` |
| `N8N_WEBHOOK_TOKEN` | Guards the n8n webhook trigger | n8n Config node → `webhookToken`, Apple Shortcut header |

Restart the app after editing `.env` (`./run.sh`).

---

## 2. Tunnel: Tailscale Funnel (recommended — already installed)

Tailscale is installed on this Mac (`/Applications/Tailscale.app`) and logged in; the machine's
tailnet name is **`your-mac.your-tailnet.ts.net`**. Funnel exposes a single HTTPS port publicly
with a trusted certificate — no extra software, no random URLs that change per run (unlike
cloudflared quick tunnels / free ngrok).

The CLI ships inside the app bundle; add an alias once:

```bash
alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
```

Start the tunnel (persists in the background until reset):

```bash
tailscale funnel --bg 8765
```

This maps **`https://your-mac.your-tailnet.ts.net`** (port 443) → `http://127.0.0.1:8765`,
i.e. the public URL is the Mac app root: `https://your-mac.your-tailnet.ts.net/resolve`, etc.
That hostname is the **`macBaseUrl`** value for the n8n Config node.

- First run may print a link to enable the Funnel node attribute for your tailnet — approve it
  in the admin console once.
- Check: `tailscale funnel status` · Stop: `tailscale funnel reset`
- Anyone on the internet can reach the port, which is why `API_AUTH_TOKEN` is mandatory before
  starting the funnel.

Fallbacks if you ever move off Tailscale (neither is installed today):
`brew install cloudflared && cloudflared tunnel --url http://127.0.0.1:8765` (URL changes every
run — update the Config node each time), or ngrok with a reserved domain.

---

## 3. n8n workflow setup (~2 minutes, one time)

Node graph:

```
Receive YouTube URL (webhook POST /setlist-submit)
→ Config → Check Webhook Token ─(fail)→ Reject (401)
→ Site Job?  (body has video_id = full approved job from the hosted site)
   ├─(yes: SITE PATH — no form, already reviewed in the UI)
   │   → Build Site Job → Start Download on Mac (/download or /download-split)
   │   → Respond Job Started (job_id + execution_id back to the site)
   │   → Wait for Mac Callback ────────────────────────────────┐
   └─(no: SHORTCUT PATH)                                       │
       → Resolve Set on Mac → Fetch 1001 Tracklist → Prepare Review
       → Reply With Approval Link (returns approve_url to the Shortcut)
       → Approve & Edit (Form)  [human-in-the-loop]
       → Cancelled? ─(yes)→ Cancelled — No Action              │
       → Tracklist Provided? ─(yes)→ Parse Edited Tracklist ─┐ │
                             └─(no)──────────────────────────┴→ Build Job Request
       → Split Into Tracks? ─(yes)→ Start Split Download ─┐    │
                            └─(no)→ Start Single Download ─┴───┤
                                                               ↓
                                              Wait for Mac Callback → Completion Summary
```

Site-path payload (sent by the hosted site's Download button):

```json
{ "url": "…", "video_id": "…", "format": "alac|aac256", "split": true,
  "metadata": { "title": "…", "artist": "…", … }, "tracks": [{ "start": 0, "title": "…", "artist": "…" }] }
```

n8n replies `{ "status": "started", "job_id": "…", "split": true, "execution_id": "…" }`
(the Respond node runs right after the helper accepts the job, then the execution keeps
waiting for the callback). Tracks without a start time are dropped; `split` only sticks
if usable tracks remain.

Browser note: the site calls the webhook cross-origin with the `X-N8N-Auth` header, which
triggers a CORS preflight. The webhook node's *Allowed Origins* option is at its default
`*`; if a published run ever shows a preflight failure in the browser console, set that
option explicitly on the *Receive YouTube URL* node.

Steps:

1. Open <https://your-instance.app.n8n.cloud/workflow/<id>> → **Config** node and set:
   - `macBaseUrl` — the tunnel URL (pre-filled with `https://your-mac.your-tailnet.ts.net`);
   - `macApiToken` — copy `API_AUTH_TOKEN` from the repo's `.env`;
   - `webhookToken` — copy `N8N_WEBHOOK_TOKEN` from the repo's `.env`.
2. **Publish** the workflow (top-right toggle). The production webhook becomes
   `https://your-instance.app.n8n.cloud/webhook/setlist-submit`.

Webhook auth note: MCP cannot create n8n credentials, so the trigger authenticates via an
explicit IF check (`X-N8N-Auth` header vs `webhookToken`) — functional immediately, wrong/missing
token gets a 401. Optional hardening (1 minute): in n8n create a **Header Auth** credential
(name `X-N8N-Auth`, value = `N8N_WEBHOOK_TOKEN`), set Authentication = Header Auth on the
*Receive YouTube URL* node, pick the credential, then blank out `webhookToken` in Config so the
token no longer sits in workflow JSON.

Human-in-the-loop: the *Approve & Edit (Form)* Wait node needs **no credentials** — n8n serves a
form (link is returned to the Shortcut and also available on the paused execution). The form is
pre-filled with proposed Title / Artist / Album and the tracklist text (one `M:SS Artist - Title`
line per track). Edit lines freely; the edited text is re-parsed by the Mac app
(`/parse-tracklist`) and used for splitting. Clear the textarea (or pick "single file") to force
a single-file download. Splitting only happens when every track has a timestamp.

Notifications: no messaging credentials exist on the instance, so the flow ends at the
**Completion Summary** node (status, file paths, human message). To get a push/email at the end,
append a Gmail / Telegram / Slack node after *Completion Summary* once you add a credential —
the summary fields are ready to interpolate.

---

## 4. Apple Shortcut (share sheet → n8n)

Create a new Shortcut in the Shortcuts app:

1. Shortcut settings (ⓘ) → enable **Show in Share Sheet**; set accepted types to **URLs**.
2. Add action **Get Contents of URL** and configure:
   - URL: `https://your-instance.app.n8n.cloud/webhook/setlist-submit`
   - Method: **POST**
   - Headers: add `X-N8N-Auth` = the `N8N_WEBHOOK_TOKEN` value from `.env`
   - Request Body: **JSON**, one field: `url` = **Shortcut Input** (the shared URL)
3. Add **Get Dictionary Value** → key `approve_url` from *Contents of URL*.
4. Add **Open URLs** with that value — Safari opens the approval form directly.
   (Alternatively use **Show Notification** with `approve_url` if you prefer to open it later.)

Name it e.g. "Send to Setlist". Usage: YouTube app/Safari → Share → *Send to Setlist* → the
approval form opens → review, approve → files appear in `~/Music/YouTube Sets` when done.

Timing caveat: the webhook responds only after resolve + tracklist lookup (typically 15–45 s).
Shortcuts waits up to ~60 s; if it ever times out, the workflow still continues — open the
paused execution in n8n and click the form URL from there.

---

## 5. Go-live checklist (in order)

1. `.env` has `API_AUTH_TOKEN` + `N8N_WEBHOOK_TOKEN` (done — generated during setup)
   and `CORS_ORIGINS` for the hosted site (see `docs/hosted-site.md`).
2. Restart the Mac app: `./run.sh` — or install it as a login service: `./helper/install.sh`.
3. Start the tunnel: `tailscale funnel --bg 8765` (approve the Funnel attribute on first run).
4. Sanity check auth from another network:
   `curl -s https://your-mac.your-tailnet.ts.net/recent` → 401;
   with `-H "Authorization: Bearer $API_AUTH_TOKEN"` → 200.
5. Paste the three Config values in the n8n workflow (section 3) and **publish** it.
6. Hosted site: open <https://list-setlist.vercel.app> in Chrome on the Mac, open Settings
   (gear), paste the webhook URL (`https://your-instance.app.n8n.cloud/webhook/setlist-submit`)
   and the `N8N_WEBHOOK_TOKEN` value. The helper pill should already be green.
7. Build the Apple Shortcut (section 4) if you want the share-sheet path too.
8. Run one real set end-to-end (site Download click, or share from the phone).

Not yet done for you (requires publishing / real downloads): no live end-to-end test was run —
the workflow is a validated draft, and the Mac-side callback + auth are covered by unit tests.

Workflow source (for future edits via MCP or the n8n editor): `docs/n8n-workflow.sdk.js`.
