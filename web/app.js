const $ = (id) => document.getElementById(id);
const state = {
  videoId: "",
  url: "",
  detectedAlac: "",
  duration: 0,
  player: null,
  resolveController: null,
  autoTlController: null,
};
const tl = { source: "none", tracks: [] };
let debounceTimer = null;

// ---- time helpers ----------------------------------------------------------
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

// Pull an 11-char YouTube id out of the common URL shapes so we can tell, on
// paste, whether the link is worth auto-resolving (before the user clicks).
function parseYouTubeId(url) {
  if (!url) return "";
  const patterns = [
    /[?&]v=([A-Za-z0-9_-]{11})/,
    /youtu\.be\/([A-Za-z0-9_-]{11})/,
    /youtube\.com\/(?:embed|live|shorts)\/([A-Za-z0-9_-]{11})/,
  ];
  for (const re of patterns) {
    const m = url.match(re);
    if (m) return m[1];
  }
  return "";
}

// ---- YouTube IFrame player -------------------------------------------------
// The embedded player is built via the IFrame API so clicking a track can seek
// it. The API is loaded lazily; player creation queues until it is ready.
const ytQueue = [];
function loadYouTubeApi() {
  if (window.YT && window.YT.Player) return;
  if (document.getElementById("yt-iframe-api")) return;
  const s = document.createElement("script");
  s.id = "yt-iframe-api";
  s.src = "https://www.youtube.com/iframe_api";
  document.head.appendChild(s);
}
window.onYouTubeIframeAPIReady = function () {
  ytQueue.splice(0).forEach((fn) => fn());
};

function mountPlayer(videoId) {
  const host = $("ytPlayer");
  host.innerHTML = "";
  const target = document.createElement("div");
  target.id = "yt-frame";
  host.appendChild(target);
  state.player = null;
  if (!videoId) return;
  const build = () => {
    state.player = new YT.Player("yt-frame", {
      videoId,
      playerVars: { rel: 0, modestbranding: 1, playsinline: 1 },
    });
  };
  if (window.YT && window.YT.Player) {
    build();
  } else {
    loadYouTubeApi();
    ytQueue.length = 0; // only the latest mount matters
    ytQueue.push(build);
  }
}

function seekPlayer(sec) {
  if (sec == null) return;
  const p = state.player;
  if (p && typeof p.seekTo === "function") {
    p.seekTo(sec, true);
    if (typeof p.playVideo === "function") p.playVideo();
  }
}

// ---- resolve (auto on paste + explicit button) -----------------------------
async function resolve(opts = {}) {
  const url = $("url").value.trim();
  if (!url) return;
  // Cancel anything in-flight so rapid edits/clicks don't stack requests.
  if (state.resolveController) state.resolveController.abort();
  if (state.autoTlController) state.autoTlController.abort();
  const ctrl = new AbortController();
  state.resolveController = ctrl;
  setResolveState(opts.auto ? "Resolving link…" : "Resolving…", { spin: true });
  $("resolveBtn").disabled = true;
  try {
    const res = await fetch("/resolve", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url }),
      signal: ctrl.signal,
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ detail: res.statusText }));
      throw new Error(err.detail || "Resolve failed");
    }
    const data = await res.json();
    if (ctrl.signal.aborted) return;
    state.videoId = data.video_id;
    state.url = url;
    state.detectedAlac = data.detected_line;
    state.duration = data.duration || 0;
    $("cover").src = data.cover || "";
    $("cover").alt = data.metadata && data.metadata.title
      ? `Cover art for ${data.metadata.title}`
      : "Cover art preview";
    $("title").value = data.metadata.title || "";
    $("artist").value = data.metadata.artist || "";
    $("album").value = data.metadata.album || "";
    $("albumArtist").value = data.metadata.album_artist || "";
    $("year").value = data.metadata.year ?? "";
    $("genre").value = data.metadata.genre || "";
    $("compilation").checked = !!data.metadata.compilation;
    setTracklist(data.tracklist || { source: "none", tracks: [] });
    updateDetected();
    updateSplitState();
    enterResolvedState();
    mountPlayer(state.videoId);
    setResolveState("");
    autoFetchTracklist();
  } catch (err) {
    if (ctrl.signal.aborted || err.name === "AbortError") return;
    setResolveState("Error: " + err.message, { err: true });
  } finally {
    if (state.resolveController === ctrl) {
      state.resolveController = null;
      $("resolveBtn").disabled = false;
    }
  }
}

