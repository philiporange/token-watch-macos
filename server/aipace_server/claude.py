"""Collect Claude usage with credentials maintained by the Claude Code CLI.

Credentials are resolved from ``~/.claude/.credentials.json``, macOS Keychain,
then ``CLAUDE_CODE_OAUTH_TOKEN``. Expiring refreshable credentials are renewed
and persisted before calling Anthropic's OAuth usage endpoint.
"""

from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timezone
import asyncio
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from typing import Any, Mapping

import httpx

from aipace_server.models import ModelUsageWindow, ProviderSnapshot, UsageWindow
from aipace_server.processes import find_executable, process_environment


USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
REFRESH_URL = "https://platform.claude.com/v1/oauth/token"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
KEYCHAIN_SERVICE = "Claude Code-credentials"
REFRESH_BUFFER_MS = 5 * 60 * 1000
_fetch_lock = asyncio.Lock()


class ClaudeError(RuntimeError):
    """Report a failure to load credentials or retrieve Claude usage."""


class ClaudeAuthenticationError(ClaudeError):
    """Signal that a usage request should be retried after token refresh."""


@dataclass
class ClaudeCredentials:
    """OAuth data plus the source document needed for safe persistence."""

    access_token: str
    refresh_token: str | None
    expires_at: float | None
    subscription_type: str | None
    source: str
    full_data: dict[str, Any]


def _trimmed(value: Any) -> str | None:
    """Return non-empty trimmed strings from loosely typed credential JSON."""

    if not isinstance(value, str):
        return None
    result = value.strip()
    return result or None


def _numeric(value: Any) -> float | None:
    """Parse a credential timestamp represented as a JSON number or string."""

    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float, str)):
        try:
            return float(value)
        except ValueError:
            return None
    return None


