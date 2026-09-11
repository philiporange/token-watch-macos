"""Verify Claude credential priority and usage response normalization."""

import asyncio
import json
from pathlib import Path

import httpx

from aipace_server.claude import (
    DEFAULT_OAUTH_SCOPES,
    ClaudeCredentials,
    CredentialLoader,
    _refresh_scope,
    fetch_claude_usage,
)


def test_file_credentials_take_priority_over_environment(tmp_path: Path) -> None:
    credentials_path = tmp_path / ".claude" / ".credentials.json"
    credentials_path.parent.mkdir()
    credentials_path.write_text(
        json.dumps(
            {
                "claudeAiOauth": {
                    "accessToken": "file-token",
                    "expiresAt": 9_999_999_999_999,
                }
            }
        )
    )

    credentials = CredentialLoader(
        home=tmp_path,
        environment={"CLAUDE_CODE_OAUTH_TOKEN": "environment-token"},
    ).resolve()

    assert credentials is not None
    assert credentials.access_token == "file-token"
    assert credentials.source == "file"


def test_usage_response_includes_scoped_model_limits(tmp_path: Path) -> None:
    credentials_path = tmp_path / ".claude" / ".credentials.json"
    credentials_path.parent.mkdir()
    credentials_path.write_text(
        json.dumps(
            {
                "claudeAiOauth": {
                    "accessToken": "token",
                    "expiresAt": 9_999_999_999_999,
                    "subscriptionType": "claude_max",
                }
            }
        )
    )

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["Authorization"] == "Bearer token"
        return httpx.Response(
            200,
            json={
                "five_hour": {"utilization": 15, "resets_at": "2026-07-16T12:00:00Z"},
                "seven_day": {"utilization": 40, "resets_at": "2026-07-20T12:00:00Z"},
                "limits": [
                    {
                        "kind": "weekly_scoped",
                        "percent": 33,
                        "resets_at": "2026-07-20T12:00:00Z",
                        "scope": {"model": {"display_name": "Fable"}},
                        "is_active": True,
                    }
                ],
            },
        )

    snapshot = asyncio.run(
        fetch_claude_usage(
            loader=CredentialLoader(home=tmp_path, environment={}),
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.five_hour.used_percentage == 15
    assert snapshot.weekly.used_percentage == 40
    assert snapshot.model_windows[0].model_name == "Fable"
    assert snapshot.model_windows[0].is_active is True
    assert snapshot.detail == "Max"


def _write_credentials(home: Path, oauth: dict) -> Path:
    path = home / ".claude" / ".credentials.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"claudeAiOauth": oauth}))
    return path


def _keychain(loader: CredentialLoader, oauth: dict | None) -> None:
    """Stub the Keychain lookup, which otherwise shells out to `security`."""

    def _load(self=loader):  # noqa: ANN001
        if oauth is None:
            return None
        return self._from_root({"claudeAiOauth": oauth}, "keychain")

    loader._load_keychain = _load  # type: ignore[method-assign]


def test_stale_file_does_not_shadow_live_keychain(tmp_path: Path) -> None:
    """A leftover credentials file must lose to a valid Keychain entry."""

    _write_credentials(
        tmp_path,
        {"accessToken": "stale", "refreshToken": "dead", "expiresAt": 1_700_000_000_000},
    )
    loader = CredentialLoader(home=tmp_path, environment={})
    _keychain(loader, {"accessToken": "live", "expiresAt": 9_999_999_999_999})

    credentials = loader.resolve()

    assert credentials is not None
    assert credentials.source == "keychain"
    assert credentials.access_token == "live"


def test_file_keeps_priority_when_both_sources_are_live(tmp_path: Path) -> None:
    _write_credentials(tmp_path, {"accessToken": "file", "expiresAt": 9_999_999_999_999})
    loader = CredentialLoader(home=tmp_path, environment={})
    _keychain(loader, {"accessToken": "keychain", "expiresAt": 9_999_999_999_999})

    credentials = loader.resolve()

    assert credentials is not None
    assert credentials.source == "file"


def test_latest_expiry_wins_when_both_sources_are_stale(tmp_path: Path) -> None:
    _write_credentials(tmp_path, {"accessToken": "older", "expiresAt": 1_700_000_000_000})
    loader = CredentialLoader(home=tmp_path, environment={})
    _keychain(loader, {"accessToken": "newer", "expiresAt": 1_800_000_000_000})

    credentials = loader.resolve()

    assert credentials is not None
    assert credentials.access_token == "newer"


def test_scopes_are_parsed_and_survive_a_save(tmp_path: Path) -> None:
    """Saving must not strip sibling keys the Claude CLI relies on."""

    path = _write_credentials(
        tmp_path,
        {
            "accessToken": "token",
            "refreshToken": "refresh",
            "expiresAt": 9_999_999_999_999,
            "scopes": ["user:profile", "user:mcp_servers"],
            "refreshTokenExpiresAt": 1_788_033_826_690,
            "rateLimitTier": "default_claude_max_20x",
        },
    )
    loader = CredentialLoader(home=tmp_path, environment={})
    _keychain(loader, None)

    credentials = loader.resolve()
    assert credentials is not None
    assert credentials.scopes == ["user:profile", "user:mcp_servers"]

    credentials.access_token = "rotated"
    loader.save(credentials)

    oauth = json.loads(path.read_text())["claudeAiOauth"]
    assert oauth["accessToken"] == "rotated"
    assert oauth["scopes"] == ["user:profile", "user:mcp_servers"]
    assert oauth["refreshTokenExpiresAt"] == 1_788_033_826_690
    assert oauth["rateLimitTier"] == "default_claude_max_20x"


def _credentials(scopes: list[str] | None) -> ClaudeCredentials:
    return ClaudeCredentials(
        access_token="token",
        refresh_token="refresh",
        expires_at=None,
        subscription_type=None,
        source="keychain",
        full_data={},
        scopes=scopes,
    )


def test_refresh_replays_the_granted_scopes() -> None:
    """Refreshing with a narrower fixed list would down-scope the rotated token."""

    stored = ["user:profile", "user:inference", "user:mcp_servers", "user:file_upload"]
    assert _refresh_scope(_credentials(stored)) == " ".join(stored)


def test_refresh_falls_back_to_the_cli_scopes() -> None:
    expected = " ".join(DEFAULT_OAUTH_SCOPES)
    assert _refresh_scope(_credentials(None)) == expected
    assert _refresh_scope(_credentials([])) == expected
    assert "user:mcp_servers" in DEFAULT_OAUTH_SCOPES
