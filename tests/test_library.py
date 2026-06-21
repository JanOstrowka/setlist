from pathlib import Path

from app.core.library import (
    sanitize_filename,
    set_output_dir,
    single_track_path,
    track_filename,
    write_cover,
    save,
    ensure_output_dir,
    record_recent,
    load_recent,
)


def test_sanitize_replaces_illegal_chars():
    assert sanitize_filename("AC/DC: Live") == "AC-DC- Live"
    assert sanitize_filename("   ") == "untitled"


def test_sanitize_strips_trailing_dots_and_spaces():
    assert sanitize_filename("Set Name. ") == "Set Name"
    assert sanitize_filename(".hidden") == "hidden"


def test_sanitize_strips_control_chars():
    assert sanitize_filename("a\x00b\x1fc") == "abc"


def test_set_output_dir_structure(tmp_path):
    d = set_output_dir(tmp_path, "DJ Test", "DJ Test", "Sunset Set", "Sunset Set")
    assert d == Path(tmp_path) / "DJ Test" / "Sunset Set"


def test_set_output_dir_falls_back(tmp_path):
    # album_artist empty -> artist; album empty -> title
    d = set_output_dir(tmp_path, "", "The Artist", "", "The Title")
    assert d == Path(tmp_path) / "The Artist" / "The Title"


def test_set_output_dir_sanitizes(tmp_path):
    d = set_output_dir(tmp_path, "AC/DC", "AC/DC", "Back: In", "x")
    assert d == Path(tmp_path) / "AC-DC" / "Back- In"


def test_single_track_path(tmp_path):
    p = single_track_path(tmp_path, "DJ Test", "DJ Test", "Sunset Set", "Opening")
    assert p == Path(tmp_path) / "DJ Test" / "Sunset Set" / "Opening.m4a"


def test_track_filename():
    assert track_filename(1, "Intro") == "01 - Intro.m4a"
    assert track_filename(12, "AC/DC") == "12 - AC-DC.m4a"
    assert track_filename(3, "") == "03 - Untitled.m4a"


def test_write_cover_writes_jpg(tmp_path):
    set_dir = tmp_path / "Artist" / "Set"
    p = write_cover(set_dir, b"jpeg-bytes")
    assert p == set_dir / "cover.jpg"
    assert p.read_bytes() == b"jpeg-bytes"


def test_write_cover_skips_when_none(tmp_path):
    assert write_cover(tmp_path / "x", None) is None
    assert not (tmp_path / "x" / "cover.jpg").exists()


def test_save_moves_file(tmp_path):
    src = tmp_path / "src.m4a"
    src.write_bytes(b"data")
    dest = tmp_path / "out" / "final.m4a"
    result = save(src, dest)
    assert result == dest
    assert dest.exists()
    assert not src.exists()


def test_recent_caps_at_20_and_dedups(tmp_path):
    ensure_output_dir(tmp_path)
    for i in range(25):
        record_recent(tmp_path, {"path": f"/x/{i}.m4a", "title": str(i), "artist": "a", "album": "b"})
    record_recent(tmp_path, {"path": "/x/24.m4a", "title": "24", "artist": "a", "album": "b"})
    items = load_recent(tmp_path)
    assert len(items) == 20
    assert items[0]["path"] == "/x/24.m4a"
    paths = [it["path"] for it in items]
    assert len(paths) == len(set(paths))


def test_load_recent_missing_returns_empty(tmp_path):
    assert load_recent(tmp_path) == []
