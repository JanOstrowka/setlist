import dataclasses
import shutil
import subprocess
from io import BytesIO
from pathlib import Path

import pytest
from PIL import Image


def has_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


@pytest.fixture(autouse=True)
def _no_api_auth(monkeypatch):
    """Neutralize the developer's real .env during tests.

    app.main loads .env at import time, so a real API_AUTH_TOKEN there would
    401 every TestClient call, and a real CORS_ORIGINS would emit CORS headers
    the tests don't expect. Auth/CORS tests opt back in by replacing cfg with
    values of their own inside the test body (which runs after this fixture).
    """
    from app import main as main_module

    monkeypatch.setattr(
        main_module, "cfg",
        dataclasses.replace(main_module.cfg, api_auth_token=None, cors_origins=()),
    )


@pytest.fixture
def sample_jpeg() -> bytes:
    img = Image.new("RGB", (300, 300), (180, 40, 40))
    buf = BytesIO()
    img.save(buf, format="JPEG", quality=90)
    return buf.getvalue()


@pytest.fixture
def m4a_file(tmp_path) -> Path:
    """A tiny real .m4a (AAC) built with ffmpeg; skips if ffmpeg is unavailable."""
    if not has_ffmpeg():
        pytest.skip("ffmpeg not installed")
    out = tmp_path / "sample.m4a"
    subprocess.run(
        [
            "ffmpeg", "-y", "-f", "lavfi",
            "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
            "-t", "1", "-c:a", "aac", "-b:a", "64k", str(out),
        ],
        check=True, capture_output=True,
    )
    return out
