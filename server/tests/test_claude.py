"""Verify Claude credential priority and usage response normalization."""

import asyncio
import json
from pathlib import Path

import httpx

from aipace_server.claude import CredentialLoader, fetch_claude_usage


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
