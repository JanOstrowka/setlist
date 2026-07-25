from __future__ import annotations

import asyncio
import os
import queue
import secrets
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import asynccontextmanager
from pathlib import Path
from uuid import uuid4

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from .config import APP_NAME, init_env, load_config
from .core import (
    downloader,
    library,
    metadata_ai,
    resolver,
    splitter,
    tagger,
    tracklist,
    tracklist_1001,
)
from .core.job_state import JobCancelled, JobRecord
from .models import (
    DownloadRequest,
    JobSnapshot,
    ProgressEvent,
    ResolveRequest,
    ResolveResponse,
    SplitDownloadRequest,
    Tracklist,
)

init_env()
cfg = load_config()

WEB_DIR = Path(__file__).resolve().parent.parent / "web"

# Completion-callback delivery policy (see JobManager._post_callback).
CALLBACK_ATTEMPTS = 3
CALLBACK_RETRY_DELAY = 2.0  # seconds between attempts; tests patch this to 0


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
        self.jobs: dict[str, JobRecord] = {}
        self.events: dict[str, "queue.Queue[ProgressEvent]"] = {}
        self.work: "queue.Queue[tuple[str, DownloadRequest]]" = queue.Queue()
        self._worker = threading.Thread(target=self._run, daemon=True)
        self._worker.start()

    def submit(self, req: "DownloadRequest | SplitDownloadRequest") -> str:
        job_id = uuid4().hex
        self.jobs[job_id] = JobRecord(job_id)
        self.events[job_id] = queue.Queue()
        self._emit(job_id, ProgressEvent(stage="queued", pct=0.0, message="Queued"))
        self.work.put((job_id, req))
        return job_id

    def get_queue(self, job_id: str) -> "queue.Queue[ProgressEvent]":
        if job_id not in self.events:
            raise KeyError(job_id)
        return self.events[job_id]

    def get_snapshot(self, job_id: str) -> JobSnapshot:
        if job_id not in self.jobs:
            raise KeyError(job_id)
        return self.jobs[job_id].snapshot()

    def _emit(self, job_id: str, event: ProgressEvent) -> None:
        self.jobs[job_id].update(event)
        self.events[job_id].put(event)

    def _run(self) -> None:
        while True:
            job_id, req = self.work.get()
            try:
                if isinstance(req, SplitDownloadRequest):
                    paths = self._process_split(job_id, req)
                else:
                    paths = self._process(job_id, req)
            except JobCancelled:
                record = self.jobs[job_id]
                record.mark_cancelled()
                self._emit(job_id, record.latest)
                self._post_callback(req, {
                    "job_id": job_id, "status": "cancelled", "output_paths": [], "error": "",
                })
            except Exception as exc:  # surface any pipeline failure to the UI
                message = resolver.augment_error(exc)
                record = self.jobs[job_id]
                record.fail(message)
                self._emit(job_id, record.latest)
                self._post_callback(req, {
                    "job_id": job_id, "status": "error", "output_paths": [], "error": message,
                })
            else:
                self.jobs[job_id].complete(paths)
                self._post_callback(req, {
                    "job_id": job_id, "status": "done", "output_paths": paths, "error": "",
                })

    def _post_callback(self, req: "DownloadRequest | SplitDownloadRequest", payload: dict) -> None:
        """Best-effort POST of a terminal-state summary to the request's callback_url.

        Lets remote orchestrators (e.g. an n8n Wait-node resume URL) learn that a
        job finished without holding an SSE connection open. Never raises: a dead
        or slow callback target must not crash the worker or fail the job. Retries
        cover the small race where the caller's resume webhook is not registered
        yet when a job finishes quickly.
        """
        url = (req.callback_url or "").strip()
        if not url:
            return
        for attempt in range(CALLBACK_ATTEMPTS):
            try:
                resp = httpx.post(url, json=payload, timeout=10.0)
                if resp.is_success:
                    return
            except Exception:
                pass
            if attempt < CALLBACK_ATTEMPTS - 1:
                time.sleep(CALLBACK_RETRY_DELAY)

    def _process(self, job_id: str, req: DownloadRequest) -> list[str]:
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

            dest = library.single_track_path(
                self.cfg.output_dir,
                req.metadata.album_artist,
                req.metadata.artist,
                req.metadata.album,
                req.metadata.title,
                req.video_id,
            )
            library.save(encoded, dest)
            library.write_cover(dest.parent, cover)
            library.record_recent(self.cfg.output_dir, {
                "path": str(dest),
                "title": req.metadata.title,
                "artist": req.metadata.artist,
                "album": req.metadata.album,
                "video_id": req.video_id,  # lets the UI show a YouTube thumbnail
            })
            self._emit(job_id, ProgressEvent(stage="done", pct=100.0, message="Saved", file_path=str(dest)))
            return [str(dest)]

    def _process_split(self, job_id: str, req: SplitDownloadRequest) -> list[str]:
        with tempfile.TemporaryDirectory(prefix="setlist-") as tmp:
            tmpdir = Path(tmp)

            self._emit(job_id, ProgressEvent(stage="download", pct=0.0, message="Starting download"))
            src = downloader.download_audio(
                req.url,
                tmpdir,
                lambda pct: self._emit(job_id, ProgressEvent(stage="download", pct=pct, message="Downloading full set")),
                self.cfg.pot_provider_url,
            )

            target = "ALAC (lossless)" if req.format == "alac" else "AAC 256 kbps"
            self._emit(job_id, ProgressEvent(stage="encode", pct=0.0, message=f"Encoding full set to {target}"))
            full = tmpdir / "full.m4a"
            downloader.encode(src, full, req.format)
            self._emit(job_id, ProgressEvent(stage="encode", pct=100.0, message="Encoded"))

            if req.cover == "keep":
                cover = resolver.read_cached_cover(req.video_id)
            else:
                try:
                    cover = resolver.to_square_jpeg(resolver.data_uri_to_bytes(req.cover))
                except Exception:
                    cover = None

            tracks = tracklist.normalize(req.tracks)
            if not tracks:
                raise RuntimeError("No valid tracks to split")
            if any(t.start is None for t in tracks):
                raise RuntimeError("Some tracks are missing start times; fill them in before splitting")

            total = len(tracks)
            self._emit(job_id, ProgressEvent(stage="split", pct=0.0, message=f"Splitting into {total} tracks"))
            cut_dir = tmpdir / "cuts"

            def on_track(i: int, n: int, title: str) -> None:
                self._emit(job_id, ProgressEvent(stage="split", pct=i / n * 100.0, message=f"Cut {i}/{n}: {title or 'Untitled'}"))

            files = splitter.split_file(full, tracks, cut_dir, on_track=on_track)

            self._emit(job_id, ProgressEvent(stage="tag", pct=0.0, message="Tagging album"))
            tagger.tag_album(files, tracks, req.metadata, cover)
            self._emit(job_id, ProgressEvent(stage="tag", pct=100.0, message="Tagged"))

            set_dir = library.set_output_dir(
                self.cfg.output_dir,
                req.metadata.album_artist,
                req.metadata.artist,
                req.metadata.album,
                req.metadata.title,
            )
            library.ensure_output_dir(set_dir)
            for f in files:
                library.save(f, set_dir / f.name)
            library.write_cover(set_dir, cover)
            library.record_recent(self.cfg.output_dir, {
                "path": str(set_dir),
                "title": req.metadata.album or req.metadata.title,
                "artist": req.metadata.album_artist or req.metadata.artist,
                "album": req.metadata.album,
                "video_id": req.video_id,  # lets the UI show a YouTube thumbnail
            })
            self._emit(job_id, ProgressEvent(stage="done", pct=100.0, message=f"Saved {total} tracks", file_path=str(set_dir)))
            return [str(set_dir / f.name) for f in files]


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

