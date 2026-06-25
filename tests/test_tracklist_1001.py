from pathlib import Path

from app.core.tracklist_1001 import (
    Parsed1001,
    _cue_to_seconds,
    _normalize_search_results,
    _pick_1001_tracklist_url,
    _split_artist_title,
    is_1001_url,
    parse_1001tracklists_markdown,
)

FIXTURE = (
    Path(__file__).parent
    / "fixtures"
    / "1001tracklists_john_summit_coachella_2026.md"
)


def _fixture() -> str:
    return FIXTURE.read_text(encoding="utf-8")


# --- URL detection ----------------------------------------------------------

def test_is_1001_url_variants():
    assert is_1001_url("https://www.1001tracklists.com/tracklist/2wtl1821/x.html")
    assert is_1001_url("http://1001tracklists.com/tracklist/abc.html")
    assert is_1001_url("https://1001.tl/2wtl1821")
    assert not is_1001_url("https://www.youtube.com/watch?v=Cx5FXDTQ__M")
    assert not is_1001_url("not a url")
    assert not is_1001_url("")


# --- helpers ----------------------------------------------------------------

def test_cue_to_seconds_mm_ss_and_hh_mm_ss():
    assert _cue_to_seconds("1:31") == 91.0
    assert _cue_to_seconds("03:10") == 190.0
    assert _cue_to_seconds("1:02:13") == 3733.0
    assert _cue_to_seconds("0:00") == 0.0


def test_split_artist_title_basic():
    assert _split_artist_title("Devault+-+Can%27t+Wait+No+More") == (
        "Devault",
        "Can't Wait No More",
    )


def test_split_artist_title_keeps_remix_in_title():
    artist, title = _split_artist_title(
        "No+Doubt+-+Hella+Good+%28Layton+Giordani+Remix%29"
    )
    assert artist == "No Doubt"
    assert title == "Hella Good (Layton Giordani Remix)"


def test_split_artist_title_id_id():
    assert _split_artist_title("ID+-+ID") == ("ID", "ID")


def test_split_artist_title_keeps_w_slash_in_artist():
    artist, title = _split_artist_title("Artist+Two+w%2F+Other+-+Title+Two")
    assert artist == "Artist Two w/ Other"
    assert title == "Title Two"


def test_split_artist_title_no_separator():
    assert _split_artist_title("Just+A+Name") == ("", "Just A Name")


# --- the real fixture -------------------------------------------------------

def test_fixture_parses_all_24_tracks():
    parsed = parse_1001tracklists_markdown(_fixture())
    assert isinstance(parsed, Parsed1001)
    assert len(parsed.tracks) == 24


def test_fixture_header_album_artist():
    parsed = parse_1001tracklists_markdown(_fixture())
    assert parsed.album_artist == "John Summit"
    assert "Coachella" in parsed.album


def test_fixture_first_track_starts_at_zero():
    # 1001tracklists omits the opening track's cue -> treated as 0:00.
    t0 = parse_1001tracklists_markdown(_fixture()).tracks[0]
    assert t0.start == 0.0
    assert t0.artist == "John Summit & Zonderling"
    assert t0.title == "ID"


def test_fixture_cue_times_and_names_sample():
    tracks = parse_1001tracklists_markdown(_fixture()).tracks
    # (index, start_seconds, artist, title)
    expected = {
        1: (91.0, "Devault", "Can't Wait No More"),
        2: (190.0, "No Doubt", "Hella Good (Layton Giordani Remix)"),
        4: (444.0, "John Summit & Devault ft. Julia Church", "SHADES OF BLUE"),
        13: (1886.0, "John Summit ft. In\u00e9z", "crystallized"),
        15: (2271.0, "Hamdi & Peekaboo", "ID"),  # second ID; linked-positions noise
        23: (3530.0, "John Summit & HAYLA", "Shiver"),
    }
    for idx, (start, artist, title) in expected.items():
        assert tracks[idx].start == start, idx
        assert tracks[idx].artist == artist, idx
        assert tracks[idx].title == title, idx


def test_fixture_all_have_cues_and_are_strictly_increasing():
    tracks = parse_1001tracklists_markdown(_fixture()).tracks
    starts = [t.start for t in tracks]
    assert all(s is not None for s in starts)
    assert starts == sorted(starts)
    assert len(set(starts)) == len(starts)  # strictly increasing, no dupes


def test_fixture_note_reports_full_cue_coverage():
    parsed = parse_1001tracklists_markdown(_fixture())
    assert "all with cue times" in parsed.note


def test_fixture_excludes_footer_navigation_searches():
    # The footer has q=John+Summit / q=Do+LaB / q=Coachella+Festival Google links
    # with no " - "; none of them should become tracks.
    titles = {t.title for t in parse_1001tracklists_markdown(_fixture()).tracks}
    assert "Do LaB" not in titles
    assert "Coachella Festival" not in titles


# --- synthetic edge cases (h:mm:ss cue, ID-ID, w/, footer cutoff) -----------

SYNTHETIC = """# [DJ X](https://www.1001tracklists.com/dj/x/index.html) @ Test Set

01

Artist One \\- ID

user (1)[open user page](https://www.1001tracklists.com/user/u/index.html "open user page")

Pre-Save 0[search the web via Google](https://www.google.com/search?q=ID+-+ID "search the web via Google")

![art](https://x/y.jpg)

02

1:02:13

Artist Two w/ Other \\- Title Two[open track page](https://www.1001tracklists.com/track/abc/x/index.html "open track page")

Save 5[search the web via Google](https://www.google.com/search?q=Artist+Two+w%2F+Other+-+Title+Two "search the web via Google")

General Information

Views

5,200

[search the web via Google](https://www.google.com/search?q=DJ+X "search the web via Google")
"""


# --- auto-discovery search-result handling ----------------------------------

def test_normalize_search_results_v2_web_shape():
    payload = {"data": {"web": [{"url": "https://a"}, {"url": "https://b"}, "junk"]}}
    assert _normalize_search_results(payload) == [{"url": "https://a"}, {"url": "https://b"}]


def test_normalize_search_results_bare_list_shape():
    payload = {"data": [{"url": "https://a"}]}
    assert _normalize_search_results(payload) == [{"url": "https://a"}]


def test_normalize_search_results_handles_garbage():
    assert _normalize_search_results({}) == []
    assert _normalize_search_results("nope") == []


def test_pick_1001_tracklist_url_skips_non_tracklist_pages():
    results = [
        {"url": "https://www.youtube.com/watch?v=abc"},
        {"url": "https://www.1001tracklists.com/dj/johnsummit/index.html"},
        {"url": "https://www.1001tracklists.com/tracklist/2wtl1821/x.html"},
        {"url": "https://www.1001tracklists.com/tracklist/zzz/y.html"},
    ]
    assert (
        _pick_1001_tracklist_url(results)
        == "https://www.1001tracklists.com/tracklist/2wtl1821/x.html"
    )


def test_pick_1001_tracklist_url_none_when_no_match():
    assert _pick_1001_tracklist_url([{"url": "https://example.com"}]) is None
    assert _pick_1001_tracklist_url([]) is None


def test_synthetic_handles_id_id_w_slash_and_hhmmss():
    parsed = parse_1001tracklists_markdown(SYNTHETIC)
    assert parsed.album_artist == "DJ X"
    assert len(parsed.tracks) == 2  # trailing footer search excluded

    t0, t1 = parsed.tracks
    assert (t0.artist, t0.title, t0.start) == ("ID", "ID", 0.0)
    assert (t1.artist, t1.title, t1.start) == ("Artist Two w/ Other", "Title Two", 3733.0)
