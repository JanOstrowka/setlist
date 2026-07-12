"""Modal feasibility spike: can the Setlist engine run YouTube -> ALAC in the cloud?

The decisive unknown is whether YouTube serves audio to Modal's datacenter
egress IPs, or bot-blocks them ("Sign in to confirm you're not a bot", 403,
429). This spike answers that with a real download, reusing the repo's
`app.core` engine (resolver -> downloader -> encode -> tagger) instead of
reimplementing it.

Run (after `modal setup`; see spike/README.md):

    modal run spike/modal_spike.py --url "https://www.youtube.com/watch?v=..."
    modal run spike/modal_spike.py --url "..." --pot          # PO-token provider
    modal run spike/modal_spike.py --url "..." --use-cookies  # cookie fallback

--pot runs the bgutil PO-token provider (Brainicism/bgutil-ytdlp-pot-provider)
as a sidecar inside the container: a Node.js HTTP server on 127.0.0.1:4416 that
yt-dlp's bgutil plugin queries for proof-of-origin tokens. This is the
credential-free route around YouTube's datacenter-IP bot checks.

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

# bgutil provider: pin server clone + pip plugin to the same release (README:
# "Replace with the latest version or the one that matches the plugin").
POT_PROVIDER_VERSION = "1.3.1"
# Default port: at 127.0.0.1:4416 the plugin needs no extractor args at all,
# which also covers the resolve stage (resolver.resolve has no pot hook).
POT_BASE_URL = "http://127.0.0.1:4416"

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

# --pot image: base + Node.js 22 (provider needs >=20; Debian's apt ships 18),
# the bgutil provider server (cloned + built at a pinned tag), and the pip
# plugin that teaches yt-dlp to fetch PO tokens from it.
pot_image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("ffmpeg", "git", "curl", "ca-certificates", "gnupg")
    .run_commands(
        "curl -fsSL https://deb.nodesource.com/setup_22.x | bash -",
        "apt-get install -y nodejs",
        "git clone --single-branch --branch " + POT_PROVIDER_VERSION + " --depth 1 "
        "https://github.com/Brainicism/bgutil-ytdlp-pot-provider.git /opt/bgutil-provider",
        "cd /opt/bgutil-provider/server && npm ci && npx tsc",
    )
    .uv_pip_install(
        "yt-dlp",
        "bgutil-ytdlp-pot-provider==" + POT_PROVIDER_VERSION,
        "mutagen>=1.47",
        "pillow>=10.2",
        "httpx>=0.27",
        "pydantic>=2.6",
        "boto3>=1.34",
    )
    .add_local_python_source("app")
)

spike_app = modal.App("setlist-modal-spike")


# (secret name, sentinel env key) pairs; order matters, see _optional_secrets.
_SECRET_PROBES = (("r2-credentials", "R2_ACCOUNT_ID"), ("youtube-cookies", "YOUTUBE_COOKIES_TXT"))


def _optional_secrets() -> list[modal.Secret]:
    """Attach r2-credentials / youtube-cookies only if they exist in the workspace.

    Secret.from_name is lazy; a missing secret would only fail at run time, so
    locally we probe with .hydrate() to allow running with zero secrets
    configured. The container re-evaluates this module and Modal matches the
    function's dependency list positionally against the locally-defined one, so
    remotely we must return the SAME list -- returning [] crash-loops the
    container as soon as any secret exists. Secret env vars are injected before
    user code is imported, so their presence tells us which secrets were
    attached.
    """
    import os

    if not modal.is_local():
        return [
            modal.Secret.from_name(name)
            for name, env_key in _SECRET_PROBES
            if os.environ.get(env_key)
        ]
    found = []
    for name, _ in _SECRET_PROBES:
        try:
            secret = modal.Secret.from_name(name)
            secret.hydrate()
            found.append(secret)
        except Exception:
            pass
    return found


def _new_report(use_cookies: bool, use_pot: bool) -> dict:
    import yt_dlp

    return {
        "stages": [],
        "egress_ip": "",
        "bot_blocked": False,
        "presigned_url": "",
        "used_cookies": use_cookies,
        "used_pot": use_pot,
        "yt_dlp_version": yt_dlp.version.__version__,
    }


def _record(report: dict, name: str, ok: bool, started: float | None, detail: str) -> None:
    report["stages"].append({
        "stage": name,
        "ok": ok,
        "seconds": round(time.monotonic() - started, 1) if started is not None else 0.0,
        "detail": detail,
    })


def _fail(report: dict, name: str, started: float | None, exc: Exception) -> None:
    from app.core import resolver

    message = resolver.augment_error(exc)
    if any(t in message.lower() for t in BOT_BLOCK_TRIGGERS):
        report["bot_blocked"] = True
    _record(report, name, False, started, message)


def _start_pot_provider(report: dict) -> bool:
    """Launch the bgutil Node server and poll /ping until healthy (or fail the stage)."""
    import json
    import subprocess
    from importlib.metadata import version as pkg_version
    from pathlib import Path

    import httpx

    started = time.monotonic()
    log_path = Path("/tmp/bgutil-provider.log")
    try:
        log = log_path.open("w")
        subprocess.Popen(
            ["node", "/opt/bgutil-provider/server/build/main.js"],
            stdout=log, stderr=subprocess.STDOUT,
        )
        ping: dict = {}
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                resp = httpx.get(POT_BASE_URL + "/ping", timeout=2)
                if resp.status_code == 200:
                    ping = resp.json()
                    break
            except Exception:
                pass
            time.sleep(0.5)
        else:
            raise RuntimeError(
                f"provider not healthy after 30s; log tail: {log_path.read_text()[-400:]!r}"
            )
        _record(
            report, "pot-provider", True, started,
            f"bgutil server {ping.get('version', '?')} healthy at {POT_BASE_URL} "
            f"(plugin {pkg_version('bgutil-ytdlp-pot-provider')}) · ping: {json.dumps(ping)}",
        )
        return True
    except Exception as exc:
        _record(report, "pot-provider", False, started, f"provider failed to start: {exc}")
        return False


def _run_pipeline(report: dict, url: str, use_cookies: bool, pot_base_url: str | None) -> dict:
    """Run the engine once, recording per-stage outcomes (never raises)."""
    import os
    import tempfile
    from pathlib import Path

    import httpx

    from app.core import downloader, resolver, tagger
    from app.models import MetadataFields

    def mb(path: Path) -> str:
        return f"{path.stat().st_size / 1_048_576:.1f} MB"

    # --- egress IP: which IP YouTube sees (the whole point of the spike) ---
    started = time.monotonic()
    try:
        ip = httpx.get("https://api.ipify.org", timeout=15).text.strip()
        report["egress_ip"] = ip
        _record(report, "egress-ip", True, started, f"container egress IP: {ip}")
    except Exception as exc:
        _record(report, "egress-ip", False, started, f"IP echo failed (non-fatal): {exc}")

    # --- cookies (optional) ---
    cookiefile: Path | None = None
    if use_cookies:
        raw = os.environ.get("YOUTUBE_COOKIES_TXT", "")
        if raw:
            cookiefile = Path(tempfile.gettempdir()) / "youtube-cookies.txt"
            cookiefile.write_text(raw)
            _record(report, "cookies", True, None,
                    f"cookiefile written ({len(raw)} bytes) from secret 'youtube-cookies'")
        else:
            _record(report, "cookies", False, None,
                    "--use-cookies set but secret 'youtube-cookies' (key YOUTUBE_COOKIES_TXT) is missing; "
                    "proceeding WITHOUT cookies")

    workdir = Path(tempfile.mkdtemp(prefix="spike-"))

    # --- resolve: metadata via app.core.resolver ---
    # No pot hook needed here: with the provider on the default port, the bgutil
    # plugin auto-detects it for every yt-dlp call in this process.
    started = time.monotonic()
    try:
        info = resolver.resolve(url, cookiefile=cookiefile)
        _record(report, "resolve", True, started,
                f"'{info.title}' by {info.uploader} · {info.duration}s · {info.best_audio_label}")
    except Exception as exc:
        _fail(report, "resolve", started, exc)
        return report

    # --- download: bestaudio via app.core.downloader (the decisive stage) ---
    started = time.monotonic()
    try:
        src = downloader.download_audio(
            url, workdir, on_progress=lambda pct: None,
            pot_provider_url=pot_base_url, cookiefile=cookiefile,
        )
        _record(report, "download", True, started, f"bestaudio -> {src.name} ({mb(src)})")
    except Exception as exc:
        _fail(report, "download", started, exc)
        return report

    # --- encode: first SAMPLE_SECONDS to ALAC via app.core.downloader.encode ---
    started = time.monotonic()
    sample = workdir / "sample-alac.m4a"
    try:
        downloader.encode(src, sample, "alac", limit_seconds=SAMPLE_SECONDS)
        _record(report, "encode", True, started, f"first {SAMPLE_SECONDS}s -> ALAC ({mb(sample)})")
    except Exception as exc:
        _fail(report, "encode", started, exc)
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
        _record(report, "tag", True, started, "MP4 atoms written (title/artist/album)")
    except Exception as exc:
        _fail(report, "tag", started, exc)
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
            _record(report, "r2-upload", True, started, f"s3://{bucket}/{key} · presigned GET valid 1h")
        except Exception as exc:
            _record(report, "r2-upload", False, started, f"R2 upload failed: {exc}")
    else:
        _record(report, "r2-upload", True, None, "skipped: secret 'r2-credentials' not configured (optional)")

    return report


@spike_app.function(image=image, secrets=_optional_secrets(), timeout=2 * 60 * 60)
def spike_download(url: str, use_cookies: bool = False) -> dict:
    report = _new_report(use_cookies, use_pot=False)
    return _run_pipeline(report, url, use_cookies, pot_base_url=None)


@spike_app.function(image=pot_image, secrets=_optional_secrets(), timeout=2 * 60 * 60)
def spike_download_pot(url: str, use_cookies: bool = False) -> dict:
    report = _new_report(use_cookies, use_pot=True)
    if not _start_pot_provider(report):
        return report
    return _run_pipeline(report, url, use_cookies, pot_base_url=POT_BASE_URL)


def _verdict(report: dict) -> str:
    stages = {s["stage"]: s for s in report["stages"]}
    download = stages.get("download")
    if download and download["ok"]:
        if report.get("used_pot") and not report["used_cookies"]:
            return ("GREEN LIGHT (PO TOKENS) - credential-free downloads work from Modal's egress "
                    "IPs with the bgutil PO-token provider sidecar. Bake the provider + plugin "
                    "into the production worker image.")
        if report["used_cookies"]:
            return ("WORKS WITH COOKIES - YouTube accepts Modal's egress IPs only with a signed-in "
                    "session. Build the worker with the 'youtube-cookies' secret wired in.")
        return ("GREEN LIGHT - plain yt-dlp works from Modal's egress IPs. "
                "Build the cloud worker as planned.")
    if report["bot_blocked"]:
        if report.get("used_pot"):
            return ("BLOCKED EVEN WITH PO TOKENS - next fallbacks: residential proxy "
                    "(~$2-8/mo; yt-dlp 'proxy' option) or cookies (--use-cookies with the "
                    "'youtube-cookies' secret).")
        if not report["used_cookies"]:
            return ("BOT-BLOCKED - YouTube rejected the datacenter IP. "
                    "Retry credential-free with --pot (bgutil PO-token provider), or with "
                    "--use-cookies (see spike/README.md).")
        return ("BLOCKED EVEN WITH COOKIES - evaluate a residential proxy or the --pot route "
                "before building.")
    return "FAILED for a non-bot reason - read the stage details above before drawing conclusions."


@spike_app.local_entrypoint()
def main(url: str = DEFAULT_TEST_URL, use_cookies: bool = False, pot: bool = False) -> None:
    mode = "pot" if pot else ("cookies" if use_cookies else "plain")
    print(f"Running spike against: {url}  (mode: {mode})")
    fn = spike_download_pot if pot else spike_download
    report = fn.remote(url, use_cookies=use_cookies)

    print()
    print(f"{'STAGE':<14} {'RESULT':<8} {'TIME':>8}  DETAIL")
    print("-" * 100)
    for s in report["stages"]:
        outcome = "ok" if s["ok"] else "FAIL"
        print(f"{s['stage']:<14} {outcome:<8} {s['seconds']:>7.1f}s  {s['detail']}")
    print("-" * 100)
    print(f"egress IP: {report['egress_ip'] or 'unknown'} · yt-dlp {report['yt_dlp_version']}")
    if report["presigned_url"]:
        print(f"R2 sample download (1h): {report['presigned_url']}")
    print()
    print(f"VERDICT: {_verdict(report)}")
