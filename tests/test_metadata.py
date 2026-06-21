from app.core.resolver import RawInfo
from app.core.metadata_ai import clean_title, parse_title_fallback, _map_ai_json


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


def test_map_ai_json_overrides_and_coerces():
    raw = _raw(title="DJ Test - Sunset Set")
    fallback = parse_title_fallback(raw)
    data = {
        "title": "Sunset Set",
        "artist": "DJ Test",
        "album": "Tomorrowland 2025",
        "album_artist": "Various Artists",
        "year": "2025",
        "genre": "Electronic",
        "compilation": True,
    }
    meta = _map_ai_json(data, fallback, raw)
    assert meta.album == "Tomorrowland 2025"
    assert meta.album_artist == "Various Artists"
    assert meta.year == 2025
    assert meta.genre == "Electronic"
    assert meta.compilation is True
    assert meta.comment == "https://youtu.be/abc123"


def test_map_ai_json_empty_fields_fall_back():
    raw = _raw(title="DJ Test - Sunset Set")
    fallback = parse_title_fallback(raw)
    data = {"title": "", "artist": "", "album": "", "album_artist": "", "year": None, "genre": "", "compilation": False}
    meta = _map_ai_json(data, fallback, raw)
    assert meta.title == fallback.title
    assert meta.artist == fallback.artist
    assert meta.album == fallback.album
    assert meta.year == fallback.year


def test_map_ai_json_bad_year_falls_back():
    raw = _raw(title="A - B")
    fallback = parse_title_fallback(raw)
    meta = _map_ai_json({"year": "not-a-year"}, fallback, raw)
    assert meta.year == fallback.year
