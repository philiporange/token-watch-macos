"""Collect AliCloud Model Studio Token Plan quota usage from console credentials."""

from collections.abc import Mapping
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import plistlib
from typing import Any

from dotenv import dotenv_values
import httpx

from aipace_server.models import ProviderSnapshot, UsageWindow


USAGE_URL = (
    "https://bailian-singapore-cs.alibabacloud.com/data/api.json"
    "?action=IntlBroadScopeAspnGateway&product=sfm_bailian"
    "&api=zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
)
SUBSCRIPTION_URL = (
    "https://bailian-singapore-cs.alibabacloud.com/data/api.json"
    "?action=IntlBroadScopeAspnGateway&product=sfm_bailian"
    "&api=zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
)


class AliCloudError(RuntimeError):
    """Report a failure to load AliCloud credentials or retrieve quota usage."""


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


def load_alicloud_ticket(
    home: Path | None = None,
    environment: Mapping[str, str] | None = None,
) -> str:
    """Read the AliCloud console ticket from the environment, ~/.env, or Muon."""

    environment = environment if environment is not None else os.environ
    ticket = _trimmed(environment.get("ALICLOUD_CONSOLE_TICKET"))
    if ticket is not None:
        return ticket

    try:
        values = dotenv_values((home or Path.home()) / ".env", interpolate=False)
    except OSError:
        values = {}
    file_ticket = _trimmed(values.get("ALICLOUD_CONSOLE_TICKET"))
    if file_ticket is not None:
        return file_ticket

    sessions_dir = (
        (home or Path.home())
        / "Library"
        / "Application Support"
        / "Muon"
        / "website-sessions"
    )
    if sessions_dir.is_dir():
        try:
            plist_files = sorted(sessions_dir.glob("*.plist"))
        except OSError:
            plist_files = []
        for plist_file in plist_files:
            try:
                with plist_file.open("rb") as fp:
                    data = plistlib.load(fp)
            except Exception:
                continue
            if not isinstance(data, dict):
                continue
            cookies = data.get("cookies")
            if not isinstance(cookies, list):
                continue
            for cookie in cookies:
                if not isinstance(cookie, dict):
                    continue
                if cookie.get("Name") != "login_aliyunid_ticket":
                    continue
                domain = cookie.get("Domain")
                if not isinstance(domain, str):
                    continue
                clean_domain = domain.lstrip(".")
                if (
                    clean_domain == "alibabacloud.com"
                    or clean_domain.endswith(".alibabacloud.com")
                ):
                    cookie_val = _trimmed(cookie.get("Value"))
                    if cookie_val is not None:
                        return cookie_val

    raise AliCloudError(
        "AliCloud credentials not found. Sign in to the Model Studio console in Muon or set ALICLOUD_CONSOLE_TICKET."
    )


def _failure(message: str) -> ProviderSnapshot:
    return ProviderSnapshot(
        provider="AliCloud",
        five_hour=UsageWindow(kind="5h", message=message),
        weekly=UsageWindow(kind="Week", message=message),
    )


async def fetch_alicloud_usage(
    timeout: float = 20,
    ticket: str | None = None,
    home: Path | None = None,
    environment: Mapping[str, str] | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> ProviderSnapshot:
    """Return weekly quota percentage and plan details from AliCloud."""

    try:
        active_ticket = _trimmed(ticket) or load_alicloud_ticket(
            home=home,
            environment=environment,
        )
        headers = {
            "Cookie": f"login_aliyunid_ticket={active_ticket}",
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": "AIPace",
        }
        usage_form = {
            "params": json.dumps(
                {
                    "Api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
                    "V": "1.0",
                    "Data": {"cornerstoneParam": {"switchUserType": 3}},
                }
            ),
            "region": "ap-southeast-1",
        }

        async with httpx.AsyncClient(timeout=timeout, transport=transport) as client:
            response = await client.post(
                USAGE_URL,
                headers=headers,
                data=usage_form,
            )
            if not response.is_success:
                raise AliCloudError(
                    f"AliCloud console returned HTTP {response.status_code}."
                )
            try:
                payload = response.json()
            except ValueError as error:
                raise AliCloudError(
                    "AliCloud response could not be read."
                ) from error
            if not isinstance(payload, dict):
                raise AliCloudError("AliCloud response could not be read.")

            data = payload.get("data")
            if not isinstance(data, dict):
                raise AliCloudError("AliCloud response could not be read.")

            error_code = data.get("errorCode")
            if error_code == "BailianGateway.Login.NotLogined":
                raise AliCloudError(
                    "AliCloud session expired. Sign in to the Model Studio console again."
                )
            if error_code:
                raise AliCloudError(
                    f"AliCloud console returned {error_code}."
                )

            data_v2 = data.get("DataV2")
            if not isinstance(data_v2, dict):
                raise AliCloudError("AliCloud response could not be read.")
            inner_data = data_v2.get("data")
            if not isinstance(inner_data, dict):
                raise AliCloudError("AliCloud response could not be read.")
            usage_payload = inner_data.get("data")
            if not isinstance(usage_payload, dict):
                raise AliCloudError("AliCloud response could not be read.")

            fraction = _numeric(usage_payload.get("per1WeekPercentage"))
            used_percentage = fraction * 100 if fraction is not None else None
            resets_at = _reset_date(usage_payload.get("per1WeekResetTime"))

            detail: str | None = None
            try:
                sub_form = {
                    "params": json.dumps(
                        {
                            "Api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription",
                            "V": "1.0",
                            "Data": {
                                "queryInstanceInfoRequest": {},
                                "cornerstoneParam": {"switchUserType": 3},
                            },
                        }
                    ),
                    "region": "ap-southeast-1",
                }
                sub_response = await client.post(
                    SUBSCRIPTION_URL,
                    headers=headers,
                    data=sub_form,
                )
                if sub_response.is_success:
                    sub_json = sub_response.json()
                    if isinstance(sub_json, dict):
                        sub_data = sub_json.get("data")
                        if (
                            isinstance(sub_data, dict)
                            and not sub_data.get("errorCode")
                        ):
                            sub_v2 = sub_data.get("DataV2")
                            if isinstance(sub_v2, dict):
                                sub_inner = sub_v2.get("data")
                                if isinstance(sub_inner, dict):
                                    sub_payload = sub_inner.get("data")
                                    if isinstance(sub_payload, dict):
                                        spec_code = _trimmed(
                                            sub_payload.get("specCode")
                                        )
                                        remaining_days = sub_payload.get(
                                            "remainingDays"
                                        )
                                        if (
                                            spec_code is not None
                                            and remaining_days is not None
                                        ):
                                            detail = (
                                                f"{spec_code.capitalize()} plan · "
                                                f"{remaining_days} days left"
                                            )
            except Exception:
                detail = None

            weekly_message = (
                None if used_percentage is not None else "No weekly limit returned."
            )
            return ProviderSnapshot(
                provider="AliCloud",
                five_hour=UsageWindow(
                    kind="5h",
                    message="Token Plan has no 5h window.",
                ),
                weekly=UsageWindow(
                    kind="Week",
                    used_percentage=used_percentage,
                    resets_at=resets_at,
                    message=weekly_message,
                ),
                detail=detail,
            )
    except (AliCloudError, httpx.HTTPError) as error:
        return _failure(str(error))
