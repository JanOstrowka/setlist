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
    updateSplitState();
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
    row.className = "track-row";

    const start = document.createElement("input");
    start.className = "start";
    start.value = secondsToClock(t.start);
    start.placeholder = "0:00";
    start.addEventListener("change", () => { t.start = clockToSeconds(start.value); });
    // Clearing the highlight as soon as the user edits the offending field.
    start.addEventListener("input", () => start.classList.remove("invalid"));

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
    // A pasted tracklist means the user wants to split — reveal the editor.
    const n = (data.tracks || []).length;
    if (n > 0) {
      $("split").checked = true;
      updateSplitState();
    }
    note.textContent = n
      ? `Parsed ${n} track${n === 1 ? "" : "s"}. Review and fill any missing times below.`
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
    // A fetched tracklist means the user wants to split — reveal the editor.
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
  // Manual paste and the 1001tracklists URL fetch are co-equal sources that feed
  // the same editable tracklist; this just toggles which input is shown.
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
  if (!on) clearTrackErrors();
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
  clearTrackErrors();
  clearDownloadError();
  // A track counts as "active" if it has any content; empty rows are ignored.
  const missing = [];
  let activeCount = 0;
  tl.tracks.forEach((t, i) => {
    const active = t.title || t.artist || t.start != null;
    if (!active) return;
    activeCount += 1;
    if (t.start == null) missing.push(i);
  });
  if (activeCount === 0) {
    setDownloadError("Add at least one track to split.");
    return;
  }
  if (missing.length) {
    highlightMissingTimes(missing);
    setDownloadError(
      `Add a start time to ${missing.length} track${missing.length === 1 ? "" : "s"} before splitting.`
    );
    return;
  }
  const tracks = tl.tracks
    .map((t) => ({ start: t.start, title: t.title, artist: t.artist }))
    .filter((t) => t.title || t.artist || t.start != null);
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
  show("progress");
  setBar(0);
  setStatus("");
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

// Removing the red highlight from every track-time field.
function clearTrackErrors() {
  $("trackRows")
    .querySelectorAll(".start.invalid")
    .forEach((el) => el.classList.remove("invalid"));
}

// Highlighting the start-time fields of the exact rows missing a time.
function highlightMissingTimes(indices) {
  const rows = $("trackRows").querySelectorAll(".track-row");
  indices.forEach((i) => {
    const input = rows[i] && rows[i].querySelector(".start");
    if (input) input.classList.add("invalid");
  });
  const first = rows[indices[0]] && rows[indices[0]].querySelector(".start");
  if (first) first.focus();
}

function show(id) {
  $(id).classList.remove("hidden");
}

window.addEventListener("DOMContentLoaded", () => {
  $("resolveBtn").addEventListener("click", resolve);
  $("downloadBtn").addEventListener("click", download);
  $("aac256").addEventListener("change", updateDetected);
  $("split").addEventListener("change", updateSplitState);
  $("addTrackBtn").addEventListener("click", addTrack);
  $("parseBtn").addEventListener("click", parsePasted);
  $("fetch1001Btn").addEventListener("click", fetch1001);
  $("srcFetchBtn").addEventListener("click", () => setTlSource("fetch"));
  $("srcPasteBtn").addEventListener("click", () => setTlSource("paste"));
  $("url").addEventListener("keydown", (e) => {
    if (e.key === "Enter") resolve();
  });
  $("url1001").addEventListener("keydown", (e) => {
    if (e.key === "Enter") fetch1001();
  });
  updateSplitState();
  loadRecent();
});
