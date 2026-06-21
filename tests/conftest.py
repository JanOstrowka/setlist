import shutil
import subprocess
from io import BytesIO
from pathlib import Path

import pytest
from PIL import Image


def has_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


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