class CredentialLoader:
    """Resolve and persist Claude Code OAuth credentials."""

    def __init__(
        self,
        home: Path | None = None,
        environment: Mapping[str, str] | None = None,
    ) -> None:
        self.home = home or Path.home()
        self.environment = environment if environment is not None else os.environ

    def resolve(self) -> ClaudeCredentials | None:
        """Load credentials in the same priority order as native AIPace."""

        credentials = self._load_file()
        if credentials is not None:
            return credentials

        keychain_error = None
        try:
            credentials = self._load_keychain()
        except ClaudeError as error:
            keychain_error = error
        if credentials is not None:
            return credentials

        credentials = self._load_environment()
        if credentials is not None:
            return credentials
        if keychain_error is not None:
            raise keychain_error
        return None

    def needs_refresh(self, credentials: ClaudeCredentials) -> bool:
        """Return whether the token expires within the five-minute buffer."""

        if credentials.expires_at is None:
            return True
        return time.time() * 1000 + REFRESH_BUFFER_MS >= credentials.expires_at

    def save(self, credentials: ClaudeCredentials) -> None:
        """Persist refreshed OAuth values back to their original source."""

        try:
            if credentials.source == "file":
                self._save_file(credentials)
            elif credentials.source == "keychain":
                self._save_keychain(credentials)
        except (OSError, subprocess.SubprocessError):
            pass

    def _load_file(self) -> ClaudeCredentials | None:
        path = self.home / ".claude" / ".credentials.json"
        try:
            root = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            return None
        return self._from_root(root, "file")

    def _load_keychain(self) -> ClaudeCredentials | None:
        security = "/usr/bin/security"
        if not os.access(security, os.X_OK):
            return None
        try:
            result = subprocess.run(
                [security, "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError) as error:
            raise ClaudeError(f"Claude Keychain lookup failed: {error}") from error
        if result.returncode != 0:
            message = (result.stderr or result.stdout).strip()
            normalized = message.lower()
            if (
                "could not be found in the keychain" in normalized
                or "item could not be found" in normalized
            ):
                return None
            if any(
                phrase in normalized
                for phrase in (
                    "user interaction is not allowed",
                    "authorization was denied",
                    "user canceled",
                    "user cancelled",
                )
            ):
                raise ClaudeError("Claude Keychain access denied.")
            suffix = f": {message}" if message else "."
            raise ClaudeError(f"Claude Keychain lookup failed{suffix}")
        try:
            root = json.loads(result.stdout)
        except json.JSONDecodeError:
            return None
        return self._from_root(root, "keychain")

    def _load_environment(self) -> ClaudeCredentials | None:
        token = _trimmed(self.environment.get("CLAUDE_CODE_OAUTH_TOKEN"))
        if token is None:
            return None
        return ClaudeCredentials(token, None, None, None, "environment", {})

    def _from_root(self, root: Any, source: str) -> ClaudeCredentials | None:
        if not isinstance(root, dict) or not isinstance(
            root.get("claudeAiOauth"), dict
        ):
            return None
        oauth = root["claudeAiOauth"]
        access_token = _trimmed(oauth.get("accessToken"))
        if access_token is None:
            return None
        return ClaudeCredentials(
            access_token=access_token,
            refresh_token=_trimmed(oauth.get("refreshToken")),
            expires_at=_numeric(oauth.get("expiresAt")),
            subscription_type=_trimmed(oauth.get("subscriptionType")),
            source=source,
            full_data=root,
        )

    def _updated_root(self, credentials: ClaudeCredentials) -> dict[str, Any]:
        root = deepcopy(credentials.full_data)
        oauth: dict[str, Any] = {"accessToken": credentials.access_token}
        if credentials.refresh_token is not None:
            oauth["refreshToken"] = credentials.refresh_token
        if credentials.expires_at is not None:
            oauth["expiresAt"] = credentials.expires_at
        if credentials.subscription_type is not None:
            oauth["subscriptionType"] = credentials.subscription_type
        root["claudeAiOauth"] = oauth
        return root

    def _save_file(self, credentials: ClaudeCredentials) -> None:
        path = self.home / ".claude" / ".credentials.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        serialized = (
            json.dumps(self._updated_root(credentials), indent=2, sort_keys=True) + "\n"
        )
        with tempfile.NamedTemporaryFile(
            mode="w",
            dir=path.parent,
            prefix=".credentials.",
            delete=False,
        ) as temporary_file:
            temporary_file.write(serialized)
            os.fchmod(temporary_file.fileno(), 0o600)
            temporary_path = Path(temporary_file.name)
        try:
            temporary_path.replace(path)
        finally:
            temporary_path.unlink(missing_ok=True)

    def _save_keychain(self, credentials: ClaudeCredentials) -> None:
        security = "/usr/bin/security"
        value = json.dumps(self._updated_root(credentials), indent=2)
        subprocess.run(
            [security, "delete-generic-password", "-s", KEYCHAIN_SERVICE],
            capture_output=True,
            timeout=10,
        )
        subprocess.run(
            [security, "add-generic-password", "-s", KEYCHAIN_SERVICE, "-w", value],
            capture_output=True,
            check=True,
            timeout=10,
        )


def _account_detail(home: Path, subscription_type: str | None) -> str | None:
    """Build the optional plan and account label shown by native AIPace."""

    tier_names = {
        "claude_max": "Max",
        "max": "Max",
        "claude_pro": "Pro",
        "pro": "Pro",
        "api": "API",
        "claude_api": "API",
    }
    tier = (
        tier_names.get(subscription_type.lower(), subscription_type)
        if subscription_type
        else None
    )
    identity = None
    try:
        root = json.loads((home / ".claude.json").read_text())
        account = root.get("oauthAccount")
        if isinstance(account, dict):
            identity = next(
                (
                    value
                    for value in (
                        account.get("displayName"),
                        account.get("emailAddress"),
                        account.get("organizationName"),
                    )
                    if isinstance(value, str)
                ),
                None,
            )
    except (OSError, json.JSONDecodeError):
        pass
    detail = " · ".join(value for value in (tier, identity) if value)
    return detail or None


def _parse_date(value: Any) -> datetime | None:
    """Parse the ISO-8601 reset formats returned by Anthropic."""

    if not isinstance(value, str):
        return None
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return result if result.tzinfo else result.replace(tzinfo=timezone.utc)


async def _refresh_credentials(
    credentials: ClaudeCredentials,
    loader: CredentialLoader,
    client: httpx.AsyncClient,
) -> ClaudeCredentials:
    """Refresh OAuth credentials and save rotating token values."""

    if credentials.refresh_token is None:
        raise ClaudeError("Claude session expired; log in again.")
    response = await client.post(
        REFRESH_URL,
        json={
            "grant_type": "refresh_token",
            "refresh_token": credentials.refresh_token,
            "client_id": CLIENT_ID,
            "scope": "user:profile user:inference user:sessions:claude_code",
        },
    )
    if response.status_code in (400, 401):
        raise ClaudeError("Claude session expired; log in again.")
    if not response.is_success:
        raise ClaudeError(
            f"Claude token refresh failed with HTTP {response.status_code}."
        )
    try:
        payload = response.json()
    except ValueError as error:
        raise ClaudeError(
            "Claude token refresh returned an invalid response."
        ) from error
    if not isinstance(payload, dict):
        raise ClaudeError("Claude token refresh returned an invalid response.")
    access_token = _trimmed(payload.get("access_token"))
    if access_token is None:
        raise ClaudeError("Claude token refresh returned no access token.")
    credentials.access_token = access_token
    credentials.refresh_token = (
        _trimmed(payload.get("refresh_token")) or credentials.refresh_token
    )
    expires_in = _numeric(payload.get("expires_in"))
    if expires_in is not None:
        credentials.expires_at = time.time() * 1000 + expires_in * 1000
    loader.save(credentials)
    return credentials


async def _fetch_usage(
    access_token: str,
    client: httpx.AsyncClient,
) -> dict[str, Any]:
    """Request Claude quota usage using the Claude Code OAuth token."""

    response = await client.get(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {access_token.strip()}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "AIPace",
        },
    )
    if response.status_code in (401, 403):
        raise ClaudeAuthenticationError("Claude authentication failed.")
    if not response.is_success:
        raise ClaudeError(
            f"Claude usage endpoint returned HTTP {response.status_code}."
        )
    try:
        payload = response.json()
    except ValueError as error:
        raise ClaudeError(
            "Claude usage endpoint returned an invalid response."
        ) from error
    if not isinstance(payload, dict):
        raise ClaudeError("Claude usage endpoint returned an invalid response.")
    return payload


