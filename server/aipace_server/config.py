"""Load the FastAPI server settings from environment variables and ``.env``.

Defaults expose the dashboard on port 8036 across available network interfaces.
Environment variables make the listener and provider timeouts configurable
without changing the collection logic.
"""

from dataclasses import dataclass
import os

from dotenv import load_dotenv


load_dotenv()


@dataclass(frozen=True)
class Settings:
    """Runtime settings for the HTTP server and upstream provider calls."""

    host: str = os.environ.get("AIPACE_HOST", "0.0.0.0")
    port: int = int(os.environ.get("AIPACE_PORT", "8036"))
    request_timeout: float = float(os.environ.get("AIPACE_REQUEST_TIMEOUT", "20"))
    codex_timeout: float = float(os.environ.get("AIPACE_CODEX_TIMEOUT", "20"))


settings = Settings()