# Paths that stay public even when API auth is enabled: the UI shell and its
# assets carry no secrets, and the browser can't attach an Authorization header
# to plain page/asset loads anyway. /health is the hosted site's
# helper-detection ping; it reveals nothing beyond "the app is running".
PUBLIC_PATHS = {"/", "/favicon.ico", "/health"}


def _is_direct_local_request(request: Request) -> bool:
    """True for requests from this Mac's own browser hitting 127.0.0.1 directly.

    Tunnels (Tailscale serve/funnel, cloudflared, ngrok) proxy to loopback but
    always add an X-Forwarded-For header, so remote traffic can't look local:
    loopback + no forwarding header can only originate on this machine. This
    keeps the local web UI working without a token while the tunnel side of the
    same server requires one.
    """
    client = request.client
    return (
        client is not None
        and client.host in ("127.0.0.1", "::1")
        and "x-forwarded-for" not in request.headers
    )


@app.middleware("http")
async def require_bearer_token(request: Request, call_next):
    """Require `Authorization: Bearer <API_AUTH_TOKEN>` when the token is configured.

    With API_AUTH_TOKEN unset the app behaves exactly as before (open,
    loopback-only). With it set, every API route demands the token except the
    UI paths above and direct local requests (see _is_direct_local_request).
    """
    token = cfg.api_auth_token
    if token:
        path = request.url.path
        exempt = path in PUBLIC_PATHS or path.startswith("/static/") or _is_direct_local_request(request)
        if not exempt:
            supplied = request.headers.get("authorization", "")
            if not secrets.compare_digest(supplied.encode(), f"Bearer {token}".encode()):
                return JSONResponse(
                    status_code=401,
                    content={"detail": "Missing or invalid bearer token"},
                    headers={"WWW-Authenticate": "Bearer"},
                )
    return await call_next(request)


