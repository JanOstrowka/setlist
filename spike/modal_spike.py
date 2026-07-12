"""Modal feasibility spike: can the Setlist engine run YouTube -> ALAC in the cloud?

The decisive unknown is whether YouTube serves audio to Modal's datacenter
egress IPs, or bot-blocks them ("Sign in to confirm you're not a bot", 403,
429). This spike answers that with a real download, reusing the repo's
`app.core` engine (resolver -> downloader -> encode -> tagger) instead of
reimplementing it.

Run (after `modal setup`; see spike/README.md):

    modal run spike/modal_spike.py --url "https://www.youtube.com/watch?v=..."
    modal run spike/modal_spike.py --url "..." --use-cookies

Optional Modal Secrets (attached automatically when they exist):
  - r2-credentials:  R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY / R2_BUCKET
                     -> uploads the 60s ALAC sample to Cloudflare R2 + presigned GET URL
  - youtube-cookies: YOUTUBE_COOKIES_TXT (contents of a cookies.txt export)
                     -> passed to yt-dlp as a cookiefile when --use-cookies is set
"""

from __future__ import annotations

import time

import modal

# Only the first 60s is transcoded: enough to prove download + ffmpeg ALAC work
# without paying for a full-set encode.
SAMPLE_SECONDS = 60

# "Me at the zoo" - public, short, never region-locked; a good canary.
DEFAULT_TEST_URL = "https://www.youtube.com/watch?v=jNQXAC9IVRw"

# Substrings that mark a YouTube bot/rate check (mirrors app.core.resolver.augment_error).
BOT_BLOCK_TRIGGERS = ("sign in", "bot", "confirm you", "403", "429", "rate", "captcha", "not a bot")

# yt-dlp is intentionally unpinned: YouTube breakage is usually fixed by the
# latest release, and image layers are cached anyway (refresh with
# MODAL_FORCE_BUILD=1). add_local_python_source must stay the last layer: it
# adds files at container start, so no build steps may follow it.
image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("ffmpeg")
    .uv_pip_install(
        "yt-dlp",
        "mutagen>=1.47",
        "pillow>=10.2",
        "httpx>=0.27",
        "pydantic>=2.6",
        "boto3>=1.34",
    )
    .add_local_python_source("app")
)

spike_app = modal.App("setlist-modal-spike")


def _optional_secrets() -> list[modal.Secret]:
    """Attach r2-credentials / youtube-cookies only if they exist in the workspace.

    Secret.from_name is lazy; a missing secret would only fail at run time.
    Probing with .hydrate() at local build time lets the spike run with zero
    secrets configured. Inside the container (or when unauthenticated, e.g.
    plain `import`), we skip probing: env vars are already injected there.
    """
    if not modal.is_local():
        return []
    found = []
    for name in ("r2-credentials", "youtube-cookies"):
        try:
            secret = modal.Secret.from_name(name)
            secret.hydrate()
            found.append(secret)
        except Exception:
            pass
    return found