async def _is_logged_in() -> bool:
    """Ask Claude Code whether it is logged in when credentials are unavailable."""

    executable = find_executable("claude")
    if executable is None:
        return False
    process = None
    try:
        process = await asyncio.create_subprocess_exec(
            executable,
            "auth",
            "status",
            "--json",
            cwd=Path.home(),
            env=process_environment(),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(process.communicate(), timeout=10)
        return json.loads(stdout).get("loggedIn") is True
    except (OSError, ValueError, json.JSONDecodeError, asyncio.TimeoutError):
        return False
    finally:
        if process is not None and process.returncode is None:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=1)
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()


def _quota_window(kind: str, payload: Any, missing_message: str) -> UsageWindow:
    """Convert an Anthropic quota object to the shared API model."""

    if not isinstance(payload, dict):
        return UsageWindow(kind=kind, message=missing_message)
    utilization = _numeric(payload.get("utilization"))
    return UsageWindow(
        kind=kind,
        used_percentage=utilization,
        resets_at=_parse_date(payload.get("resets_at")),
    )


def _model_windows(limits: Any) -> list[ModelUsageWindow]:
    """Filter and prioritize weekly model-scoped Claude limits."""

    if not isinstance(limits, list):
        return []
    normalized = []
    for limit in limits:
        if not isinstance(limit, dict) or limit.get("kind") != "weekly_scoped":
            continue
        percent = _numeric(limit.get("percent"))
        scope = limit.get("scope")
        model = scope.get("model") if isinstance(scope, dict) else None
        name = _trimmed(model.get("display_name")) if isinstance(model, dict) else None
        if percent is None or name is None:
            continue
        normalized.append((limit, percent, name))

    normalized.sort(
        key=lambda item: (
            "fable" not in item[2].lower(),
            not bool(item[0].get("is_active", False)),
            -item[1],
        )
    )
    return [
        ModelUsageWindow(
            model_name=name,
            window=UsageWindow(
                kind="Model",
                used_percentage=percent,
                resets_at=_parse_date(limit.get("resets_at")),
            ),
            is_active=bool(limit.get("is_active", False)),
        )
        for limit, percent, name in normalized
    ]


async def _fetch_claude_usage_unlocked(
    timeout: float = 20,
    loader: CredentialLoader | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> ProviderSnapshot:
    """Return the current Claude usage snapshot, including provider-local errors."""

    loader = loader or CredentialLoader()
    try:
        credentials = loader.resolve()
        if credentials is None:
            if await _is_logged_in():
                raise ClaudeError(
                    "Claude is logged in, but credentials could not be read from "
                    "file, Keychain, or environment."
                )
            raise ClaudeError("Claude credentials not found.")

        async with httpx.AsyncClient(timeout=timeout, transport=transport) as client:
            if (
                loader.needs_refresh(credentials)
                and credentials.source != "environment"
            ):
                credentials = await _refresh_credentials(credentials, loader, client)
            try:
                usage = await _fetch_usage(credentials.access_token, client)
            except ClaudeAuthenticationError:
                if (
                    credentials.source == "environment"
                    or credentials.refresh_token is None
                ):
                    raise
                credentials = await _refresh_credentials(credentials, loader, client)
                usage = await _fetch_usage(credentials.access_token, client)

        return ProviderSnapshot(
            provider="Claude",
            five_hour=_quota_window(
                "5h", usage.get("five_hour"), "No 5h limit returned."
            ),
            weekly=_quota_window(
                "Week", usage.get("seven_day"), "No weekly limit returned."
            ),
            model_windows=_model_windows(usage.get("limits")),
            detail=_account_detail(loader.home, credentials.subscription_type),
        )
    except (ClaudeError, httpx.HTTPError, OSError, subprocess.SubprocessError) as error:
        message = str(error)
        return ProviderSnapshot(
            provider="Claude",
            five_hour=UsageWindow(kind="5h", message=message),
            weekly=UsageWindow(kind="Week", message=message),
        )


async def fetch_claude_usage(
    timeout: float = 20,
    loader: CredentialLoader | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
) -> ProviderSnapshot:
    """Serialize Claude reads so rotating refresh tokens cannot race."""

    async with _fetch_lock:
        return await _fetch_claude_usage_unlocked(timeout, loader, transport)
