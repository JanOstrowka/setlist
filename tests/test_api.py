from fastapi.testclient import TestClient

from app.main import app


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