def _cors_headers(origin: str) -> dict[str, str]:
    return {
        "Access-Control-Allow-Origin": origin,
        # No cookies/credentials are used, so Allow-Credentials stays off and
        # the exact-origin echo (not "*") is only needed for config symmetry.
        "Vary": "Origin",
    }


# Registered after require_bearer_token so it wraps it (Starlette runs the
# last-added middleware first): preflights are answered before auth can 401
# them, and ACAO headers land on auth failures too, so the browser surfaces
# the real 401 instead of a masked CORS error.
@app.middleware("http")
async def cors_for_hosted_site(request: Request, call_next):
    """Hand-rolled CORS so the allowed origins come from live config.

    The hosted site (e.g. https://setlist.vercel.app) calls this server at
    127.0.0.1 straight from the browser. Only origins listed in CORS_ORIGINS
    are allowed; with the variable unset the app never emits a CORS header and
    cross-origin pages are blocked by the browser exactly as before.

    Also answers Chrome's Private Network Access preflight (a public HTTPS page
    fetching a loopback address sends Access-Control-Request-Private-Network;
    the response must opt in) so future Chrome enforcement doesn't break the
    site->helper path.
    """
    origin = request.headers.get("origin", "")
    allowed = origin.rstrip("/") in cfg.cors_origins if origin else False

    is_preflight = (
        request.method == "OPTIONS"
        and "access-control-request-method" in request.headers
    )
    if is_preflight:
        if not allowed:
            return Response(status_code=400, content="Origin not allowed")
        headers = _cors_headers(origin)
        headers.update({
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers":
                request.headers.get("access-control-request-headers", "Content-Type, Authorization"),
            "Access-Control-Max-Age": "600",
        })
        if request.headers.get("access-control-request-private-network", "").lower() == "true":
            headers["Access-Control-Allow-Private-Network"] = "true"
        return Response(status_code=204, headers=headers)

    response = await call_next(request)
    if allowed:
        response.headers.update(_cors_headers(origin))
    return response


class RevealRequest(BaseModel):
    path: str