@spike_app.function(image=image, secrets=_optional_secrets(), timeout=2 * 60 * 60)
def spike_download(url: str, use_cookies: bool = False) -> dict:
    """Run the pipeline once and report per-stage outcomes (never raises)."""
    import os
    import tempfile
    from pathlib import Path

    import httpx
    import yt_dlp

    from app.core import downloader, resolver, tagger
    from app.models import MetadataFields

    report: dict = {
        "stages": [],
        "egress_ip": "",
        "bot_blocked": False,
        "presigned_url": "",
        "used_cookies": use_cookies,
        "yt_dlp_version": yt_dlp.version.__version__,
    }

    def record(name: str, ok: bool, started: float | None, detail: str) -> None:
        report["stages"].append({
            "stage": name,
            "ok": ok,
            "seconds": round(time.monotonic() - started, 1) if started is not None else 0.0,
            "detail": detail,
        })

    def fail(name: str, started: float | None, exc: Exception) -> None:
        message = resolver.augment_error(exc)
        if any(t in message.lower() for t in BOT_BLOCK_TRIGGERS):
            report["bot_blocked"] = True
        record(name, False, started, message)

    def mb(path: Path) -> str:
        return f"{path.stat().st_size / 1_048_576:.1f} MB"

    # --- egress IP: which IP YouTube sees (the whole point of the spike) ---
    started = time.monotonic()
    try:
        ip = httpx.get("https://api.ipify.org", timeout=15).text.strip()
        report["egress_ip"] = ip
        record("egress-ip", True, started, f"container egress IP: {ip}")
    except Exception as exc:
        record("egress-ip", False, started, f"IP echo failed (non-fatal): {exc}")

    # --- cookies (optional) ---
    cookiefile: Path | None = None
    if use_cookies:
        raw = os.environ.get("YOUTUBE_COOKIES_TXT", "")
        if raw:
            cookiefile = Path(tempfile.gettempdir()) / "youtube-cookies.txt"
            cookiefile.write_text(raw)
            record("cookies", True, None, f"cookiefile written ({len(raw)} bytes) from secret 'youtube-cookies'")
        else:
            record("cookies", False, None,
                   "--use-cookies set but secret 'youtube-cookies' (key YOUTUBE_COOKIES_TXT) is missing; "
                   "proceeding WITHOUT cookies")

    workdir = Path(tempfile.mkdtemp(prefix="spike-"))

    # --- resolve: metadata via app.core.resolver ---
    started = time.monotonic()
    try:
        info = resolver.resolve(url, cookiefile=cookiefile)
        record("resolve", True, started,
               f"'{info.title}' by {info.uploader} · {info.duration}s · {info.best_audio_label}")
    except Exception as exc:
        fail("resolve", started, exc)
        return report

    # --- download: bestaudio via app.core.downloader (the decisive stage) ---
    started = time.monotonic()
    try:
        src = downloader.download_audio(url, workdir, on_progress=lambda pct: None, cookiefile=cookiefile)
        record("download", True, started, f"bestaudio -> {src.name} ({mb(src)})")
    except Exception as exc:
        fail("download", started, exc)
        return report

    # --- encode: first SAMPLE_SECONDS to ALAC via app.core.downloader.encode ---
    started = time.monotonic()
    sample = workdir / "sample-alac.m4a"
    try:
        downloader.encode(src, sample, "alac", limit_seconds=SAMPLE_SECONDS)
        record("encode", True, started, f"first {SAMPLE_SECONDS}s -> ALAC ({mb(sample)})")
    except Exception as exc:
        fail("encode", started, exc)
        return report

    # --- tag: minimal MP4 atoms via app.core.tagger ---
    started = time.monotonic()
    try:
        tagger.write_tags(sample, MetadataFields(
            title=f"{info.title} (60s spike sample)",
            artist=info.uploader or "Unknown",
            album="Modal Spike",
            comment=url,
        ))
        record("tag", True, started, "MP4 atoms written (title/artist/album)")
    except Exception as exc:
        fail("tag", started, exc)
        return report

    # --- R2 upload (optional): only when the r2-credentials secret is attached ---
    r2_keys = ("R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET")
    if all(os.environ.get(k) for k in r2_keys):
        started = time.monotonic()
        try:
            import boto3
            from botocore.config import Config

            s3 = boto3.client(
                "s3",
                endpoint_url=f"https://{os.environ['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
                aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
                aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
                region_name="auto",
                config=Config(signature_version="s3v4"),
            )
            bucket = os.environ["R2_BUCKET"]
            key = f"spike/{info.video_id}-sample.m4a"
            s3.upload_file(str(sample), bucket, key)
            presigned = s3.generate_presigned_url(
                "get_object", Params={"Bucket": bucket, "Key": key}, ExpiresIn=3600,
            )
            report["presigned_url"] = presigned
            record("r2-upload", True, started, f"s3://{bucket}/{key} · presigned GET valid 1h")
        except Exception as exc:
            record("r2-upload", False, started, f"R2 upload failed: {exc}")
    else:
        record("r2-upload", True, None, "skipped: secret 'r2-credentials' not configured (optional)")

    return report


def _verdict(report: dict) -> str:
    stages = {s["stage"]: s for s in report["stages"]}
    download = stages.get("download")
    if download and download["ok"]:
        if report["used_cookies"]:
            return ("WORKS WITH COOKIES - YouTube accepts Modal's egress IPs only with a signed-in "
                    "session. Build the worker with the 'youtube-cookies' secret wired in.")
        return ("GREEN LIGHT - plain yt-dlp works from Modal's egress IPs. "
                "Build the cloud worker as planned.")
    if report["bot_blocked"]:
        if not report["used_cookies"]:
            return ("BOT-BLOCKED - YouTube rejected the datacenter IP. "
                    "Retry with cookies: create the 'youtube-cookies' secret (see spike/README.md), "
                    "then run again with --use-cookies.")
        return ("BLOCKED EVEN WITH COOKIES - evaluate a residential proxy or a PO-token provider "
                "before building (the engine already has a POT_PROVIDER_URL hook in app.core).")
    return "FAILED for a non-bot reason - read the stage details above before drawing conclusions."


@spike_app.local_entrypoint()
def main(url: str = DEFAULT_TEST_URL, use_cookies: bool = False) -> None:
    print(f"Running spike against: {url}  (cookies: {'on' if use_cookies else 'off'})")
    report = spike_download.remote(url, use_cookies=use_cookies)

    print()
    print(f"{'STAGE':<12} {'RESULT':<8} {'TIME':>8}  DETAIL")
    print("-" * 100)
    for s in report["stages"]:
        outcome = "ok" if s["ok"] else "FAIL"
        print(f"{s['stage']:<12} {outcome:<8} {s['seconds']:>7.1f}s  {s['detail']}")
    print("-" * 100)
    print(f"egress IP: {report['egress_ip'] or 'unknown'} · yt-dlp {report['yt_dlp_version']}")
    if report["presigned_url"]:
        print(f"R2 sample download (1h): {report['presigned_url']}")
    print()
    print(f"VERDICT: {_verdict(report)}")
