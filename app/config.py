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


@dataclass(frozen=True)
class Config:
    openai_api_key: str | None
    firecrawl_api_key: str | None
    openai_model: str
    output_dir: Path
    default_format: str
    port: int
    pot_provider_url: str | None


def load_config() -> Config:
    return Config(
        openai_api_key=os.getenv("OPENAI_API_KEY") or None,
        firecrawl_api_key=os.getenv("FIRECRAWL_API_KEY") or None,
        openai_model=os.getenv("OPENAI_MODEL", "gpt-4o-mini"),
        output_dir=_expand(os.getenv("OUTPUT_DIR", "~/Music/YouTube Sets")),
        default_format=os.getenv("DEFAULT_FORMAT", "alac"),
        port=int(os.getenv("PORT", "8765")),
        pot_provider_url=os.getenv("POT_PROVIDER_URL") or None,
    )
