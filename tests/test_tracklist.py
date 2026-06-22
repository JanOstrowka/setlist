from app.core.resolver import RawInfo
from app.core.tracklist import (
    parse_chapters,
    parse_description,
    parse_manual,
    normalize,
    build_tracklist,
    parse_manual_tracklist,
)
from app.models import Track


def _raw(**overrides) -> RawInfo:
    base = dict(
        video_id="v", url="u", title="", description="", uploader="C",
        upload_date="20240101", thumbnail="", duration=3600, has_chapters=False,
        best_audio_label="", formats_summary="", chapters=[],
    )
    base.update(overrides)
    return RawInfo(**base)


def test_parse_chapters_splits_artist_title():
    chs = [
        {"start_time": 0.0, "end_time": 120.0, "title": "DJ A - Intro"},
        {"start_time": 120.0, "end_time": 240.0, "title": "Second"},
    ]
    tracks = parse_chapters(chs)
    assert tracks[0].start == 0.0 and tracks[0].artist == "DJ A" and tracks[0].title == "Intro"
    assert tracks[1].artist == "" and tracks[1].title == "Second"


def test_parse_description_mm_ss_and_hh_mm_ss():
    desc = "0:00 Artist One - First\n3:24 Second Track\n1:02:33 Closing"
    tracks = parse_description(desc)
    assert [t.start for t in tracks] == [0.0, 204.0, 3753.0]
    assert tracks[0].artist == "Artist One" and tracks[0].title == "First"
    assert tracks[1].title == "Second Track"


def test_parse_description_brackets_and_index():
    desc = "1. [12:34] Bracketed\n2) 1:00 A - B\nrandom line without time"
    tracks = parse_description(desc)
    assert len(tracks) == 2
    assert tracks[0].start == 754.0 and tracks[0].title == "Bracketed"
    assert tracks[1].start == 60.0 and tracks[1].artist == "A" and tracks[1].title == "B"


def test_parse_manual_three_formats():
    text = "1. Artist - Title [1:23]\nSecond Artist - Second Title\n2:00 Third Title"
    tracks = parse_manual(text)
    assert tracks[0].start == 83.0 and tracks[0].artist == "Artist" and tracks[0].title == "Title"
    assert tracks[1].start is None and tracks[1].artist == "Second Artist" and tracks[1].title == "Second Title"
    assert tracks[2].start == 120.0 and tracks[2].title == "Third Title"


def test_parse_manual_en_dash_em_dash_and_hhmmss():
    # Pasted YouTube-comment lines often use en-/em-dashes and h:mm:ss cues.
    text = "0:00 Artist One – First\n[3:24] Artist Two — Second\n1:02:33 Closing Title"
    tracks = parse_manual(text)
    assert [t.start for t in tracks] == [0.0, 204.0, 3753.0]
    assert tracks[0].artist == "Artist One" and tracks[0].title == "First"
    assert tracks[1].artist == "Artist Two" and tracks[1].title == "Second"
    assert tracks[2].artist == "" and tracks[2].title == "Closing Title"


def test_parse_manual_ignores_garbage_without_error():
    # Separator-only / blank lines carry no track and are dropped; the timestamped
    # lines (incl. an en-dash split and an h:mm:ss cue) still parse cleanly.
    text = (
        "0:00 Artist One - First\n"
        "··········\n"
        "\n"
        "-----\n"
        "3:24 Artist Two – Second\n"
        "   |   \n"
        "1:02:33 Closing\n"
    )
    tracks = parse_manual(text)
    assert [t.start for t in tracks] == [0.0, 204.0, 3753.0]
    assert [t.title for t in tracks] == ["First", "Second", "Closing"]
    assert tracks[1].artist == "Artist Two"


def test_normalize_sorts_and_dedups():
    tracks = [Track(start=120, title="B"), Track(start=0, title="A"), Track(start=120, title="B dup")]
    out = normalize(tracks, 3600)
    assert [t.start for t in out] == [0, 120]
    assert out[0].title == "A"


def test_normalize_drops_beyond_duration():
    tracks = [Track(start=0, title="A"), Track(start=5000, title="too late")]
    out = normalize(tracks, 3600)
    assert [t.start for t in out] == [0]


def test_normalize_keeps_manual_order_when_starts_missing():
    tracks = [Track(start=None, title="First"), Track(start=None, title="Second")]
    out = normalize(tracks)
    assert [t.title for t in out] == ["First", "Second"]


def test_build_tracklist_prefers_chapters():
    raw = _raw(chapters=[{"start_time": 0, "end_time": 10, "title": "Ch"}], description="0:00 Desc")
    tl = build_tracklist(raw)
    assert tl.source == "chapters" and tl.tracks[0].title == "Ch"


def test_build_tracklist_falls_back_to_description():
    raw = _raw(chapters=[], description="0:00 Foo\n2:00 Bar")
    tl = build_tracklist(raw)
    assert tl.source == "description" and len(tl.tracks) == 2


def test_build_tracklist_empty_when_nothing():
    raw = _raw(chapters=[], description="no timestamps here")
    tl = build_tracklist(raw)
    assert tl.source == "none" and tl.tracks == []


def test_parse_manual_tracklist_normalizes():
    tl = parse_manual_tracklist("2:00 B\n0:00 A", 3600)
    assert tl.source == "manual"
    assert [t.start for t in tl.tracks] == [0.0, 120.0]
