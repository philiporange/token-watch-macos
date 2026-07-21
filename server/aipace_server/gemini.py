"""Collect Gemini quota usage from Antigravity CLI (``agy``) credentials."""

import base64
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import platform
import subprocess
from typing import Any, Mapping

import httpx

from aipace_server.models import ModelUsageWindow, ProviderSnapshot, UsageWindow


HOSTS = (
    "daily-cloudcode-pa.googleapis.com",
    "cloudcode-pa.googleapis.com",
)
TOKEN_URL = "https://oauth2.googleapis.com/token"
# agy uses an installed-app OAuth client. These shared values identify the
# public client; each user's credential remains in their OS keyring/token file.
OAUTH_CLIENT_ID = (
    "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
)
OAUTH_CLIENT_SECRET = "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"
KEYRING_PREFIX = "go-keyring-base64:"


class AgyError(RuntimeError):
    """Report a credential, refresh, or private quota API failure."""


class AgyAuthenticationError(AgyError):
    """Indicate that an access token was rejected by the quota API."""


@dataclass(frozen=True)
class AgyCredential:
    """The OAuth values read from agy's credential store."""

    access_token: str
    refresh_token: str | None = None
    expiry: datetime | None = None
    auth_method: str | None = None


def _trimmed(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def decode_agy_secret(raw: str) -> AgyCredential:
    """Decode agy's plain JSON or ``go-keyring-base64:`` credential value."""

    if raw.startswith(KEYRING_PREFIX):
        try:
            payload = base64.b64decode(
                raw[len(KEYRING_PREFIX) :], validate=True
            ).decode("utf-8")
        except (ValueError, UnicodeDecodeError) as error:
            raise AgyError("Gemini credentials could not be read.") from error
    else:
        payload = raw
    try:
        root = json.loads(payload)
    except (TypeError, json.JSONDecodeError) as error:
        raise AgyError("Gemini credentials could not be read.") from error
    if not isinstance(root, dict):
        raise AgyError("Gemini credentials could not be read.")
    token = root.get("token", root)
    if not isinstance(token, dict):
        raise AgyError("Gemini credentials could not be read.")
    access_token = _trimmed(token.get("access_token"))
    if access_token is None:
        raise AgyError("Gemini credentials could not be read.")
    return AgyCredential(
        access_token=access_token,
        refresh_token=_trimmed(token.get("refresh_token")),
        expiry=_parse_expiry(token.get("expiry")),
        auth_method=_trimmed(root.get("auth_method")),
    )


def _parse_expiry(value: Any) -> datetime | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        timestamp = float(value)
        if timestamp > 10_000_000_000:
            timestamp /= 1000
        try:
            return datetime.fromtimestamp(timestamp, timezone.utc)
        except (OSError, OverflowError, ValueError):
            return None
    value = _trimmed(value)
    if value is None:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
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


def _read_keyring() -> str | None:
    system = platform.system()
    if system == "Darwin":
        return _read_command(
            "/usr/bin/security",
            [
                "find-generic-password",
                "-s",
                "gemini",
                "-a",
                "antigravity",
                "-w",
            ],
        )
    if system == "Linux":
        return _read_command(
            "secret-tool",
            ["lookup", "service", "gemini", "account", "antigravity"],
        )
    return None


def load_agy_credential(
    home: Path | None = None,
    environment: Mapping[str, str] | None = None,
    raw_keyring: str | None = None,
) -> AgyCredential:
    """Read agy's OS keyring entry or headless token-file fallback."""

    environment = environment if environment is not None else os.environ
    raw = _trimmed(raw_keyring) if raw_keyring is not None else _read_keyring()
    if raw is None:
        configured_path = _trimmed(environment.get("AGY_OAUTH_TOKEN_FILE"))
        path = (
            Path(configured_path).expanduser()
            if configured_path
            else (home or Path.home())
            / ".gemini"
            / "antigravity-cli"
            / "antigravity-oauth-token"
        )
        try:
            raw = _trimmed(path.read_text(encoding="utf-8"))
        except OSError:
            raw = None
    if raw is None:
        raise AgyError("Gemini credentials not found. Run agy and sign in.")
    return decode_agy_secret(raw)


def _needs_refresh(credential: AgyCredential) -> bool:
    if credential.expiry is None:
        return False
    now = datetime.now(timezone.utc)
    expiry = credential.expiry
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    return expiry - now < timedelta(minutes=1)


async def _refresh_access_token(
    client: httpx.AsyncClient, refresh_token: str | None
) -> str:
    if refresh_token is None:
        raise AgyError("Gemini session expired. Run agy and sign in again.")
    response = await client.post(
        TOKEN_URL,
        data={
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
            "client_id": OAUTH_CLIENT_ID,
            "client_secret": OAUTH_CLIENT_SECRET,
        },
    )
    if response.status_code in (400, 401):
        raise AgyError("Gemini session expired. Run agy and sign in again.")
    if not response.is_success:
        raise AgyError(
            f"Gemini token refresh returned HTTP {response.status_code}."
        )
    try:
        token = _trimmed(response.json().get("access_token"))
    except (AttributeError, ValueError) as error:
        raise AgyError("Gemini token refresh response could not be read.") from error
    if token is None:
        raise AgyError("Gemini token refresh returned no access token.")
    return token


async def _post_internal(
    client: httpx.AsyncClient,
    host: str,
    method: str,
    access_token: str,
    body: dict[str, Any],
) -> dict[str, Any]:
    response = await client.post(
        f"https://{host}/v1internal:{method}",
        headers={
            "Authorization": f"Bearer {access_token.strip()}",
            "Content-Type": "application/json",
            # The quota API rejects unknown user agents with 403.
            "User-Agent": "antigravity",
        },
        json=body,
    )
    if response.status_code in (401, 403):
        raise AgyAuthenticationError("Gemini authentication failed.")
    if not response.is_success:
        raise AgyError(f"Gemini {method} returned HTTP {response.status_code}.")
    try:
        payload = response.json()
    except ValueError as error:
        raise AgyError(f"Gemini {method} response could not be read.") from error
    if not isinstance(payload, dict):
        raise AgyError(f"Gemini {method} response could not be read.")
    return payload


async def _fetch_summary(
    client: httpx.AsyncClient, access_token: str
) -> tuple[dict[str, Any], str | None, str]:
    last_error: AgyError = AgyError("No Gemini quota host responded.")
    for host in HOSTS:
        try:
            load = await _post_internal(
                client,
                host,
                "loadCodeAssist",
                access_token,
                {"metadata": {"ideType": "ANTIGRAVITY"}},
            )
            project = _trimmed(load.get("cloudaicompanionProject"))
            if project is None:
                raise AgyError("Gemini loadCodeAssist returned no project.")
            summary = await _post_internal(
                client,
                host,
                "retrieveUserQuotaSummary",
                access_token,
                {"project": project},
            )
            return summary, _tier_name(load), host
        except AgyAuthenticationError:
            raise
        except AgyError as error:
            last_error = error
    raise last_error


def _tier_name(load: dict[str, Any]) -> str | None:
    # currentTier reports the Code Assist tier ("free-tier") even for
    # subscribers; paidTier carries the actual plan ("Google AI Pro").
    paid = load.get("paidTier")
    if isinstance(paid, dict):
        name = _trimmed(paid.get("name")) or _trimmed(paid.get("id"))
        if name is not None:
            return name
    current = load.get("currentTier")
    if isinstance(current, dict):
        return _trimmed(current.get("id")) or _trimmed(current.get("name"))
    return None


def _numeric(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float, str)):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _bucket_kind(bucket: dict[str, Any]) -> str | None:
    text = " ".join(
        str(bucket.get(key, ""))
        for key in ("window", "bucketId", "displayName")
    ).lower()
    if "weekly" in text or "week" in text:
        return "Week"
    if "five-hour" in text or "five hour" in text or "5h" in text:
        return "5h"
    return None


