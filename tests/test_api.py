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


def test_reveal_missing_path_returns_404(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    resp = client.post("/reveal", json={"path": "/no/such/file_xyz123.m4a"})
    assert resp.status_code == 404


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
