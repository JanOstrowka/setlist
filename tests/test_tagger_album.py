import shutil
import subprocess
from pathlib import Path

import pytest
from mutagen.mp4 import MP4

from app.core.tagger import tag_album
from app.models import MetadataFields, Track


def _has_ffmpeg() -> bool:
    return shutil.which("ffmpeg") is not None


@pytest.fixture
def three_m4a(tmp_path) -> list[Path]:
    if not _has_ffmpeg():
        pytest.skip("ffmpeg not installed")
    files = []
    for i in range(3):
        out = tmp_path / f"{i}.m4a"
        subprocess.run(
            [
                "ffmpeg", "-y", "-f", "lavfi",
                "-i", "anullsrc=channel_layout=stereo:sample_rate=44100",
                "-t", "1", "-c:a", "aac", "-b:a", "64k", str(out),
            ],
            check=True, capture_output=True,
        )
        files.append(out)
    return files


def test_tag_album_various_artists_sets_compilation(three_m4a):
    tracks = [
        Track(start=0, title="One", artist="A"),
        Track(start=10, title="Two", artist="B"),
        Track(start=20, title="Three", artist="A"),
    ]
    album = MetadataFields(album="Live Set", album_artist="DJ X", year=2025,
                           genre="Electronic", comment="https://youtu.be/x")
    tag_album(three_m4a, tracks, album, cover_jpeg=None)
    for i, f in enumerate(three_m4a, start=1):
        a = MP4(str(f))
        assert a["\xa9alb"] == ["Live Set"]
        assert a["aART"] == ["DJ X"]
        assert a["trkn"][0] == (i, 3)
        assert a["disk"][0] == (1, 1)
        assert a["pgap"] is True
        assert a["cpil"] is True  # track artists differ → various-artists set
        assert a["\xa9cmt"] == ["https://youtu.be/x"]
    first = MP4(str(three_m4a[0]))
    assert first["\xa9nam"] == ["One"]
    assert first["\xa9ART"] == ["A"]


def test_tag_album_single_artist_not_compilation(three_m4a):
    tracks = [Track(start=0, title="One", artist="A"),
              Track(start=10, title="Two", artist="A"),
              Track(start=20, title="Three", artist="A")]
    album = MetadataFields(album="Live Set", album_artist="A")
    tag_album(three_m4a, tracks, album)
    for f in three_m4a:
        assert MP4(str(f))["cpil"] is False


def test_tag_album_track_artist_falls_back_to_album_artist(three_m4a):
    tracks = [Track(start=0, title="One"), Track(start=10, title="Two"), Track(start=20, title="Three")]
    album = MetadataFields(album="Live Set", album_artist="DJ X")
    tag_album(three_m4a, tracks, album)
    for f in three_m4a:
        assert MP4(str(f))["\xa9ART"] == ["DJ X"]