class ParseTracklistRequest(BaseModel):
    text: str
    duration: int = 0


class AutoTracklistRequest(BaseModel):
    # `query` is normally the resolved video title; `url` is a fallback search term.
    query: str = ""
    url: str = ""
    duration: int = 0


@app.get("/")
def index() -> HTMLResponse:
    return HTMLResponse(render_index())


@app.get("/favicon.ico")
def favicon() -> Response:
    # Browsers auto-request /favicon.ico; return 204 to silence the 404 noise.
    return Response(status_code=204)


@app.get("/health")
def health_endpoint() -> dict:
    """Lightweight liveness ping for the hosted site's helper detection."""
    return {"status": "ok", "app": APP_NAME}


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
    tl = tracklist.build_tracklist(raw)
    return ResolveResponse(
        video_id=raw.video_id,
        duration=raw.duration,
        metadata=meta,
        cover=cover_uri,
        formats=raw.formats_summary,
        detected_line=line,
        has_chapters=raw.has_chapters,
        tracklist=tl,
    )


@app.post("/download")
def download_endpoint(req: DownloadRequest) -> dict:
    job_id = jobs.submit(req)
    return {"job_id": job_id}


@app.post("/parse-tracklist", response_model=Tracklist)
def parse_tracklist_endpoint(req: ParseTracklistRequest) -> Tracklist:
    text = (req.text or "").strip()
    # A pasted 1001tracklists URL is fetched + parsed via Firecrawl (Cloudflare-gated);
    # anything else is treated as a manually pasted tracklist as before.
    if tracklist_1001.is_1001_url(text):
        try:
            return tracklist_1001.parse_1001tracklists(text, cfg)
        except Exception as exc:
            raise HTTPException(
                status_code=400,
                detail=f"Could not fetch 1001tracklists: {resolver.augment_error(exc)}",
            )
    return tracklist.parse_manual_tracklist(req.text, req.duration or None)


@app.post("/auto-tracklist", response_model=Tracklist)
def auto_tracklist_endpoint(req: AutoTracklistRequest) -> Tracklist:
    """Best-effort auto-fetch of a 1001tracklists tracklist for a resolved set.

    Always returns 200 with a ``Tracklist`` (``source='none'`` when nothing is
    found or no Firecrawl key is configured) so the UI degrades quietly to manual
    entry instead of surfacing a blocking error.
    """
    query = (req.query or req.url or "").strip()
    if not query:
        return Tracklist(source="none", note="Nothing to search for yet.")
    return tracklist_1001.find_tracklist_for_youtube(query, cfg)


@app.post("/download-split")
def download_split_endpoint(req: SplitDownloadRequest) -> dict:
    if not req.tracks:
        raise HTTPException(status_code=400, detail="No tracks provided")
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
            if event.stage in ("done", "error", "cancelled"):
                break
        jobs.events.pop(job_id, None)

    headers = {"Cache-Control": "no-cache", "X-Accel-Buffering": "no", "Connection": "keep-alive"}
    return StreamingResponse(event_stream(), media_type="text/event-stream", headers=headers)


@app.get("/recent")
def recent_endpoint() -> list:
    return library.load_recent(cfg.output_dir)


@app.post("/reveal")
def reveal_endpoint(req: RevealRequest) -> dict:
    # The server listens on localhost, so any web page in the browser could POST
    # here (CSRF) to pop Finder on arbitrary files or probe paths. Only reveal
    # paths within the configured output dir. resolve() also collapses symlinks,
    # so a link inside the dir cannot be used to escape it.
    output_dir = cfg.output_dir.resolve()
    path = Path(req.path).resolve()
    if not path.is_relative_to(output_dir):
        raise HTTPException(status_code=403, detail="Path is outside the output directory")
    if not path.exists():
        raise HTTPException(status_code=404, detail="File not found")
    try:
        subprocess.run(["open", "-R", str(path)], check=False)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))
    return {"ok": True}
