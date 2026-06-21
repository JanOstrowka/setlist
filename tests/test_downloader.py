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
