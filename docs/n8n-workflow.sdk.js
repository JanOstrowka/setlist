import { workflow, node, trigger, sticky, expr } from '@n8n/workflow-sdk';

// Setlist — YouTube to Apple Music. Two entry paths share one webhook:
//   1. Hosted-site jobs (body carries video_id + approved metadata/tracklist):
//      no form — the human already reviewed everything in the site UI. n8n
//      forwards the job to the Mac helper, replies with the helper's job_id
//      (the site attaches to the local SSE stream for live progress), then
//      waits for the completion callback. n8n is the audit trail.
//   2. Apple-Shortcut jobs (body carries only url): resolve + tracklist fetch
//      on the Mac, then an n8n form is the human-in-the-loop approval step.

const receiveUrl = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'Receive YouTube URL',
    parameters: {
      httpMethod: 'POST',
      path: 'setlist-submit',
      responseMode: 'responseNode',
    },
    position: [240, 380],
  },
  output: [{
    headers: { 'x-n8n-auth': 'webhook-token' },
    params: {},
    query: {},
    body: {
      url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      video_id: 'dQw4w9WgXcQ',
      format: 'alac',
      split: true,
      metadata: { title: 'Set Title', artist: 'DJ Name', album: 'Festival Set 2026', album_artist: 'DJ Name', year: 2026, genre: 'House', comment: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', compilation: false },
      tracks: [{ start: 0, title: 'Opener', artist: 'Artist A' }],
    },
  }],
});

const setConfig = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Config',
    parameters: {
      mode: 'manual',
      assignments: {
        assignments: [
          { id: 'cfg-base-url', name: 'macBaseUrl', value: 'https://macbook-pro.tailb2c1e.ts.net', type: 'string' },
          { id: 'cfg-api-token', name: 'macApiToken', value: 'PASTE_API_AUTH_TOKEN_FROM_MAC_ENV', type: 'string' },
          { id: 'cfg-webhook-token', name: 'webhookToken', value: 'PASTE_N8N_WEBHOOK_TOKEN_FROM_MAC_ENV', type: 'string' },
        ],
      },
      includeOtherFields: true,
    },
    position: [460, 380],
  },
  output: [{
    macBaseUrl: 'https://macbook-pro.tailb2c1e.ts.net',
    macApiToken: 'token',
    webhookToken: 'webhook-token',
    headers: { 'x-n8n-auth': 'webhook-token' },
    body: { url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', video_id: 'dQw4w9WgXcQ' },
  }],
});

const checkToken = node({
  type: 'n8n-nodes-base.if',
  version: 2.3,
  config: {
    name: 'Check Webhook Token',
    parameters: {
      conditions: {
        conditions: [
          {
            leftValue: expr('{{ $json.headers["x-n8n-auth"] ?? "" }}'),
            operator: { type: 'string', operation: 'equals' },
            rightValue: expr('{{ $json.webhookToken }}'),
          },
        ],
      },
    },
    position: [680, 380],
  },
  output: [{ macBaseUrl: 'https://macbook-pro.tailb2c1e.ts.net', body: { url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', video_id: 'dQw4w9WgXcQ' } }],
});

const rejectRequest = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Reject (401)',
    parameters: {
      respondWith: 'json',
      responseBody: '{"status":"unauthorized","detail":"Missing or invalid X-N8N-Auth header"}',
      options: { responseCode: 401 },
    },
    position: [900, 620],
  },
  output: [{ status: 'unauthorized' }],
});

