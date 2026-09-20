from app.core.resolver import RawInfo
from app.core.metadata import clean_title, parse_title_fallback, propose_metadata


def _raw(**overrides) -> RawInfo:
    base = dict(
        video_id="abc123",
        url="https://youtu.be/abc123",
        title="",
        description="",
        uploader="Some Channel",
        upload_date="20240115",
        thumbnail="",
        duration=3600,
        has_chapters=False,
        best_audio_label="251 · opus · ~160 kbps",
        formats_summary="",
    )
    base.update(overrides)
    return RawInfo(**base)


def test_clean_title_strips_noise():
    assert clean_title("Artist - Track [Official Video]") == "Artist - Track"
    assert clean_title("Big Set (Official Audio)") == "Big Set"
    assert clean_title("Name (Official Music Video)") == "Name"


def test_parse_title_fallback_splits_artist_and_title():
    raw = _raw(title="DJ Test - Sunset Set [Official Video]")
    meta = parse_title_fallback(raw)
    assert meta.artist == "DJ Test"
    assert meta.title == "Sunset Set"
    assert meta.album == "DJ Test - Sunset Set"
    assert meta.album_artist == "DJ Test"
    assert meta.year == 2024
    assert meta.comment == "https://youtu.be/abc123"


def test_parse_title_fallback_uses_uploader_when_no_separator():
    raw = _raw(title="Just A Title")
    meta = parse_title_fallback(raw)
    assert meta.artist == "Some Channel"
    assert meta.title == "Just A Title"


def test_propose_metadata_is_the_title_parse():
    raw = _raw(title="DJ Test - Sunset Set [Official Video]")
    assert propose_metadata(raw) == parse_title_fallback(raw)
