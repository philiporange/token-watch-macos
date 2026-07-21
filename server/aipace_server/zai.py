"""Collect z.ai Coding Plan quota usage with a local ``ZAI_API_KEY``."""

from datetime import datetime, timezone
import os
from pathlib import Path
from typing import Any, Mapping

from dotenv import dotenv_values
import httpx

from aipace_server.models import ProviderSnapshot, UsageWindow


QUOTA_URL = "https://api.z.ai/api/monitor/usage/quota/limit"


class ZaiError(RuntimeError):
    """Report a failure to load the z.ai key or retrieve quota usage."""


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


def load_zai_api_key(
    home: Path | None = None,
    environment: Mapping[str, str] | None = None,
) -> str | None:
    """Read only ``ZAI_API_KEY`` from the environment or ``~/.env``."""

    environment = environment if environment is not None else os.environ
    token = _trimmed(environment.get("ZAI_API_KEY"))
    if token is not None:
        return token

    try:
        values = dotenv_values((home or Path.home()) / ".env", interpolate=False)
    except OSError:
        return None
    return _trimmed(values.get("ZAI_API_KEY"))


def _reset_date(value: Any) -> datetime | None:
    milliseconds = _numeric(value)
    if milliseconds is None or milliseconds <= 0:
        return None
    try:
        return datetime.fromtimestamp(milliseconds / 1000, timezone.utc)
    except (OSError, OverflowError, ValueError):
        return None


def _limit(limits: Any, limit_type: str) -> dict[str, Any] | None:
    if not isinstance(limits, list):
        return None
    return next(
        (
            limit
            for limit in limits
            if isinstance(limit, dict) and limit.get("type") == limit_type
        ),
        None,
    )


def _window(
    kind: str,
    limit: dict[str, Any] | None,
    missing_message: str,
) -> UsageWindow:
    if limit is None:
        return UsageWindow(kind=kind, message=missing_message)
    return UsageWindow(
        kind=kind,
        used_percentage=_numeric(limit.get("percentage")),
        resets_at=_reset_date(limit.get("nextResetTime")),
    )


def _failure(message: str) -> ProviderSnapshot:
    return ProviderSnapshot(
        provider="Z.ai",
        five_hour=UsageWindow(kind="5h", message=message),
        weekly=UsageWindow(kind="Month", message=message),
    )


async def fetch_zai_usage(
    timeout: float = 20,
    api_key: str | None = None,
    home: Path | None = None,
    environment: Mapping[str, str] | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> ProviderSnapshot:
    """Return five-hour token and monthly MCP quota percentages from z.ai."""

    token = _trimmed(api_key) or load_zai_api_key(home, environment)
    if token is None:
        return _failure("Z.ai API key not found. Set ZAI_API_KEY in ~/.env.")

    try:
        async with httpx.AsyncClient(timeout=timeout, transport=transport) as client:
            response = await client.get(
                QUOTA_URL,
                headers={
                    "Authorization": token,
                    "Accept-Language": "en-US,en",
                    "Content-Type": "application/json",
                    "User-Agent": "AIPace",
                },
            )
        if response.status_code in (401, 403):
            raise ZaiError("Z.ai authentication failed.")
        if not response.is_success:
            raise ZaiError(
                f"Z.ai quota endpoint returned HTTP {response.status_code}."
            )
        try:
            payload = response.json()
        except ValueError as error:
            raise ZaiError("Z.ai quota response could not be read.") from error
        data = payload.get("data") if isinstance(payload, dict) else None
        if not isinstance(data, dict):
            raise ZaiError("Z.ai quota response could not be read.")

        limits = data.get("limits")
        token_limit = _limit(limits, "TOKENS_LIMIT")
        tool_limit = _limit(limits, "TIME_LIMIT")
        detail = next(
            (
                _trimmed(data.get(key))
                for key in ("planName", "plan", "plan_type", "packageName")
                if _trimmed(data.get(key)) is not None
            ),
            None,
        )
        return ProviderSnapshot(
            provider="Z.ai",
            five_hour=_window(
                "5h", token_limit, "No 5h token limit returned."
            ),
            weekly=_window(
                "Month", tool_limit, "No monthly MCP limit returned."
            ),
            detail=detail,
        )
    except (ZaiError, httpx.HTTPError) as error:
        return _failure(str(error))
