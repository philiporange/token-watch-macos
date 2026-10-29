"""Load the FastAPI server settings from environment variables and ``.env``.

Defaults expose the dashboard on port 8036 across available network interfaces.
Environment variables configure opt-in reset application, the listener, and
provider timeouts without changing the collection logic.
"""

import os
from dataclasses import dataclass

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


settings = Settings()