function onUrlInput() {
  if (debounceTimer) clearTimeout(debounceTimer);
  const url = $("url").value.trim();
  const id = parseYouTubeId(url);
  if (!id) {
    setResolveState("");
    if (state.resolveController) {
      state.resolveController.abort();
      state.resolveController = null;
    }
    return;
  }
  if (id === state.videoId && url === state.url) {
    setResolveState("");
    return;
  }
  setResolveState("Checking link…", { spin: true });
  debounceTimer = setTimeout(() => resolve({ auto: true }), 650);
}

function setResolveState(msg, { err = false, spin = false } = {}) {
  const el = $("resolveState");
  el.className = "resolve-state" + (err ? " err" : "");
  el.innerHTML = "";
  if (spin && msg) {
    const s = document.createElement("span");
    s.className = "spin";
    el.appendChild(s);
  }
  el.appendChild(document.createTextNode(msg || ""));
}

// ---- landing <-> resolved workspace ----------------------------------------
function enterResolvedState() {
  document.body.classList.remove("state-landing");
  document.body.classList.add("state-resolved");
  $("workspace").classList.remove("hidden");
  $("recentSection").classList.add("hidden");
  $("resetBtn").classList.remove("hidden");
}

function resetToLanding() {
  if (debounceTimer) clearTimeout(debounceTimer);
  if (state.resolveController) state.resolveController.abort();
  if (state.autoTlController) state.autoTlController.abort();
  state.videoId = "";
  state.url = "";
  state.duration = 0;
  state.detectedAlac = "";
  state.player = null;
  tl.source = "none";
  tl.tracks = [];
  $("ytPlayer").innerHTML = "";
  $("url").value = "";
  document.body.classList.add("state-landing");
  document.body.classList.remove("state-resolved");
  $("workspace").classList.add("hidden");
  $("recentSection").classList.remove("hidden");
  $("resetBtn").classList.add("hidden");
  setResolveState("");
  loadRecent();
  $("url").focus();
}

// ---- tracklist -------------------------------------------------------------
function setTracklist(data) {
  tl.source = data.source || "none";
  tl.tracks = (data.tracks || []).map((t) => ({
    start: t.start ?? null,
    title: t.title || "",
    artist: t.artist || "",
  }));
  // A source-provided album/artist (e.g. from a 1001tracklists H1) fills the
  // shared album fields; empty values never clobber the AI-proposed metadata.
  if (data.album_artist) $("albumArtist").value = data.album_artist;
  if (data.album) $("album").value = data.album;
  renderTracklist();
}

function renderTracklist() {
  const sourceLabel = {
    chapters: "from YouTube chapters",
    description: "from description timestamps",
    manual: "from pasted text",
    "1001tracklists": "from 1001tracklists",
    none: "none yet — fetch or paste a list above, or add rows",
  }[tl.source] || "";
  $("tlSource").textContent = sourceLabel ? `(${sourceLabel})` : "";
  const rows = $("trackRows");
  rows.innerHTML = "";
  tl.tracks.forEach((t, i) => {
    const row = document.createElement("div");
    row.className = "track-row" + (t.start == null ? " no-time" : "");

    // Per-track seek button: jump the player to this track to verify the cue.
    const seek = document.createElement("button");
    seek.type = "button";
    seek.className = "seek";
    seek.textContent = "▶";
    seek.title = "Jump the player to this track";
    seek.setAttribute("aria-label", "Jump player to this track");
    seek.addEventListener("click", () => seekPlayer(t.start));

    const start = document.createElement("input");
    start.className = "start";
    start.value = secondsToClock(t.start);
    start.placeholder = "—";
    start.setAttribute("aria-label", "Start time");
    start.title = "Click to jump the player here; edit to set the start time";
    start.addEventListener("change", () => {
      t.start = clockToSeconds(start.value);
      row.classList.toggle("no-time", t.start == null);
    });
    // Clicking a track's time seeks the player so the user can confirm it.
    start.addEventListener("click", () => seekPlayer(clockToSeconds(start.value)));

    const title = document.createElement("input");
    title.value = t.title;
    title.placeholder = "Title";
    title.addEventListener("change", () => { t.title = title.value; });

    const artist = document.createElement("input");
    artist.className = "artist";
    artist.value = t.artist;
    artist.placeholder = "Artist";
    artist.addEventListener("change", () => { t.artist = artist.value; });

    const btns = document.createElement("div");
    btns.className = "row-btns";
    btns.appendChild(iconBtn("↑", () => moveTrack(i, -1)));
    btns.appendChild(iconBtn("↓", () => moveTrack(i, 1)));
    btns.appendChild(iconBtn("✕", () => removeTrack(i)));

    row.append(seek, start, title, artist, btns);
    rows.appendChild(row);
  });
  // Re-rendered rows must inherit the current enabled/disabled split state.
  setTracklistEnabled($("split").checked);
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
    const start = row.querySelector(".start");
    const inputs = row.querySelectorAll("input");
    // inputs = [start, title, artist]
    tl.tracks[i].start = clockToSeconds(start.value);
    tl.tracks[i].title = inputs[1].value;
    tl.tracks[i].artist = inputs[2].value;
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

// Auto-fetch the matching 1001tracklists tracklist once a set resolves. It is
// best-effort: when nothing is found it degrades quietly to whatever the resolve
// step proposed (chapters/description) and manual paste remains available.
async function autoFetchTracklist() {
  if (state.autoTlController) state.autoTlController.abort();
  const ctrl = new AbortController();
  state.autoTlController = ctrl;
  const note = $("tl1001Note");
  note.className = "hint";
  note.textContent = "Looking for a matching tracklist on 1001tracklists…";
  try {
    const res = await fetch("/auto-tracklist", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        query: $("title").value || "",
        url: state.url,
        duration: state.duration,
      }),
      signal: ctrl.signal,
    });
    if (!res.ok) throw new Error("auto-fetch failed");
    const data = await res.json();
    if (ctrl.signal.aborted) return;
    const n = (data.tracks || []).length;
    if (n > 0) {
      setTracklist(data);
      $("split").checked = true;
      updateSplitState();
      note.textContent = data.note || `Auto-loaded ${n} tracks from 1001tracklists.`;
    } else {
      note.textContent = data.note
        || "No 1001tracklists match — paste a list if you want to split.";
    }
  } catch (err) {
    if (ctrl.signal.aborted || err.name === "AbortError") return;
    note.textContent = "Couldn't auto-fetch a tracklist — paste one to split.";
  } finally {
    if (state.autoTlController === ctrl) state.autoTlController = null;
  }
}

