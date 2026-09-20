from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

# Single source of truth for the human-facing product name. The brand may change,
# so it lives here (and is injected into the web UI) instead of being scattered
# through logic. pyproject.toml and README.md mirror this value.
APP_NAME = "Setlist"


def init_env(env_path: str | None = None) -> None:
    """Load variables from a .env file into os.environ. Call once at app startup.

    Not called by load_config(), so tests can control the environment directly.
    """
    load_dotenv(env_path)


def _expand(path_str: str) -> Path:
    return Path(os.path.expanduser(path_str)).resolve()


def _parse_origins(raw: str) -> tuple[str, ...]:
    """Comma-separated origin list -> normalized tuple (no trailing slashes).

    Origins compare byte-exact in CORS, so "https://x.app/" would never match
    the browser's "https://x.app" — normalize once here.
    """
    return tuple(
        origin.strip().rstrip("/")
        for origin in raw.split(",")
        if origin.strip()
    )


@dataclass(frozen=True)
class Config:
    # Only the browser UI needs this, to read 1001tracklists through
    # Firecrawl; the Mac app renders the page itself.
    firecrawl_api_key: str | None
    output_dir: Path
    default_format: str
    port: int
    pot_provider_url: str | None
    api_auth_token: str | None
    cors_origins: tuple[str, ...]
    # Encoded full-set masters kept for fast re-runs; 0 bytes turns it off.
    master_cache_dir: Path
    master_cache_bytes: int


_DEFAULT_MASTER_CACHE_BYTES = 3 * 1024**3


def load_config() -> Config:
    return Config(
        firecrawl_api_key=os.getenv("FIRECRAWL_API_KEY") or None,
        output_dir=_expand(os.getenv("OUTPUT_DIR", "~/Music/YouTube Sets")),
        default_format=os.getenv("DEFAULT_FORMAT", "alac"),
        port=int(os.getenv("PORT", "8765")),
        pot_provider_url=os.getenv("POT_PROVIDER_URL") or None,
        api_auth_token=os.getenv("API_AUTH_TOKEN") or None,
        cors_origins=_parse_origins(os.getenv("CORS_ORIGINS", "")),
        master_cache_dir=_expand(
            os.getenv("MASTER_CACHE_DIR", "~/.cache/setlist/masters")
        ),
        master_cache_bytes=int(
            os.getenv("MASTER_CACHE_BYTES", str(_DEFAULT_MASTER_CACHE_BYTES))
        ),
    )
