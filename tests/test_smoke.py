import os
import shutil

import pytest
from mutagen.mp4 import MP4

from app.core import downloader, tagger
from app.core.resolver import resolve, fetch_thumbnail, to_square_jpeg
from app.models import MetadataFields

# Big Buck Bunny — Creative Commons.
CC_URL = os.getenv("SMOKE_URL", "https://www.youtube.com/watch?v=aqz-KE-bpKQ")


@pytest.mark.skipif(os.getenv("RUN_SMOKE") != "1", reason="set RUN_SMOKE=1 to run the network smoke test")
def test_end_to_end_download_encode_tag(tmp_path):
    if not shutil.which("ffmpeg"):
        pytest.skip("ffmpeg not installed")

    raw = resolve(CC_URL)
    src = downloader.download_audio(raw.url, tmp_path, lambda pct: None)

    out = tmp_path / "out.m4a"
    downloader.encode(src, out, "alac")

    cover = None
    if raw.thumbnail:
        cover = to_square_jpeg(fetch_thumbnail(raw.thumbnail))

    meta = MetadataFields(
        title=raw.title or "Smoke Test",
        artist=raw.uploader or "Smoke",
        album="Smoke Album",
        album_artist=raw.uploader or "Smoke",
        year=2025,
        genre="",
        comment=raw.url,
        compilation=False,
    )
    tagger.write_tags(out, meta, cover)

    audio = MP4(str(out))
    assert audio.info.length > 0
    assert audio["\xa9nam"][0]
    assert audio["pgap"] is True
    if cover:
        assert "covr" in audio