async function parsePasted() {
  const text = $("pasteBox").value;
  const note = $("pasteNote");
  if (!text.trim()) return;
  const btn = $("parseBtn");
  btn.disabled = true;
  note.className = "hint";
  note.textContent = "Parsing…";
  try {
    const res = await fetch("/parse-tracklist", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text, duration: state.duration }),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ detail: res.statusText }));
      throw new Error(err.detail || "Parse failed");
    }
    const data = await res.json();
    setTracklist(data);
    const n = (data.tracks || []).length;
    if (n > 0) {
      $("split").checked = true;
      updateSplitState();
    }
    note.textContent = n
      ? `Parsed ${n} track${n === 1 ? "" : "s"}. Tracks without a time are skipped when splitting.`
      : "No tracks found in the pasted text.";
  } catch (err) {
    note.className = "hint err-text";
    note.textContent = "Error: " + err.message;
  } finally {
    btn.disabled = false;
  }
}

async function fetch1001() {
  const url = $("url1001").value.trim();
  const note = $("tl1001Note");
  if (!url) return;
  const btn = $("fetch1001Btn");
  btn.disabled = true;
  note.className = "hint";
  note.textContent = "Fetching from 1001tracklists… this can take ~30s (it renders the page and bypasses the bot wall).";
  try {
    const res = await fetch("/parse-tracklist", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: url, duration: state.duration }),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({ detail: res.statusText }));
      throw new Error(err.detail || "Fetch failed");
    }
    const data = await res.json();
    setTracklist(data);
    if ((data.tracks || []).length > 0) {
      $("split").checked = true;
      updateSplitState();
    }
    note.textContent = data.note || `Loaded ${(data.tracks || []).length} tracks.`;
  } catch (err) {
    note.className = "hint err-text";
    note.textContent = "Error: " + err.message;
  } finally {
    btn.disabled = false;
  }
}

function setTlSource(mode) {
  const fetchMode = mode === "fetch";
  $("from1001").classList.toggle("hidden", !fetchMode);
  $("pastePanel").classList.toggle("hidden", fetchMode);
  $("srcFetchBtn").classList.toggle("active", fetchMode);
  $("srcFetchBtn").setAttribute("aria-checked", String(fetchMode));
  $("srcPasteBtn").classList.toggle("active", !fetchMode);
  $("srcPasteBtn").setAttribute("aria-checked", String(!fetchMode));
}

