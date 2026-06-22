import dataclasses
from pathlib import Path

from fastapi.testclient import TestClient

from app import main as main_module
from app.core import tracklist_1001
from app.main import app
from app.models import MetadataFields, Track

_FIXTURE = (
    Path(__file__).parent
    / "fixtures"
    / "1001tracklists_john_summit_coachella_2026.md"
)
_1001_URL = (
    "https://www.1001tracklists.com/tracklist/2wtl1821/"
    "john-summit-do-lab-stage-coachella-festival-weekend-1-united-states-2026-04-10.html"
)


def test_recent_returns_list(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.get("/recent")
    assert resp.status_code == 200
    assert isinstance(resp.json(), list)


def _use_output_dir(monkeypatch, output_dir: Path) -> list:
    """Point the app at a temp output dir and capture any subprocess.run calls.

    Returns the list that records reveal invocations, so tests can assert that
    `open -R` is (or is not) called without actually opening Finder.
    """
    monkeypatch.setattr(
        main_module, "cfg",
        dataclasses.replace(main_module.cfg, output_dir=output_dir.resolve()),
    )
    calls: list = []
    monkeypatch.setattr(
        main_module.subprocess, "run",
        lambda *a, **k: calls.append((a, k)),
    )
    return calls


def test_reveal_missing_path_returns_404(monkeypatch, tmp_path):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    calls = _use_output_dir(monkeypatch, tmp_path)
    client = TestClient(app)
    # Inside the output dir but nonexistent: containment passes, existence fails.
    resp = client.post("/reveal", json={"path": str(tmp_path / "no_such_file_xyz123.m4a")})
    assert resp.status_code == 404
    assert calls == []


def test_reveal_inside_output_dir_invokes_open(monkeypatch, tmp_path):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    calls = _use_output_dir(monkeypatch, tmp_path)
    target = tmp_path / "DJ" / "Set" / "track.m4a"
    target.parent.mkdir(parents=True)
    target.write_bytes(b"audio")
    client = TestClient(app)
    resp = client.post("/reveal", json={"path": str(target)})
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert len(calls) == 1
    argv = calls[0][0][0]
    assert argv[0] == "open" and argv[1] == "-R"
    assert Path(argv[2]) == target.resolve()


def test_reveal_outside_output_dir_returns_403(monkeypatch, tmp_path):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    calls = _use_output_dir(monkeypatch, tmp_path)
    client = TestClient(app)
    resp = client.post("/reveal", json={"path": "/etc/passwd"})
    assert resp.status_code == 403
    assert calls == []


def test_reveal_symlink_escape_returns_403(monkeypatch, tmp_path):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    output_dir = tmp_path / "out"
    output_dir.mkdir()
    secret = tmp_path / "secret.txt"
    secret.write_text("top secret")
    link = output_dir / "escape"
    link.symlink_to(secret)
    calls = _use_output_dir(monkeypatch, output_dir)
    client = TestClient(app)
    # The link lives inside the output dir but resolves outside it.
    resp = client.post("/reveal", json={"path": str(link)})
    assert resp.status_code == 403
    assert calls == []


def test_progress_unknown_job_returns_404(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.get("/progress/doesnotexist")
    assert resp.status_code == 404


def test_parse_tracklist_returns_manual_source(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.post("/parse-tracklist", json={"text": "0:00 A - One\n2:00 B - Two", "duration": 3600})
    assert resp.status_code == 200
    data = resp.json()
    assert data["source"] == "manual"
    assert [t["start"] for t in data["tracks"]] == [0.0, 120.0]
    assert data["tracks"][0]["artist"] == "A" and data["tracks"][0]["title"] == "One"


def test_parse_tracklist_empty_text(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.post("/parse-tracklist", json={"text": "", "duration": 0})
    assert resp.status_code == 200
    assert resp.json()["tracks"] == []


def test_parse_tracklist_manual_paste_shape(monkeypatch):
    # A pasted (non-URL) tracklist is parsed manually and comes back in the SAME
    # Tracklist shape the 1001tracklists path returns, so the editor/splitter is
    # source-agnostic. Covers a leading index, en-dash, and an h:mm:ss cue.
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    pasted = "1. Artist One - First [0:00]\n3:24 Artist Two – Second\n1:02:33 Closing"
    resp = client.post("/parse-tracklist", json={"text": pasted, "duration": 7200})
    assert resp.status_code == 200
    data = resp.json()
    assert data["source"] == "manual"
    assert [t["start"] for t in data["tracks"]] == [0.0, 204.0, 3753.0]
    assert data["tracks"][1]["artist"] == "Artist Two"
    assert data["tracks"][1]["title"] == "Second"
    assert set(data.keys()) == {"source", "tracks", "album", "album_artist", "note"}
    assert set(data["tracks"][0].keys()) >= {"start", "title", "artist"}


def test_download_split_rejects_empty_tracks(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.post("/download-split", json={
        "video_id": "abc", "url": "https://x",
        "metadata": MetadataFields().model_dump(), "tracks": [],
    })
    assert resp.status_code == 400


def test_download_split_accepts_tracks_returns_job(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.post("/download-split", json={
        "video_id": "abc", "url": "https://x",
        "metadata": MetadataFields(album="Set", album_artist="DJ").model_dump(),
        "tracks": [Track(start=0.0, title="A").model_dump()],
    })
    assert resp.status_code == 200
    assert "job_id" in resp.json()


def test_parse_tracklist_detects_1001_url(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    md = _FIXTURE.read_text(encoding="utf-8")
    # Stub the network fetch with the committed fixture; give the route a key.
    monkeypatch.setattr(
        tracklist_1001, "fetch_1001tracklists_markdown",
        lambda url, api_key, timeout=120.0: md,
    )
    monkeypatch.setattr(
        main_module, "cfg",
        dataclasses.replace(main_module.cfg, firecrawl_api_key="fc-test"),
    )
    client = TestClient(app)
    resp = client.post("/parse-tracklist", json={"text": _1001_URL})
    assert resp.status_code == 200
    data = resp.json()
    assert data["source"] == "1001tracklists"
    assert len(data["tracks"]) == 24
    assert data["tracks"][0]["start"] == 0.0
    assert data["album_artist"] == "John Summit"


def test_parse_tracklist_1001_without_key_returns_400(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    monkeypatch.setattr(
        main_module, "cfg",
        dataclasses.replace(main_module.cfg, firecrawl_api_key=None),
    )
    client = TestClient(app)
    resp = client.post("/parse-tracklist", json={"text": _1001_URL})
    assert resp.status_code == 400
    assert "FIRECRAWL_API_KEY" in resp.json()["detail"]