const siteJobCheck = node({
  type: 'n8n-nodes-base.if',
  version: 2.3,
  config: {
    name: 'Site Job?',
    parameters: {
      conditions: {
        conditions: [
          {
            leftValue: expr('{{ $json.body.video_id ?? "" }}'),
            operator: { type: 'string', operation: 'notEmpty' },
            rightValue: '',
          },
        ],
      },
    },
    position: [900, 340],
  },
  output: [{ body: { url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', video_id: 'dQw4w9WgXcQ', split: true } }],
});

const buildSiteJob = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Site Job',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: 'const payload = $("Receive YouTube URL").first().json.body;\n' +
        'const tracks = Array.isArray(payload.tracks) ? payload.tracks : [];\n' +
        'const usable = tracks.filter((t) => t.start !== null && t.start !== undefined);\n' +
        'const split = !!payload.split && usable.length > 0;\n' +
        'const body = {\n' +
        '  video_id: payload.video_id,\n' +
        '  url: payload.url,\n' +
        '  metadata: payload.metadata || {},\n' +
        '  format: payload.format === "aac256" ? "aac256" : "alac",\n' +
        '  cover: "keep",\n' +
        '  callback_url: $execution.resumeUrl,\n' +
        '};\n' +
        'if (split) body.tracks = usable.map((t) => ({ start: t.start, title: t.title || "", artist: t.artist || "" }));\n' +
        'const note = split\n' +
        '  ? "Split download: " + usable.length + " tracks (reviewed in the site UI)"\n' +
        '  : "Single-file download (reviewed in the site UI)";\n' +
        'return [{ json: { split: split, note: note, body: body } }];',
    },
    position: [1120, 140],
  },
  output: [{
    split: true,
    note: 'Split download: 24 tracks (reviewed in the site UI)',
    body: { video_id: 'dQw4w9WgXcQ', url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', metadata: { title: 'Set Title' }, format: 'alac', cover: 'keep', callback_url: 'https://janostrowka.app.n8n.cloud/webhook-waiting/123', tracks: [{ start: 0, title: 'Opener', artist: 'Artist A' }] },
  }],
});

const startSiteDownload = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Start Download on Mac',
    parameters: {
      method: 'POST',
      url: expr('{{ $("Config").first().json.macBaseUrl }}{{ $json.split ? "/download-split" : "/download" }}'),
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'Authorization', value: expr('Bearer {{ $("Config").first().json.macApiToken }}') },
        ],
      },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ $json.body }}'),
      options: { timeout: 60000 },
    },
    position: [1340, 140],
  },
  output: [{ job_id: 'abc123' }],
});

const respondJobStarted = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Respond Job Started',
    parameters: {
      respondWith: 'json',
      responseBody: expr('{{ { "status": "started", "job_id": $json.job_id, "split": $("Build Site Job").first().json.split, "note": $("Build Site Job").first().json.note, "execution_id": $execution.id } }}'),
      options: { responseCode: 200 },
    },
    position: [1560, 140],
  },
  output: [{ job_id: 'abc123' }],
});

const resolveSet = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Resolve Set on Mac',
    parameters: {
      method: 'POST',
      url: expr('{{ $("Config").first().json.macBaseUrl }}/resolve'),
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'Authorization', value: expr('Bearer {{ $("Config").first().json.macApiToken }}') },
        ],
      },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ { "url": $("Receive YouTube URL").first().json.body.url } }}'),
      options: { timeout: 300000 },
    },
    position: [1120, 460],
  },
  output: [{
    video_id: 'dQw4w9WgXcQ',
    duration: 5400,
    metadata: { title: 'Set Title', artist: 'DJ Name', album: 'Album', album_artist: 'DJ Name', year: 2026, genre: 'House', comment: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', compilation: false },
    cover: 'data:image/jpeg;base64,...',
    formats: 'opus 160k',
    detected_line: 'Detected...',
    has_chapters: false,
    tracklist: { source: 'none', tracks: [], album: '', album_artist: '', note: '' },
  }],
});