// The split toggle enables/disables the tracklist UI instead of hiding it, so
// the editor stays visible (greyed out) when splitting is off.
function setTracklistEnabled(enabled) {
  ["tlsource", "tracklist"].forEach((id) => {
    const section = $(id);
    if (!section) return;
    section.classList.toggle("tl-disabled", !enabled);
    section.setAttribute("aria-disabled", String(!enabled));
    section
      .querySelectorAll("input, textarea, button")
      .forEach((el) => { el.disabled = !enabled; });
  });
}

function updateSplitState() {
  const on = $("split").checked;
  setTracklistEnabled(on);
  if (!on) clearDownloadError();
  $("downloadBtn").textContent = on ? "Download & split" : "Download & tag";
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
    setDownloadError("Error: " + err.message);
    $("downloadBtn").disabled = false;
  }
}

async function downloadSplit() {
  readRowsFromDOM();
  clearDownloadError();
  // Blank/missing-time entries are usually false positives — silently skip them
  // (never block or highlight). Only tracks with a start time are split.
  const tracks = tl.tracks
    .filter((t) => t.start != null)
    .map((t) => ({ start: t.start, title: t.title, artist: t.artist }));
  if (tracks.length === 0) {
    setDownloadError("Add at least one track with a start time to split.");
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
    setDownloadError("Error: " + err.message);
    $("downloadBtn").disabled = false;
  }
}

function startProgress() {
  $("downloadBtn").disabled = true;
  $("revealDone").style.display = "none";
  $("progress").classList.remove("hidden");
  setBar(0);
  clearDownloadError();
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
      setDownloadError("Error: " + ev.message);
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

// ---- recents (with thumbnails) ---------------------------------------------
function loadRecent() {
  fetch("/recent")
    .then((res) => res.json())
    .then((items) => {
      const ul = $("recent");
      ul.innerHTML = "";
      if (!items.length) {
        const li = document.createElement("li");
        li.className = "recent-empty";
        li.textContent = "Nothing saved yet — paste a link above to start.";
        ul.appendChild(li);
        return;
      }
      items.forEach((it) => {
        const li = document.createElement("li");
        li.className = "recent-item";

        const img = document.createElement("img");
        img.className = "recent-thumb";
        img.loading = "lazy";
        img.alt = it.title ? `Cover for ${it.title}` : "Recent set";
        if (it.video_id) {
          img.src = `https://i.ytimg.com/vi/${encodeURIComponent(it.video_id)}/mqdefault.jpg`;
        }
        img.addEventListener("error", () => { img.style.visibility = "hidden"; });

        const meta = document.createElement("div");
        meta.className = "recent-meta";
        const t = document.createElement("div");
        t.className = "recent-title";
        t.textContent = it.title || "Untitled";
        const a = document.createElement("div");
        a.className = "recent-artist";
        a.textContent = it.artist || "";
        meta.append(t, a);

        const btn = document.createElement("button");
        btn.className = "ghost";
        btn.textContent = "Reveal";
        btn.addEventListener("click", () => revealPath(it.path));

        li.append(img, meta, btn);
        ul.appendChild(li);
      });
    })
    .catch(() => { /* ignore */ });
}

function setBar(pct) {
  $("bar").style.width = Math.max(0, Math.min(100, pct)) + "%";
}

// Errors that belong to the main download/split action render in a callout
// right next to the button, so the user sees them where they clicked.
function setDownloadError(msg) {
  const el = $("downloadError");
  el.textContent = msg || "";
  el.classList.toggle("show", !!msg);
}

function clearDownloadError() {
  setDownloadError("");
}

window.addEventListener("DOMContentLoaded", () => {
  $("resolveBtn").addEventListener("click", () => resolve({ auto: false }));
  $("resetBtn").addEventListener("click", resetToLanding);
  $("downloadBtn").addEventListener("click", download);
  $("aac256").addEventListener("change", updateDetected);
  $("split").addEventListener("change", updateSplitState);
  $("addTrackBtn").addEventListener("click", addTrack);
  $("parseBtn").addEventListener("click", parsePasted);
  $("fetch1001Btn").addEventListener("click", fetch1001);
  $("srcFetchBtn").addEventListener("click", () => setTlSource("fetch"));
  $("srcPasteBtn").addEventListener("click", () => setTlSource("paste"));
  $("url").addEventListener("input", onUrlInput);
  $("url").addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      if (debounceTimer) clearTimeout(debounceTimer);
      resolve({ auto: false });
    }
  });
  $("url1001").addEventListener("keydown", (e) => {
    if (e.key === "Enter") fetch1001();
  });
  loadYouTubeApi();
  updateSplitState();
  loadRecent();
});
