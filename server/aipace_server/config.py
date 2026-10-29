"""Load the FastAPI server settings from environment variables and ``.env``.

Defaults expose the dashboard on port 8036 across available network interfaces.
Environment variables configure reset application, history storage, periodic
collection, the listener, and provider timeouts.
"""

import os
from dataclasses import dataclass
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()


@dataclass(frozen=True)
class Settings:
    """Runtime settings for the HTTP server and upstream provider calls."""

    host: str = os.environ.get("AIPACE_HOST", "0.0.0.0")
    port: int = int(os.environ.get("AIPACE_PORT", "8036"))
    request_timeout: float = float(os.environ.get("AIPACE_REQUEST_TIMEOUT", "20"))
    auto_apply_resets: bool = os.environ.get(
        "AIPACE_AUTO_APPLY_RESETS", ""
    ).lower().strip() in {"1", "true", "yes", "on"}
    auto_apply_lead_minutes: int = max(
        1, min(60, int(os.environ.get("AIPACE_AUTO_APPLY_LEAD_MINUTES", "5")))
    )
    codex_timeout: float = float(os.environ.get("AIPACE_CODEX_TIMEOUT", "20"))
    history_path: Path = Path(os.environ.get(
        "AIPACE_HISTORY_PATH", "~/.local/share/aipace/usage-history.sqlite3"
    )).expanduser()
    refresh_minutes: float = max(0, float(os.environ.get("AIPACE_REFRESH_MINUTES", "5")))


settings = Settings()