const fetchTracklist = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Fetch 1001 Tracklist',
    parameters: {
      method: 'POST',
      url: expr('{{ $("Config").first().json.macBaseUrl }}/auto-tracklist'),
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'Authorization', value: expr('Bearer {{ $("Config").first().json.macApiToken }}') },
        ],
      },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ { "query": $("Resolve Set on Mac").first().json.metadata.title, "url": $("Receive YouTube URL").first().json.body.url, "duration": $("Resolve Set on Mac").first().json.duration } }}'),
      options: { timeout: 180000 },
    },
    position: [1340, 460],
  },
  output: [{
    source: '1001tracklists',
    tracks: [{ start: 0, title: 'Opener', artist: 'Artist A', end: null }],
    album: 'Festival Set 2026',
    album_artist: 'DJ Name',
    note: '24 of 24 tracks have cue times.',
  }],
});

const prepareReview = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Prepare Review',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: 'const resolved = $("Resolve Set on Mac").first().json;\n' +
        'const tl = $("Fetch 1001 Tracklist").first().json;\n' +
        'const meta = resolved.metadata || {};\n' +
        'const fmt = (s) => {\n' +
        '  const sec = Math.max(0, Math.round(s || 0));\n' +
        '  const h = Math.floor(sec / 3600);\n' +
        '  const m = Math.floor((sec % 3600) / 60);\n' +
        '  const ss = String(sec % 60).padStart(2, "0");\n' +
        '  return h > 0 ? h + ":" + String(m).padStart(2, "0") + ":" + ss : m + ":" + ss;\n' +
        '};\n' +
        'const tracks = Array.isArray(tl.tracks) ? tl.tracks : [];\n' +
        'const lines = tracks.map((t) => {\n' +
        '  const cue = (t.start === null || t.start === undefined) ? "?:??" : fmt(t.start);\n' +
        '  return cue + " " + (t.artist ? t.artist + " - " : "") + (t.title || "Untitled");\n' +
        '});\n' +
        'const missing = tracks.filter((t) => t.start === null || t.start === undefined).length;\n' +
        'return [{ json: {\n' +
        '  title: meta.title || "",\n' +
        '  artist: meta.artist || "",\n' +
        '  album: (tl.album || meta.album || ""),\n' +
        '  duration_text: fmt(resolved.duration),\n' +
        '  tracks_found: tracks.length,\n' +
        '  tracklist_source: tl.source || "none",\n' +
        '  missing_cues: missing,\n' +
        '  tracklist_text: lines.join("\\n"),\n' +
        '} }];',
    },
    position: [1560, 460],
  },
  output: [{
    title: 'Set Title',
    artist: 'DJ Name',
    album: 'Festival Set 2026',
    duration_text: '1:30:00',
    tracks_found: 24,
    tracklist_source: '1001tracklists',
    missing_cues: 0,
    tracklist_text: '0:00 Artist A - Opener',
  }],
});

const sendReviewLink = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Reply With Approval Link',
    parameters: {
      respondWith: 'json',
      responseBody: expr('{{ { "status": "review_ready", "title": $json.title, "artist": $json.artist, "tracks_found": $json.tracks_found, "tracklist_source": $json.tracklist_source, "approve_url": $execution.resumeFormUrl } }}'),
      options: { responseCode: 200 },
    },
    position: [1780, 460],
  },
  output: [{
    title: 'Set Title',
    artist: 'DJ Name',
    album: 'Festival Set 2026',
    duration_text: '1:30:00',
    tracks_found: 24,
    tracklist_source: '1001tracklists',
    missing_cues: 0,
    tracklist_text: '0:00 Artist A - Opener',
  }],
});

