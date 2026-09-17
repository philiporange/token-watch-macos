"""Collect Muse quota usage from Meta's Muse Code credentials."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import subprocess
from typing import Any, Mapping

import httpx

from aipace_server.models import ProviderSnapshot, UsageWindow


KEY_URL = "https://api.meta.ai/muse-code/key"


class MuseError(RuntimeError):
    """Report a credential, authentication, or quota API failure."""


def _trimmed(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def _numeric(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float, str)):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _read_command(executable: str, arguments: list[str]) -> str | None:
    try:
        result = subprocess.run(
            [executable, *arguments],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (FileNotFoundError, subprocess.SubprocessError):
        return None
    return _trimmed(result.stdout)


def _read_keychain() -> str | None:
    system = platform.system()
    if system == "Darwin":
        return _read_command(
            "/usr/bin/security",
            [
                "find-generic-password",
                "-s",
                "ai.meta.dev.credentials",
                "-a",
                "meta",
                "-w",
            ],
        )
    if system == "Linux":
        return _read_command(
            "secret-tool",
            [
                "lookup",
                "service",
                "ai.meta.dev.credentials",
                "account",
                "meta",
            ],
        )
    return None


def load_muse_access_token(
    home: Path | None = None,
    environment: Mapping[str, str] | None = None,
    raw_keychain: str | None = None,
) -> str:
    """Read an active Muse access token from auth.json or OS keychain."""

    environment = environment if environment is not None else os.environ
    xdg_config = _trimmed(environment.get("XDG_CONFIG_HOME"))
    config_dir = Path(xdg_config) if xdg_config else (home or Path.home()) / ".config"
    auth_file = config_dir / "muse" / "auth.json"

    if auth_file.is_file():
        try:
            content = auth_file.read_text(encoding="utf-8")
        except OSError as error:
            raise MuseError("Muse credentials could not be read.") from error
        try:
            data = json.loads(content)
        except (TypeError, json.JSONDecodeError) as error:
            raise MuseError("Muse credentials could not be read.") from error
        if not isinstance(data, dict):
            raise MuseError("Muse credentials could not be read.")
        providers = data.get("providers")
        meta = providers.get("meta") if isinstance(providers, dict) else None
        token = _trimmed(meta.get("access_token")) if isinstance(meta, dict) else None
        if token is not None:
            return token

    raw = raw_keychain if raw_keychain is not None else _read_keychain()
    if raw is not None:
        trimmed_raw = _trimmed(raw)
        if trimmed_raw is not None:
            try:
                keychain_data = json.loads(trimmed_raw)
            except (TypeError, json.JSONDecodeError) as error:
                raise MuseError("Muse credentials could not be read.") from error
            if not isinstance(keychain_data, dict):
                raise MuseError("Muse credentials could not be read.")
            keychain_token = _trimmed(keychain_data.get("access_token"))
            if keychain_token is not None:
                return keychain_token

    raise MuseError("Muse credentials not found. Run muse login.")


def _reset_date(value: Any) -> datetime | None:
    seconds = _numeric(value)
    if seconds is None or seconds <= 0:
        return None
    try:
        return datetime.fromtimestamp(seconds, timezone.utc)
    except (OSError, OverflowError, ValueError):
        return None


def _failure(message: str) -> ProviderSnapshot:
    return ProviderSnapshot(
        provider="Muse",
        five_hour=UsageWindow(kind="5h", message=message),
        weekly=UsageWindow(kind="Week", message=message),
    )


async def fetch_muse_usage(
    timeout: float = 20,
    access_token: str | None = None,
    home: Path | None = None,
    environment: Mapping[str, str] | None = None,
    raw_keychain: str | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> ProviderSnapshot:
    """Return five-hour and weekly quota percentages from Muse."""

    try:
        token = _trimmed(access_token) or load_muse_access_token(
            home=home,
            environment=environment,
            raw_keychain=raw_keychain,
        )
        async with httpx.AsyncClient(timeout=timeout, transport=transport) as client:
            response = await client.post(
                KEY_URL,
                headers={
                    "Authorization": f"Bearer {token}",
                    "x-api-version": "1.0.0",
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                    "User-Agent": "AIPace",
                },
                json={},
            )
        if response.status_code in (401, 403):
            raise MuseError("Muse authentication failed. Run muse login again.")
        if not response.is_success:
            raise MuseError(
                f"Muse account endpoint returned HTTP {response.status_code}."
            )
        try:
            payload = response.json()
        except ValueError as error:
            raise MuseError("Muse response could not be read.") from error
        if not isinstance(payload, dict):
            raise MuseError("Muse response could not be read.")

        subs_usage = payload.get("subs_usage")
        if not isinstance(subs_usage, dict):
            subs_usage = {}

        window = subs_usage.get("window")
        if isinstance(window, dict):
            five_hour = UsageWindow(
                kind="5h",
                used_percentage=_numeric(window.get("used_percent")),
                resets_at=_reset_date(window.get("resets_at")),
            )
        else:
            five_hour = UsageWindow(kind="5h", message="No 5h limit returned.")

        weekly = subs_usage.get("weekly")
        if isinstance(weekly, dict):
            weekly_window = UsageWindow(
                kind="Week",
                used_percentage=_numeric(weekly.get("used_percent")),
                resets_at=_reset_date(weekly.get("resets_at")),
            )
        else:
            weekly_window = UsageWindow(
                kind="Week", message="No weekly limit returned."
            )

        detail = _trimmed(payload.get("subs_tier_name"))
        return ProviderSnapshot(
            provider="Muse",
            five_hour=five_hour,
            weekly=weekly_window,
            detail=detail,
        )
    except (MuseError, httpx.HTTPError) as error:
        return _failure(str(error))
