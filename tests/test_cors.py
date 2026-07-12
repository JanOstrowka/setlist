import dataclasses

from fastapi.testclient import TestClient

from app import main as main_module
from app.config import _parse_origins
from app.main import app

SITE = "https://setlist.vercel.app"


def _enable_cors(monkeypatch, origins: tuple[str, ...] = (SITE,)) -> None:
    monkeypatch.setattr(
        main_module, "cfg",
        dataclasses.replace(main_module.cfg, cors_origins=origins),
    )


def _client(monkeypatch) -> TestClient:
    monkeypatch.setenv("YT_DLP_SELF_UPDATE", "0")
    return TestClient(app)


# ---------------------------------------------------------------------------
# Config parsing
# ---------------------------------------------------------------------------


def test_parse_origins_handles_commas_whitespace_and_trailing_slashes():
    raw = " https://setlist.vercel.app/ ,http://localhost:4173,, "
    assert _parse_origins(raw) == ("https://setlist.vercel.app", "http://localhost:4173")


def test_parse_origins_empty_means_no_cors():
    assert _parse_origins("") == ()


# ---------------------------------------------------------------------------
# Simple (non-preflight) requests
# ---------------------------------------------------------------------------


def test_no_cors_headers_when_unconfigured(monkeypatch):
    client = _client(monkeypatch)
    resp = client.get("/health", headers={"Origin": SITE})
    assert resp.status_code == 200
    assert "access-control-allow-origin" not in resp.headers


def test_allowed_origin_gets_acao_on_actual_request(monkeypatch):
    _enable_cors(monkeypatch)
    client = _client(monkeypatch)
    resp = client.get("/recent", headers={"Origin": SITE})
    assert resp.status_code == 200
    assert resp.headers["access-control-allow-origin"] == SITE
    assert "origin" in resp.headers.get("vary", "").lower()


def test_disallowed_origin_gets_no_acao(monkeypatch):
    _enable_cors(monkeypatch)
    client = _client(monkeypatch)
    resp = client.get("/recent", headers={"Origin": "https://evil.example"})
    assert resp.status_code == 200  # server still answers; the browser blocks
    assert "access-control-allow-origin" not in resp.headers


def test_same_origin_request_without_origin_header_untouched(monkeypatch):
    _enable_cors(monkeypatch)
    client = _client(monkeypatch)
    resp = client.get("/recent")
    assert resp.status_code == 200
    assert "access-control-allow-origin" not in resp.headers


# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------


def _preflight(client, origin: str, extra: dict | None = None):
    headers = {
        "Origin": origin,
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "content-type",
    }
    headers.update(extra or {})
    return client.options("/resolve", headers=headers)


def test_preflight_allowed_origin(monkeypatch):
    _enable_cors(monkeypatch)
    client = _client(monkeypatch)
    resp = _preflight(client, SITE)
    assert resp.status_code == 204
    assert resp.headers["access-control-allow-origin"] == SITE
    assert "POST" in resp.headers["access-control-allow-methods"]
    assert resp.headers["access-control-allow-headers"] == "content-type"
    assert "access-control-allow-private-network" not in resp.headers


def test_preflight_disallowed_origin_rejected(monkeypatch):
    _enable_cors(monkeypatch)
    client = _client(monkeypatch)
    resp = _preflight(client, "https://evil.example")
    assert resp.status_code == 400
    assert "access-control-allow-origin" not in resp.headers


def test_preflight_answers_private_network_access(monkeypatch):
    # Chrome PNA: a public HTTPS page fetching 127.0.0.1 sends this extra
    # header; the helper must opt in explicitly.
    _enable_cors(monkeypatch)
    client = _client(monkeypatch)
    resp = _preflight(client, SITE, {"Access-Control-Request-Private-Network": "true"})
    assert resp.status_code == 204
    assert resp.headers["access-control-allow-private-network"] == "true"


def test_preflight_bypasses_auth(monkeypatch):
    # Browsers never attach Authorization to preflights, so CORS must answer
    # them before the bearer-token middleware can 401.
    _enable_cors(monkeypatch)
    monkeypatch.setattr(
        main_module, "cfg",
        dataclasses.replace(main_module.cfg, cors_origins=(SITE,), api_auth_token="tok"),
    )
    client = _client(monkeypatch)
    resp = _preflight(client, SITE)
    assert resp.status_code == 204


def test_actual_401_still_carries_cors_headers(monkeypatch):
    # If auth fails, the browser should see the real 401, not a CORS error.
    monkeypatch.setattr(
        main_module, "cfg",
        dataclasses.replace(main_module.cfg, cors_origins=(SITE,), api_auth_token="tok"),
    )
    client = _client(monkeypatch)
    resp = client.get("/recent", headers={"Origin": SITE})
    assert resp.status_code == 401
    assert resp.headers["access-control-allow-origin"] == SITE


# ---------------------------------------------------------------------------
# /health
# ---------------------------------------------------------------------------


def test_health_is_public_even_with_auth_enabled(monkeypatch):
    monkeypatch.setattr(
        main_module, "cfg",
        dataclasses.replace(main_module.cfg, api_auth_token="tok"),
    )
    client = _client(monkeypatch)
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "app": "Setlist"}
