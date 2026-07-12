from mutagen.mp4 import MP4

from app.core.downloader import encode


def test_encode_to_alac(m4a_file, tmp_path):
    dest = tmp_path / "out_alac.m4a"
    encode(m4a_file, dest, "alac")
    assert dest.exists() and dest.stat().st_size > 0
    assert MP4(str(dest)).info.length > 0


def test_encode_to_aac256(m4a_file, tmp_path):
    dest = tmp_path / "out_aac.m4a"
    encode(m4a_file, dest, "aac256")
    assert dest.exists() and dest.stat().st_size > 0
    assert MP4(str(dest)).info.length > 0


def test_encode_limit_seconds_truncates(m4a_file, tmp_path):
    # The fixture is 1s long; limiting to 0.5s must shorten the output.
    dest = tmp_path / "out_limited.m4a"
    encode(m4a_file, dest, "alac", limit_seconds=0.5)
    assert dest.exists() and dest.stat().st_size > 0
    assert MP4(str(dest)).info.length <= 0.75