def _reset_date(value: Any) -> datetime | None:
    value = _trimmed(value)
    if value is None:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _window(bucket: dict[str, Any] | None, kind: str, message: str) -> UsageWindow:
    if bucket is None:
        return UsageWindow(kind=kind, message=message)
    if bucket.get("disabled") is True:
        return UsageWindow(kind=kind, message="Quota disabled.")
    remaining = _numeric(bucket.get("remainingFraction"))
    used = None if remaining is None else (1 - min(max(remaining, 0), 1)) * 100
    return UsageWindow(
        kind=kind,
        used_percentage=used,
        resets_at=_reset_date(bucket.get("resetTime")),
    )


def _normalized_groups(payload: dict[str, Any]) -> list[dict[str, Any]]:
    raw_groups = payload.get("groups")
    if not isinstance(raw_groups, list):
        return []
    groups: list[dict[str, Any]] = []
    for raw_group in raw_groups:
        if not isinstance(raw_group, dict):
            continue
        buckets = raw_group.get("buckets")
        groups.append(
            {
                "display_name": _trimmed(raw_group.get("displayName"))
                or "Gemini Models",
                "buckets": [
                    bucket for bucket in buckets or [] if isinstance(bucket, dict)
                ]
                if isinstance(buckets, list)
                else [],
            }
        )
    return groups


