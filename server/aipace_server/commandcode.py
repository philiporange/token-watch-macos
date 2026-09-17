"""Collect Command Code quota usage from commandcode.ai credentials."""

from collections.abc import Mapping
from datetime import datetime, timezone
import json
import os
from pathlib import Path
from typing import Any

import httpx

from aipace_server.models import ModelUsageWindow, ProviderSnapshot, UsageWindow


CREDITS_URL = "https://api.commandcode.ai/alpha/billing/credits"
SUBSCRIPTIONS_URL = "https://api.commandcode.ai/alpha/billing/subscriptions"

PLAN_TABLE: dict[str, tuple[str, float]] = {
    "individual-goat": ("GOAT", 70.0),
    "individual-go": ("Go", 10.0),
    "individual-pro-v1": ("Pro", 80.0),
    "individual-provider": ("Provider", 15.0),
    "individual-pro": ("Pro", 30.0),
    "individual-max": ("Max", 150.0),
    "individual-ultra": ("Ultra", 300.0),
    "teams-pro": ("Teams Pro", 40.0),
}


class CommandCodeError(RuntimeError):
    """Report a failure to load Command Code credentials or retrieve quota usage."""


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


def _reset_date(value: Any) -> datetime | None:
    milliseconds = _numeric(value)
    if milliseconds is None or milliseconds <= 0:
        return None
    try:
        return datetime.fromtimestamp(milliseconds / 1000, timezone.utc)
    except (OSError, OverflowError, ValueError):
        return None


def load_commandcode_api_key(
    home: Path | None = None,
    environment: Mapping[str, str] | None = None,
) -> str:
    """Read the Command Code API key from the environment or ~/.commandcode/auth.json."""

    env = environment if environment is not None else os.environ
    env_key = _trimmed(env.get("COMMANDCODE_API_KEY"))
    if env_key is not None:
        return env_key

    auth_path = (home or Path.home()) / ".commandcode" / "auth.json"
    try:
        with auth_path.open("r", encoding="utf-8") as fp:
            data = json.load(fp)
        if isinstance(data, dict):
            key = _trimmed(data.get("apiKey"))
            if key is not None:
                return key
    except Exception:
        pass

    raise CommandCodeError(
        "Command Code credentials not found. Run command-code and sign in."
    )


def plan_info(plan_id: str | None) -> tuple[str, float] | None:
    """Return the display name and monthly credit allowance for a Command Code plan ID."""

    if not isinstance(plan_id, str):
        return None
    normalized = plan_id.strip().lower().replace("_", "-")
    if not normalized:
        return None
    for prefix, info in sorted(
        PLAN_TABLE.items(), key=lambda item: len(item[0]), reverse=True
    ):
        if normalized.startswith(prefix):
            return info
    return None


def _failure(message: str) -> ProviderSnapshot:
    return ProviderSnapshot(
        provider="Command Code",
        five_hour=UsageWindow(kind="5h", message=message),
        weekly=UsageWindow(kind="Week", message=message),
    )


