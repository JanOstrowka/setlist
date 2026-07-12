import dataclasses
import time

from fastapi.testclient import TestClient

from app import main as main_module
from app.main import app
from app.models import MetadataFields, Track

# ---------------------------------------------------------------------------
# Bearer-token auth middleware
# ---------------------------------------------------------------------------


def _enable_auth(monkeypatch, token: str = "test-token-123") -> str:
    monkeypatch.setattr(
        main_module, "cfg",
        dataclasses.replace(main_module.cfg, api_auth_token=token),
    )
    return token


def test_auth_disabled_allows_anonymous_requests(monkeypatch):
    # The conftest fixture clears the token; behavior must match pre-auth days.
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    client = TestClient(app)
    assert client.get("/recent").status_code == 200


def test_auth_enabled_rejects_missing_and_wrong_tokens(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    _enable_auth(monkeypatch)
    client = TestClient(app)  # default client host is "testclient", i.e. non-local
    resp = client.get("/recent")
    assert resp.status_code == 401
    assert resp.headers["WWW-Authenticate"] == "Bearer"
    assert client.get("/recent", headers={"Authorization": "Bearer wrong"}).status_code == 401


def test_auth_enabled_accepts_valid_bearer(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    token = _enable_auth(monkeypatch)
    client = TestClient(app)
    resp = client.get("/recent", headers={"Authorization": f"Bearer {token}"})
    assert resp.status_code == 200


def test_auth_exempts_ui_paths(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    _enable_auth(monkeypatch)
    client = TestClient(app)
    assert client.get("/").status_code == 200
    assert client.get("/favicon.ico").status_code == 204
    assert client.get("/static/styles.css").status_code == 200


def test_auth_exempts_direct_local_requests(monkeypatch):
    # The local web UI talks to 127.0.0.1 without a token; tunnels always add
    # X-Forwarded-For, so only a genuinely local client gets this exemption.
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    _enable_auth(monkeypatch)
    client = TestClient(app, client=("127.0.0.1", 51234))
    assert client.get("/recent").status_code == 200


def test_auth_requires_token_for_forwarded_loopback_traffic(monkeypatch):
    # Tunnel traffic arrives via loopback but carries X-Forwarded-For -> not exempt.
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    _enable_auth(monkeypatch)
    client = TestClient(app, client=("127.0.0.1", 51234))
    resp = client.get("/recent", headers={"X-Forwarded-For": "203.0.113.7"})
    assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Completion callback (callback_url)
# ---------------------------------------------------------------------------


class _OkResponse:
    is_success = True


def _wait_for(pred, timeout: float = 5.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.01)
    return False


def _fresh_jobs(monkeypatch) -> None:
    """Route endpoint submissions to a dedicated JobManager so these tests never
    queue behind (or interfere with) jobs submitted by other test modules."""
    monkeypatch.setattr(main_module, "jobs", main_module.JobManager(main_module.cfg))


def _download_body(callback_url: str = "") -> dict:
    return {
        "video_id": "abc", "url": "https://x",
        "metadata": MetadataFields(title="Set").model_dump(),
        "callback_url": callback_url,
    }


def test_callback_posts_done_summary(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    _fresh_jobs(monkeypatch)
    monkeypatch.setattr(
        main_module.JobManager, "_process",
        lambda self, job_id, req: ["/out/DJ/Set/track.m4a"],
    )
    calls: list = []
    monkeypatch.setattr(
        main_module.httpx, "post",
        lambda url, json, timeout: calls.append((url, json)) or _OkResponse(),
    )
    client = TestClient(app)
    resp = client.post("/download", json=_download_body("http://n8n.example/resume"))
    assert resp.status_code == 200
    job_id = resp.json()["job_id"]
    assert _wait_for(lambda: len(calls) == 1)
    url, payload = calls[0]
    assert url == "http://n8n.example/resume"
    assert payload == {
        "job_id": job_id, "status": "done",
        "output_paths": ["/out/DJ/Set/track.m4a"], "error": "",
    }


def test_callback_posts_error_summary_on_failure(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    _fresh_jobs(monkeypatch)

    def boom(self, job_id, req):
        raise RuntimeError("pipeline exploded")

    monkeypatch.setattr(main_module.JobManager, "_process_split", boom)
    calls: list = []
    monkeypatch.setattr(
        main_module.httpx, "post",
        lambda url, json, timeout: calls.append((url, json)) or _OkResponse(),
    )
    client = TestClient(app)
    resp = client.post("/download-split", json={
        **_download_body("http://n8n.example/resume"),
        "tracks": [Track(start=0.0, title="A").model_dump()],
    })
    assert resp.status_code == 200
    assert _wait_for(lambda: len(calls) == 1)
    _, payload = calls[0]
    assert payload["status"] == "error"
    assert payload["output_paths"] == []
    assert "pipeline exploded" in payload["error"]


def test_callback_retries_then_succeeds_without_crashing(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    monkeypatch.setattr(main_module, "CALLBACK_RETRY_DELAY", 0.0)
    _fresh_jobs(monkeypatch)
    monkeypatch.setattr(
        main_module.JobManager, "_process", lambda self, job_id, req: ["/out/x.m4a"],
    )
    attempts: list = []

    def flaky_post(url, json, timeout):
        attempts.append(url)
        if len(attempts) < 3:
            raise ConnectionError("target not up yet")
        return _OkResponse()

    monkeypatch.setattr(main_module.httpx, "post", flaky_post)
    client = TestClient(app)
    client.post("/download", json=_download_body("http://n8n.example/resume"))
    assert _wait_for(lambda: len(attempts) == 3)


def test_callback_gives_up_after_max_attempts_and_job_survives(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    monkeypatch.setattr(main_module, "CALLBACK_RETRY_DELAY", 0.0)
    _fresh_jobs(monkeypatch)
    monkeypatch.setattr(
        main_module.JobManager, "_process", lambda self, job_id, req: ["/out/x.m4a"],
    )
    attempts: list = []

    def dead_post(url, json, timeout):
        attempts.append(url)
        raise ConnectionError("nobody home")

    monkeypatch.setattr(main_module.httpx, "post", dead_post)
    client = TestClient(app)
    client.post("/download", json=_download_body("http://n8n.example/resume"))
    assert _wait_for(lambda: len(attempts) == main_module.CALLBACK_ATTEMPTS)
    time.sleep(0.05)  # give a hypothetical extra retry a chance to show up
    assert len(attempts) == main_module.CALLBACK_ATTEMPTS
    # The worker must survive a permanently dead callback target: a follow-up
    # job on the same manager still runs to completion.
    done: list = []
    monkeypatch.setattr(
        main_module.JobManager, "_process",
        lambda self, job_id, req: done.append(job_id) or ["/out/y.m4a"],
    )
    monkeypatch.setattr(main_module.httpx, "post", lambda *a, **k: _OkResponse())
    client.post("/download", json=_download_body())
    assert _wait_for(lambda: len(done) == 1)


def test_no_callback_when_url_empty(monkeypatch):
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    _fresh_jobs(monkeypatch)
    processed: list = []
    monkeypatch.setattr(
        main_module.JobManager, "_process",
        lambda self, job_id, req: processed.append(job_id) or ["/out/x.m4a"],
    )
    calls: list = []
    monkeypatch.setattr(
        main_module.httpx, "post",
        lambda *a, **k: calls.append(a) or _OkResponse(),
    )
    client = TestClient(app)
    client.post("/download", json=_download_body())
    assert _wait_for(lambda: len(processed) == 1)
    time.sleep(0.05)
    assert calls == []