def _snapshot(payload: dict[str, Any], tier: str | None) -> ProviderSnapshot:
    groups = _normalized_groups(payload)
    if not groups:
        return _failure("Gemini quota response returned no model groups.")
    primary = groups[0]
    primary_buckets = primary["buckets"]
    five_hour = next(
        (bucket for bucket in primary_buckets if _bucket_kind(bucket) == "5h"),
        None,
    )
    weekly = next(
        (bucket for bucket in primary_buckets if _bucket_kind(bucket) == "Week"),
        None,
    )
    additional_windows: list[ModelUsageWindow] = []
    for group in groups[1:]:
        for bucket in group["buckets"]:
            kind = _bucket_kind(bucket)
            if kind is None:
                continue
            label = _trimmed(bucket.get("displayName")) or kind
            additional_windows.append(
                ModelUsageWindow(
                    model_name=f"{group['display_name']} · {label}",
                    window=_window(bucket, kind, "Quota unavailable."),
                )
            )
    detail = " · ".join(
        value for value in (primary["display_name"], tier) if value
    )
    return ProviderSnapshot(
        provider="Gemini",
        five_hour=_window(
            five_hour, "5h", "No Gemini 5h limit returned."
        ),
        weekly=_window(
            weekly, "Week", "No Gemini weekly limit returned."
        ),
        model_windows=additional_windows,
        detail=detail or None,
    )


def _failure(message: str) -> ProviderSnapshot:
    return ProviderSnapshot(
        provider="Gemini",
        five_hour=UsageWindow(kind="5h", message=message),
        weekly=UsageWindow(kind="Week", message=message),
    )


async def fetch_gemini_usage(
    timeout: float = 20,
    credential: AgyCredential | None = None,
    home: Path | None = None,
    environment: Mapping[str, str] | None = None,
    raw_keyring: str | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> ProviderSnapshot:
    """Return Gemini weekly and five-hour usage through agy's quota service."""

    try:
        credential = credential or load_agy_credential(
            home, environment, raw_keyring
        )
        async with httpx.AsyncClient(timeout=timeout, transport=transport) as client:
            access_token = credential.access_token
            if _needs_refresh(credential):
                access_token = await _refresh_access_token(
                    client, credential.refresh_token
                )
            try:
                payload, tier, _ = await _fetch_summary(client, access_token)
            except AgyAuthenticationError:
                access_token = await _refresh_access_token(
                    client, credential.refresh_token
                )
                payload, tier, _ = await _fetch_summary(client, access_token)
        return _snapshot(payload, tier)
    except (AgyError, httpx.HTTPError) as error:
        return _failure(str(error))
