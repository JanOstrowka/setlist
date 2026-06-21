from app.config import APP_NAME, load_config
from app.models import MetadataFields, DownloadRequest, ProgressEvent


def test_app_name_is_setlist():
    # The human-facing product name lives in a single constant so a rename
    # touches one place. v1 brand is "Setlist".
    assert APP_NAME == "Setlist"


def test_config_defaults(monkeypatch):
    for key in [
        "OPENAI_API_KEY", "FIRECRAWL_API_KEY", "OPENAI_MODEL",
        "OUTPUT_DIR", "DEFAULT_FORMAT", "PORT", "POT_PROVIDER_URL",
    ]:
        monkeypatch.delenv(key, raising=False)
    cfg = load_config()
    assert cfg.openai_model == "gpt-4o-mini"
    assert cfg.default_format == "alac"
    assert cfg.port == 8765
    assert cfg.openai_api_key is None
    assert cfg.firecrawl_api_key is None
    assert cfg.pot_provider_url is None
    assert str(cfg.output_dir).endswith("YouTube Sets")


def test_config_reads_environment(monkeypatch):
    monkeypatch.setenv("OPENAI_MODEL", "gpt-4o")
    monkeypatch.setenv("DEFAULT_FORMAT", "aac256")
    monkeypatch.setenv("PORT", "9000")
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    cfg = load_config()
    assert cfg.openai_model == "gpt-4o"
    assert cfg.default_format == "aac256"
    assert cfg.port == 9000
    assert cfg.openai_api_key == "sk-test"


def test_metadata_defaults():
    meta = MetadataFields()
    assert meta.title == ""
    assert meta.year is None
    assert meta.compilation is False


def test_download_request_defaults():
    req = DownloadRequest(video_id="abc", url="https://x", metadata=MetadataFields())
    assert req.format == "alac"
    assert req.cover == "keep"


def test_progress_event_defaults():
    ev = ProgressEvent(stage="download", pct=42.0, message="x")
    assert ev.file_path is None
