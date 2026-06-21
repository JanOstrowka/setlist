from mutagen.mp4 import MP4, MP4Cover

from app.core.tagger import write_tags
from app.models import MetadataFields


def test_write_tags_roundtrip(m4a_file, sample_jpeg):
    meta = MetadataFields(
        title="Sunset Set",
        artist="DJ Test",
        album="Tomorrowland 2025",
        album_artist="DJ Test",
        year=2025,
        genre="Electronic",
        comment="https://youtu.be/abc123",
        compilation=False,
    )
    write_tags(m4a_file, meta, sample_jpeg)

    audio = MP4(str(m4a_file))
    assert audio["\xa9nam"] == ["Sunset Set"]
    assert audio["\xa9ART"] == ["DJ Test"]
    assert audio["\xa9alb"] == ["Tomorrowland 2025"]
    assert audio["aART"] == ["DJ Test"]
    assert audio["\xa9day"] == ["2025"]
    assert audio["\xa9gen"] == ["Electronic"]
    assert audio["\xa9cmt"] == ["https://youtu.be/abc123"]
    assert audio["trkn"] == [(1, 1)]
    assert audio["disk"] == [(1, 1)]
    assert audio["pgap"] is True
    assert audio["cpil"] is False
    cover = audio["covr"][0]
    assert cover.imageformat == MP4Cover.FORMAT_JPEG
    assert bytes(cover) == sample_jpeg


def test_write_tags_compilation_true(m4a_file):
    meta = MetadataFields(title="VA Set", artist="Various", album="Fest", album_artist="Various Artists", compilation=True)
    write_tags(m4a_file, meta, None)
    audio = MP4(str(m4a_file))
    assert audio["cpil"] is True
    assert "covr" not in audio
