from pathlib import Path

from app.core.library import (
    sanitize_filename,
    output_path,
    save,
    ensure_output_dir,
    record_recent,
    load_recent,
)


def test_sanitize_replaces_illegal_chars():
    assert sanitize_filename("AC/DC: Live") == "AC-DC- Live"
    assert sanitize_filename("   ") == "untitled"


def test_output_path_format(tmp_path):
    p = output_path(tmp_path, "DJ Test", "Sunset Set", "abc123")
    assert p.name == "DJ Test - Sunset Set [abc123].m4a"
    assert p.parent == Path(tmp_path)


def test_output_path_sanitizes(tmp_path):
    p = output_path(tmp_path, "AC/DC", "Back: In", "xyz")
    assert p.name == "AC-DC - Back- In [xyz].m4a"


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
    # Re-record an existing path; it should move to the front, not duplicate.
    record_recent(tmp_path, {"path": "/x/24.m4a", "title": "24", "artist": "a", "album": "b"})
    items = load_recent(tmp_path)
    assert len(items) == 20
    assert items[0]["path"] == "/x/24.m4a"
    paths = [it["path"] for it in items]
    assert len(paths) == len(set(paths))


def test_load_recent_missing_returns_empty(tmp_path):
    assert load_recent(tmp_path) == []