async def fetch_commandcode_usage(
    timeout: float = 20,
    api_key: str | None = None,
    home: Path | None = None,
    environment: Mapping[str, str] | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> ProviderSnapshot:
    """Return five-hour, weekly, and monthly quota percentages from Command Code."""

    try:
        token = _trimmed(api_key) or load_commandcode_api_key(
            home=home,
            environment=environment,
        )
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "User-Agent": "AIPace",
        }

        async with httpx.AsyncClient(timeout=timeout, transport=transport) as client:
            credits_response = await client.get(
                CREDITS_URL,
                headers=headers,
            )
            if credits_response.status_code in (401, 403):
                raise CommandCodeError(
                    "Command Code authentication failed. Run command-code and sign in again."
                )
            if not credits_response.is_success:
                raise CommandCodeError(
                    f"Command Code returned HTTP {credits_response.status_code}."
                )
            try:
                payload = credits_response.json()
            except ValueError as error:
                raise CommandCodeError(
                    "Command Code response could not be read."
                ) from error
            if not isinstance(payload, dict):
                raise CommandCodeError("Command Code response could not be read.")

            window_limits = payload.get("windowLimits")
            if not isinstance(window_limits, dict):
                window_limits = {}

            five_hour_obj = window_limits.get("fiveHour")
            if isinstance(five_hour_obj, dict):
                used = _numeric(five_hour_obj.get("used"))
                cap = _numeric(five_hour_obj.get("cap"))
                if cap is None or cap == 0 or used is None:
                    five_hour = UsageWindow(kind="5h", message="No 5h limit returned.")
                else:
                    five_hour = UsageWindow(
                        kind="5h",
                        used_percentage=(used / cap) * 100,
                        resets_at=_reset_date(five_hour_obj.get("resetAt")),
                    )
            else:
                five_hour = UsageWindow(kind="5h", message="No 5h limit returned.")

            weekly_obj = window_limits.get("weekly")
            if isinstance(weekly_obj, dict):
                used = _numeric(weekly_obj.get("used"))
                cap = _numeric(weekly_obj.get("cap"))
                if cap is None or cap == 0 or used is None:
                    weekly = UsageWindow(kind="Week", message="No weekly limit returned.")
                else:
                    weekly = UsageWindow(
                        kind="Week",
                        used_percentage=(used / cap) * 100,
                        resets_at=_reset_date(weekly_obj.get("resetAt")),
                    )
            else:
                weekly = UsageWindow(kind="Week", message="No weekly limit returned.")

            credits_obj = payload.get("credits")
            monthly_credits = (
                _numeric(credits_obj.get("monthlyCredits"))
                if isinstance(credits_obj, dict)
                else None
            )

            plan_info_result: tuple[str, float] | None = None
            current_period_end_dt: datetime | None = None
            try:
                sub_response = await client.get(SUBSCRIPTIONS_URL, headers=headers)
                if sub_response.status_code in (401, 403):
                    raise CommandCodeError(
                        "Command Code authentication failed. Run command-code and sign in again."
                    )
                if not sub_response.is_success:
                    raise CommandCodeError(
                        f"Command Code returned HTTP {sub_response.status_code}."
                    )
                sub_payload = sub_response.json()
                if isinstance(sub_payload, dict):
                    sub_data = sub_payload.get("data")
                    if isinstance(sub_data, dict):
                        plan_id = sub_data.get("planId")
                        plan_info_result = plan_info(plan_id)
                        period_end = sub_data.get("currentPeriodEnd")
                        if isinstance(period_end, str):
                            try:
                                current_period_end_dt = datetime.fromisoformat(
                                    period_end.replace("Z", "+00:00")
                                )
                            except ValueError:
                                current_period_end_dt = None
            except Exception:
                pass

            model_windows: list[ModelUsageWindow] = []
            if plan_info_result is not None and monthly_credits is not None:
                plan_name, plan_total = plan_info_result
                if plan_total > 0:
                    used_month_pct = max(
                        0.0,
                        min(100.0, (plan_total - monthly_credits) / plan_total * 100),
                    )
                    model_windows = [
                        ModelUsageWindow(
                            model_name="Credits",
                            window=UsageWindow(
                                kind="Month",
                                used_percentage=used_month_pct,
                                resets_at=current_period_end_dt,
                            ),
                            is_active=True,
                        )
                    ]

            plan_name = plan_info_result[0] if plan_info_result is not None else None
            if plan_name is not None and monthly_credits is not None:
                detail = f"{plan_name} plan · ${monthly_credits:.2f} credits left"
            elif plan_name is not None:
                detail = f"{plan_name} plan"
            elif monthly_credits is not None:
                detail = f"${monthly_credits:.2f} credits left"
            else:
                detail = None

            return ProviderSnapshot(
                provider="Command Code",
                five_hour=five_hour,
                weekly=weekly,
                model_windows=model_windows,
                detail=detail,
            )
    except (CommandCodeError, httpx.HTTPError) as error:
        return _failure(str(error))