const approvalForm = node({
  type: 'n8n-nodes-base.wait',
  version: 1.1,
  config: {
    name: 'Approve & Edit (Form)',
    parameters: {
      resume: 'form',
      formTitle: 'Setlist — approve download',
      formDescription: expr('{{ $json.artist }} — {{ $json.title }} ({{ $json.duration_text }}). Album: {{ $json.album }}. Tracklist: {{ $json.tracks_found }} tracks from {{ $json.tracklist_source }}{{ $json.missing_cues > 0 ? " with " + $json.missing_cues + " missing timestamps" : "" }}. Edit the tracklist below, or clear it to force a single-file download.'),
      formFields: {
        values: [
          {
            fieldLabel: 'Decision',
            fieldName: 'Decision',
            fieldType: 'dropdown',
            fieldOptions: {
              values: [
                { option: 'Approve — auto (split when tracklist is complete)' },
                { option: 'Approve — single file' },
                { option: 'Cancel' },
              ],
            },
            defaultValue: 'Approve — auto (split when tracklist is complete)',
            requiredField: true,
          },
          { fieldLabel: 'Title', fieldName: 'Title', fieldType: 'text', defaultValue: expr('{{ $json.title }}') },
          { fieldLabel: 'Artist', fieldName: 'Artist', fieldType: 'text', defaultValue: expr('{{ $json.artist }}') },
          { fieldLabel: 'Album', fieldName: 'Album', fieldType: 'text', defaultValue: expr('{{ $json.album }}') },
          { fieldLabel: 'Tracklist', fieldName: 'Tracklist', fieldType: 'textarea', defaultValue: expr('{{ $json.tracklist_text }}'), placeholder: 'One line per track, e.g. 0:00 Artist - Title' },
        ],
      },
    },
    position: [2000, 460],
  },
  output: [{
    Decision: 'Approve — auto (split when tracklist is complete)',
    Title: 'Set Title',
    Artist: 'DJ Name',
    Album: 'Festival Set 2026',
    Tracklist: '0:00 Artist A - Opener',
    submittedAt: '2026-07-12T12:00:00.000Z',
    formMode: 'production',
  }],
});

const checkCancelled = node({
  type: 'n8n-nodes-base.if',
  version: 2.3,
  config: {
    name: 'Cancelled?',
    parameters: {
      conditions: {
        conditions: [
          {
            leftValue: expr('{{ $json.Decision ?? "" }}'),
            operator: { type: 'string', operation: 'contains' },
            rightValue: 'Cancel',
          },
        ],
      },
    },
    position: [2220, 460],
  },
  output: [{ Decision: 'Approve — auto (split when tracklist is complete)', Tracklist: '0:00 Artist A - Opener' }],
});

const cancelledEnd = node({
  type: 'n8n-nodes-base.noOp',
  version: 1,
  config: { name: 'Cancelled — No Action', parameters: {}, position: [2440, 660] },
  output: [{ Decision: 'Cancel' }],
});

const checkEdited = node({
  type: 'n8n-nodes-base.if',
  version: 2.3,
  config: {
    name: 'Tracklist Provided?',
    parameters: {
      conditions: {
        conditions: [
          {
            leftValue: expr('{{ ($json.Tracklist ?? "").trim() }}'),
            operator: { type: 'string', operation: 'notEmpty' },
            rightValue: '',
          },
        ],
      },
    },
    position: [2440, 400],
  },
  output: [{ Decision: 'Approve — auto (split when tracklist is complete)', Tracklist: '0:00 Artist A - Opener' }],
});

const parseEdited = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Parse Edited Tracklist',
    parameters: {
      method: 'POST',
      url: expr('{{ $("Config").first().json.macBaseUrl }}/parse-tracklist'),
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'Authorization', value: expr('Bearer {{ $("Config").first().json.macApiToken }}') },
        ],
      },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ { "text": $json.Tracklist, "duration": $("Resolve Set on Mac").first().json.duration } }}'),
      options: { timeout: 60000 },
    },
    position: [2660, 300],
  },
  output: [{
    source: 'manual',
    tracks: [{ start: 0, title: 'Opener', artist: 'Artist A', end: null }],
    album: '',
    album_artist: '',
    note: '',
  }],
});

