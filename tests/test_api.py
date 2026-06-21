from fastapi.testclient import TestClient

from app.main import app
from app.models import MetadataFields, Track


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
