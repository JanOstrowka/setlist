const $ = (id) => document.getElementById(id);
const state = { videoId: "", url: "", detectedAlac: "" };

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
    $("cover").src = data.cover || "";
    $("title").value = data.metadata.title || "";
    $("artist").value = data.metadata.artist || "";
    $("album").value = data.metadata.album || "";
    $("albumArtist").value = data.metadata.album_artist || "";
    $("year").value = data.metadata.year ?? "";
    $("genre").value = data.metadata.genre || "";
    $("compilation").checked = !!data.metadata.compilation;
    updateDetected();
    show("preview");
    setStatus("");
  } catch (err) {
    setStatus("Error: " + err.message, true);
  } finally {
    $("resolveBtn").disabled = false;
  }
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

async function download() {
  if (!state.videoId) return;
  const body = {
    video_id: state.videoId,
    url: state.url,
    format: $("aac256").checked ? "aac256" : "alac",
    cover: "keep",
    metadata: {
      title: $("title").value,
      artist: $("artist").value,
      album: $("album").value,
      album_artist: $("albumArtist").value,
      year: $("year").value ? parseInt($("year").value, 10) : null,
      genre: $("genre").value,
      comment: state.url,
      compilation: $("compilation").checked,
    },
  };
  $("downloadBtn").disabled = true;
  $("revealDone").style.display = "none";
  show("progress");
  setBar(0);
  setStatus("");
  $("progressMsg").textContent = "Starting…";
  try {
    const res = await fetch("/download", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error("Download request failed");
    const { job_id } = await res.json();
    const es = new EventSource(`/progress/${job_id}`);
    es.onmessage = (e) => {
      const ev = JSON.parse(e.data);
      $("progressMsg").textContent = `${ev.stage}: ${ev.message}`;
      if (["download", "encode", "tag"].includes(ev.stage)) setBar(ev.pct);
      if (ev.stage === "done") {
        setBar(100);
        es.close();
        onDone(ev.file_path);
      }
      if (ev.stage === "error") {
        es.close();
        setStatus("Error: " + ev.message, true);
        $("downloadBtn").disabled = false;
      }
    };
    es.onerror = () => {
      es.close();
      $("downloadBtn").disabled = false;
    };
  } catch (err) {
    setStatus("Error: " + err.message, true);
    $("downloadBtn").disabled = false;
  }
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

function show(id) {
  $(id).classList.remove("hidden");
}

window.addEventListener("DOMContentLoaded", () => {
  $("resolveBtn").addEventListener("click", resolve);
  $("downloadBtn").addEventListener("click", download);
  $("aac256").addEventListener("change", updateDetected);
  $("url").addEventListener("keydown", (e) => {
    if (e.key === "Enter") resolve();
  });
  loadRecent();
});