const buildPayload = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Build Job Request',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: 'const resolved = $("Resolve Set on Mac").first().json;\n' +
        'const form = $("Approve & Edit (Form)").first().json;\n' +
        'let tl = { source: "none", tracks: [], album: "", album_artist: "" };\n' +
        'try { tl = $("Parse Edited Tracklist").first().json; } catch (e) {}\n' +
        'const decision = String(form.Decision || "").toLowerCase();\n' +
        'const singleOnly = decision.includes("single");\n' +
        'const tracks = Array.isArray(tl.tracks) ? tl.tracks : [];\n' +
        'const cuesComplete = tracks.length > 0 && tracks.every((t) => t.start !== null && t.start !== undefined);\n' +
        'const split = !singleOnly && cuesComplete;\n' +
        'const metadata = Object.assign({}, resolved.metadata);\n' +
        'if (form.Title) metadata.title = form.Title;\n' +
        'if (form.Artist) metadata.artist = form.Artist;\n' +
        'if (form.Album) metadata.album = form.Album;\n' +
        'if (tl.album && !form.Album) metadata.album = tl.album;\n' +
        'if (tl.album_artist) metadata.album_artist = tl.album_artist;\n' +
        'else if (form.Artist) metadata.album_artist = form.Artist;\n' +
        'const body = {\n' +
        '  video_id: resolved.video_id,\n' +
        '  url: $("Receive YouTube URL").first().json.body.url,\n' +
        '  metadata: metadata,\n' +
        '  format: "alac",\n' +
        '  cover: "keep",\n' +
        '  callback_url: $execution.resumeUrl,\n' +
        '};\n' +
        'if (split) body.tracks = tracks;\n' +
        'const note = split\n' +
        '  ? "Split download: " + tracks.length + " tracks"\n' +
        '  : (tracks.length > 0 ? "Single file (tracklist incomplete or single requested)" : "Single file (no tracklist)");\n' +
        'return [{ json: { split: split, note: note, body: body } }];',
    },
    position: [2880, 400],
  },
  output: [{
    split: true,
    note: 'Split download: 24 tracks',
    body: { video_id: 'dQw4w9WgXcQ', url: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ', metadata: { title: 'Set Title' }, format: 'alac', cover: 'keep', callback_url: 'https://janostrowka.app.n8n.cloud/webhook-waiting/123', tracks: [{ start: 0, title: 'Opener', artist: 'Artist A' }] },
  }],
});

const checkSplit = node({
  type: 'n8n-nodes-base.if',
  version: 2.3,
  config: {
    name: 'Split Into Tracks?',
    parameters: {
      conditions: {
        conditions: [
          {
            leftValue: expr('{{ $json.split }}'),
            operator: { type: 'boolean', operation: 'true' },
            rightValue: '',
          },
        ],
      },
    },
    position: [3100, 400],
  },
  output: [{ split: true, body: {} }],
});

const startSplit = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Start Split Download',
    parameters: {
      method: 'POST',
      url: expr('{{ $("Config").first().json.macBaseUrl }}/download-split'),
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'Authorization', value: expr('Bearer {{ $("Config").first().json.macApiToken }}') },
        ],
      },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ $json.body }}'),
      options: { timeout: 60000 },
    },
    position: [3320, 300],
  },
  output: [{ job_id: 'abc123' }],
});

const startSingle = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.4,
  config: {
    name: 'Start Single Download',
    parameters: {
      method: 'POST',
      url: expr('{{ $("Config").first().json.macBaseUrl }}/download'),
      sendHeaders: true,
      headerParameters: {
        parameters: [
          { name: 'Authorization', value: expr('Bearer {{ $("Config").first().json.macApiToken }}') },
        ],
      },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ $json.body }}'),
      options: { timeout: 60000 },
    },
    position: [3320, 520],
  },
  output: [{ job_id: 'abc123' }],
});

