from __future__ import annotations

import asyncio
import os
import queue
import subprocess
import sys
import tempfile
import threading
from contextlib import asynccontextmanager
from pathlib import Path
from uuid import uuid4

from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .config import APP_NAME, init_env, load_config
from .core import downloader, library, metadata_ai, resolver, tagger
from .models import DownloadRequest, ProgressEvent, ResolveRequest, ResolveResponse

init_env()
cfg = load_config()

WEB_DIR = Path(__file__).resolve().parent.parent / "web"


def render_index() -> str:
    """Serve the SPA shell with the centralized product name injected.

    The brand lives in a single constant (APP_NAME); the static HTML carries an
    `__APP_NAME__` placeholder so a rename never touches markup or logic.
    """
    html = (WEB_DIR / "index.html").read_text(encoding="utf-8")
    return html.replace("__APP_NAME__", APP_NAME)


class JobManager:
    """Single-worker FIFO download queue with per-job event queues for SSE."""

    def __init__(self, config) -> None:
        self.cfg = config
        self.jobs: dict[str, "queue.Queue[ProgressEvent]"] = {}
        self.work: "queue.Queue[tuple[str, DownloadRequest]]" = queue.Queue()
        self._worker = threading.Thread(target=self._run, daemon=True)
        self._worker.start()

    def submit(self, req: DownloadRequest) -> str:
        job_id = uuid4().hex
        self.jobs[job_id] = queue.Queue()
        self._emit(job_id, ProgressEvent(stage="queued", pct=0.0, message="Queued"))
        self.work.put((job_id, req))
        return job_id

    def get_queue(self, job_id: str) -> "queue.Queue[ProgressEvent]":
        if job_id not in self.jobs:
            raise KeyError(job_id)
        return self.jobs[job_id]

    def _emit(self, job_id: str, event: ProgressEvent) -> None:
        self.jobs[job_id].put(event)

    def _run(self) -> None:
        while True:
            job_id, req = self.work.get()
            try:
                self._process(job_id, req)
            except Exception as exc:  # surface any pipeline failure to the UI
                self._emit(job_id, ProgressEvent(stage="error", pct=0.0, message=resolver.augment_error(exc)))

    def _process(self, job_id: str, req: DownloadRequest) -> None:
        with tempfile.TemporaryDirectory(prefix="setlist-") as tmp:
            tmpdir = Path(tmp)

            self._emit(job_id, ProgressEvent(stage="download", pct=0.0, message="Starting download"))
            src = downloader.download_audio(
                req.url,
                tmpdir,
                lambda pct: self._emit(job_id, ProgressEvent(stage="download", pct=pct, message="Downloading audio")),
                self.cfg.pot_provider_url,
            )

            target = "ALAC (lossless)" if req.format == "alac" else "AAC 256 kbps"
            self._emit(job_id, ProgressEvent(stage="encode", pct=0.0, message=f"Encoding to {target}"))
            encoded = tmpdir / "encoded.m4a"
            downloader.encode(src, encoded, req.format)
            self._emit(job_id, ProgressEvent(stage="encode", pct=100.0, message="Encoded"))

            if req.cover == "keep":
                cover = resolver.read_cached_cover(req.video_id)
            else:
                try:
                    cover = resolver.to_square_jpeg(resolver.data_uri_to_bytes(req.cover))
                except Exception:
                    cover = None

            self._emit(job_id, ProgressEvent(stage="tag", pct=0.0, message="Writing tags"))
            tagger.write_tags(encoded, req.metadata, cover)
            self._emit(job_id, ProgressEvent(stage="tag", pct=100.0, message="Tags written"))

            library.ensure_output_dir(self.cfg.output_dir)
            dest = library.output_path(
                self.cfg.output_dir,
                req.metadata.album_artist or req.metadata.artist,
                req.metadata.title,
                req.video_id,
            )
            library.save(encoded, dest)
            library.record_recent(self.cfg.output_dir, {
                "path": str(dest),
                "title": req.metadata.title,
                "artist": req.metadata.artist,
                "album": req.metadata.album,
            })
            self._emit(job_id, ProgressEvent(stage="done", pct=100.0, message="Saved", file_path=str(dest)))


def _self_update_yt_dlp() -> None:
    try:
        subprocess.run(
            [sys.executable, "-m", "pip", "install", "-U", "--quiet", "yt-dlp"],
            check=False, capture_output=True, timeout=180,
        )
    except Exception:
        pass


@asynccontextmanager
async def lifespan(_app: FastAPI):
    if os.getenv("YT_DLP_SELF_UPDATE", "1") == "1":
        threading.Thread(target=_self_update_yt_dlp, daemon=True).start()
    yield


app = FastAPI(title=APP_NAME, lifespan=lifespan)
jobs = JobManager(cfg)
app.mount("/static", StaticFiles(directory=str(WEB_DIR)), name="static")


class RevealRequest(BaseModel):
    path: str


@app.get("/")
def index() -> HTMLResponse:
    return HTMLResponse(render_index())


@app.get("/favicon.ico")
def favicon() -> Response:
    # Browsers auto-request /favicon.ico; return 204 to silence the 404 noise.
    return Response(status_code=204)


@app.post("/resolve", response_model=ResolveResponse)
def resolve_endpoint(req: ResolveRequest) -> ResolveResponse:
    try:
        raw = resolver.resolve(req.url)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Could not resolve URL: {resolver.augment_error(exc)}")

    meta = metadata_ai.propose_metadata(raw, cfg)

    cover_uri = ""
    if raw.thumbnail:
        try:
            jpeg = resolver.to_square_jpeg(resolver.fetch_thumbnail(raw.thumbnail))
            resolver.cache_cover_jpeg(raw.video_id, jpeg)
            cover_uri = resolver.jpeg_to_data_uri(jpeg)
        except Exception:
            cover_uri = ""

    line = resolver.detected_line(raw.best_audio_label, cfg.default_format, str(cfg.output_dir))
    return ResolveResponse(
        video_id=raw.video_id,
        duration=raw.duration,
        metadata=meta,
        cover=cover_uri,
        formats=raw.formats_summary,
        detected_line=line,
        has_chapters=raw.has_chapters,
    )


@app.post("/download")
def download_endpoint(req: DownloadRequest) -> dict:
    job_id = jobs.submit(req)
    return {"job_id": job_id}


@app.get("/progress/{job_id}")
async def progress_endpoint(job_id: str) -> StreamingResponse:
    try:
        q = jobs.get_queue(job_id)
    except KeyError:
        raise HTTPException(status_code=404, detail="Unknown job")

    async def event_stream():
        while True:
            try:
                event = q.get_nowait()
            except queue.Empty:
                await asyncio.sleep(0.1)
                continue
            yield f"data: {event.model_dump_json()}\n\n"
            if event.stage in ("done", "error"):
                break
        jobs.jobs.pop(job_id, None)

    headers = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no", "Connection": "keep-alive"}
    return StreamingResponse(event_stream(), media_type="text/event-stream", headers=headers)


@app.get("/recent")
def recent_endpoint() -> list:
    return library.load_recent(cfg.output_dir)


@app.post("/reveal")
def reveal_endpoint(req: RevealRequest) -> dict:
    path = Path(req.path)
    if not path.exists():
        raise HTTPException(status_code=404, detail="File not found")
    try:
        subprocess.run(["open", "-R", str(path)], check=False)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return {"ok": True}