const waitForJob = node({
  type: 'n8n-nodes-base.wait',
  version: 1.1,
  config: {
    name: 'Wait for Mac Callback',
    parameters: {
      resume: 'webhook',
      httpMethod: 'POST',
      responseCode: 200,
    },
    position: [3540, 340],
  },
  output: [{
    headers: {},
    params: {},
    query: {},
    body: { job_id: 'abc123', status: 'done', output_paths: ['/Users/jan/Music/YouTube Sets/DJ Name/Festival Set 2026/01 Opener.m4a'], error: '' },
  }],
});

const jobSummary = node({
  type: 'n8n-nodes-base.set',
  version: 3.4,
  config: {
    name: 'Completion Summary',
    parameters: {
      mode: 'manual',
      assignments: {
        assignments: [
          { id: 'sum-status', name: 'status', value: expr('{{ $json.body?.status ?? "unknown" }}'), type: 'string' },
          { id: 'sum-files', name: 'files', value: expr('{{ $json.body?.output_paths ?? [] }}'), type: 'array' },
          { id: 'sum-error', name: 'error', value: expr('{{ $json.body?.error ?? "" }}'), type: 'string' },
          { id: 'sum-message', name: 'message', value: expr('{{ $json.body?.status === "done" ? "Saved " + ($json.body?.output_paths?.length ?? 0) + " file(s) to ~/Music/YouTube Sets on the Mac. Add them to Apple Music from there." : "Job failed: " + ($json.body?.error ?? "unknown error") }}'), type: 'string' },
        ],
      },
      includeOtherFields: false,
    },
    position: [3760, 340],
  },
  output: [{
    status: 'done',
    files: ['/Users/jan/Music/YouTube Sets/DJ Name/Festival Set 2026/01 Opener.m4a'],
    error: '',
    message: 'Saved 24 file(s) to ~/Music/YouTube Sets on the Mac. Add them to Apple Music from there.',
  }],
});

const setupNote = sticky(
  '## One-time setup\n1. Open the Config node and paste values from the Mac repo .env: macApiToken = API_AUTH_TOKEN, webhookToken = N8N_WEBHOOK_TOKEN. Set macBaseUrl to your tunnel URL.\n2. Start the tunnel on the Mac (see docs/n8n-integration.md in the repo).\n3. Publish this workflow.\n\nTwo entry paths share POST /webhook/setlist-submit (header X-N8N-Auth):\n- Hosted site sends a full approved job (video_id + metadata + tracklist) -> no form; n8n replies with the Mac job_id so the site can stream live progress locally.\n- Apple Shortcut sends just { url } -> resolve on the Mac, then the approval form.\n\nOptional hardening: create a Header Auth credential (name: X-N8N-Auth) and set it on the Receive YouTube URL node, then clear webhookToken from Config.',
  [setConfig],
  { color: 4 },
);

const notifyNote = sticky(
  '## Notifications\nNo messaging credentials exist on this instance, so the flow ends at Completion Summary (status, files, message). Replace or extend that node with Gmail / Telegram / Slack once a credential is configured.',
  [jobSummary],
  { color: 5 },
);

export default workflow('setlist-yt-to-apple-music', 'Setlist — YouTube to Apple Music')
  .add(setupNote)
  .add(notifyNote)
  .add(receiveUrl)
  .to(setConfig)
  .to(checkToken
    .onTrue(siteJobCheck
      .onTrue(buildSiteJob.to(startSiteDownload.to(respondJobStarted.to(waitForJob))))
      .onFalse(resolveSet.to(fetchTracklist.to(prepareReview.to(sendReviewLink.to(approvalForm))))))
    .onFalse(rejectRequest))
  .add(approvalForm)
  .to(checkCancelled
    .onTrue(cancelledEnd)
    .onFalse(checkEdited
      .onTrue(parseEdited.to(buildPayload))
      .onFalse(buildPayload)))
  .add(buildPayload)
  .to(checkSplit
    .onTrue(startSplit.to(waitForJob))
    .onFalse(startSingle.to(waitForJob)))
  .add(waitForJob)
  .to(jobSummary);
