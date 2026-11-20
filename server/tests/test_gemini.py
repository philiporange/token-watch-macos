"""Verify Gemini quota collection from agy's JSON command and credential API."""

import asyncio
import base64
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess

import httpx
import pytest

from aipace_server import gemini
from aipace_server.gemini import (
    AgyCredential,
    decode_agy_secret,
    fetch_gemini_usage,
    load_agy_credential,
)


@pytest.mark.parametrize("keyring_available", [True, False])
def test_cli_usage_selects_gemini_group_and_keeps_other_quotas(
    monkeypatch: pytest.MonkeyPatch, keyring_available: bool
) -> None:
    calls: list[list[str]] = []
    payload = {
        "status": "SUCCESS",
        "usage": {"total_tokens": 0},
        "command": {
            "name": "usage",
            "data": {
                "groups": [
                    {
                        "name": "Claude and GPT models",
                        "buckets": [{"id": "3p-weekly", "remaining_fraction": 1}],
                    },
                    {
                        "name": "Gemini 4 Argon",
                        "buckets": [
                            {"id": "gemini-argon-wtu-weekly", "remaining_fraction": "NaN"}
                        ],
                    },
                    {
                        "name": "Gemini Models",
                        "buckets": [
                            {
                                "id": "gemini-weekly",
                                "name": "Weekly Limit Remaining",
                                "window": "weekly",
                                "remaining_fraction": 0.9675,
                                "reset_time": "2030-01-02T03:04:05Z",
                            },
                            {"id": "gemini-5h", "remaining_fraction": 0},
                        ],
                    },
                ],
            },
        },
    }

    def run(args: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
        calls.append(args)
        assert kwargs["stdin"] == subprocess.DEVNULL
        assert kwargs["cwd"] == Path.home()
        output = "1.1.11" if args[1:] == ["--version"] else json.dumps(payload)
        return subprocess.CompletedProcess(args, 0, output)

    async def load_tier(
        _client: httpx.AsyncClient, _host: str, method: str, token: str, _body: dict
    ) -> dict:
        assert method == "loadCodeAssist"
        assert token == "agy-access"
        return {"paidTier": {"name": "Google AI Pro"}}

    def load_credential(*_args: object) -> AgyCredential:
        if not keyring_available:
            raise gemini.AgyError("Gemini credentials not found.")
        return AgyCredential(access_token="agy-access")

    monkeypatch.delenv("AGY_OAUTH_TOKEN_FILE", raising=False)
    monkeypatch.setattr(gemini, "find_executable", lambda name: f"/bin/{name}")
    monkeypatch.setattr(gemini.subprocess, "run", run)
    monkeypatch.setattr(gemini, "_post_internal", load_tier)
    monkeypatch.setattr(gemini, "load_agy_credential", load_credential)

    snapshot = asyncio.run(fetch_gemini_usage())

    assert calls == [
        ["/bin/agy", "--version"],
        ["/bin/agy", "--output-format", "json", "-p", "/usage"],
    ]
    assert snapshot.weekly.used_percentage == pytest.approx(3.25)
    assert snapshot.weekly.resets_at == datetime(2030, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    assert snapshot.five_hour.used_percentage == 100
    detail = "Gemini Models · Google AI Pro" if keyring_available else "Gemini Models"
    assert snapshot.detail == detail
    assert [
        (model.model_name, model.window.used_percentage) for model in snapshot.model_windows
    ] == [("Claude and GPT models · Week", 0), ("Gemini 4 Argon · Week", None)]


@pytest.mark.parametrize("version", ["1.1.10", "1.1.11-preview"])
def test_cli_only_checks_version_without_supported_usage(
    monkeypatch: pytest.MonkeyPatch, version: str
) -> None:
    def run(args: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        assert args == ["/bin/agy", "--version"]
        return subprocess.CompletedProcess(args, 0, version)

    monkeypatch.setattr(gemini, "find_executable", lambda name: f"/bin/{name}")
    monkeypatch.setattr(gemini.subprocess, "run", run)

    assert gemini._read_agy_usage(10) is None


def test_configured_token_file_uses_direct_quota_api(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    token_file = tmp_path / "agy-token"
    token_file.write_text('{"access_token":"file-token"}', encoding="utf-8")

    def cli_usage(_timeout: float) -> None:
        pytest.fail("An explicit token file should use the direct quota API.")

    async def direct_request(
        _client: httpx.AsyncClient, _host: str, method: str, token: str, _body: dict
    ) -> dict:
        assert token == "file-token"
        if method == "loadCodeAssist":
            return {"cloudaicompanionProject": "agy-project"}
        assert method == "retrieveUserQuotaSummary"
        return {
            "groups": [
                {
                    "displayName": "Gemini Models",
                    "buckets": [{"bucketId": "gemini-weekly", "remainingFraction": 0.75}],
                },
            ],
        }

    monkeypatch.setenv("AGY_OAUTH_TOKEN_FILE", str(token_file))
    monkeypatch.setattr(gemini, "_read_keyring", lambda: None)
    monkeypatch.setattr(gemini, "_read_agy_usage", cli_usage)
    monkeypatch.setattr(gemini, "_post_internal", direct_request)

    snapshot = asyncio.run(fetch_gemini_usage())

    assert snapshot.weekly.used_percentage == 25


def test_direct_quota_without_generic_gemini_leaves_primary_windows_unavailable() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("v1internal:loadCodeAssist"):
            return httpx.Response(200, json={"cloudaicompanionProject": "agy-project"})
        return httpx.Response(
            200,
            json={
                "groups": [
                    {
                        "displayName": "Claude and GPT models",
                        "buckets": [{"bucketId": "3p-weekly", "remainingFraction": 1}],
                    },
                    {
                        "displayName": "Gemini 4 Argon",
                        "buckets": [{"bucketId": "gemini-argon-wtu-5h", "disabled": True}],
                    },
                ],
            },
        )

    snapshot = asyncio.run(
        fetch_gemini_usage(
            credential=AgyCredential(access_token="agy-access"),
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.weekly.used_percentage is None
    assert snapshot.five_hour.used_percentage is None
    assert snapshot.model_windows[0].window.used_percentage == 0
    assert snapshot.model_windows[1].window.message == "Quota disabled."


def test_decodes_keyring_base64_and_headless_file(tmp_path: Path) -> None:
    payload = {
        "token": {
            "access_token": "agy-access",
            "refresh_token": "agy-refresh",
            "expiry": "2030-01-02T03:04:05Z",
        },
        "auth_method": "consumer",
    }
    raw = json.dumps(payload)
    encoded = "go-keyring-base64:" + base64.b64encode(raw.encode()).decode()

    credential = decode_agy_secret(encoded)

    assert credential.access_token == "agy-access"
    assert credential.refresh_token == "agy-refresh"
    assert credential.expiry == datetime(2030, 1, 2, 3, 4, 5, tzinfo=timezone.utc)
    assert credential.auth_method == "consumer"

    token_file = tmp_path / "agy-token"
    token_file.write_text(raw)
    from_file = load_agy_credential(
        tmp_path,
        {"AGY_OAUTH_TOKEN_FILE": str(token_file)},
        raw_keyring="",
    )
    assert from_file.access_token == "agy-access"


def test_fetch_uses_agy_sequence_and_normalizes_remaining_fraction() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.headers["Authorization"] == "Bearer agy-access"
        if request.url.path.endswith("v1internal:loadCodeAssist"):
            assert json.loads(request.content) == {
                "metadata": {"ideType": "ANTIGRAVITY"}
            }
            return httpx.Response(
                200,
                json={
                    "cloudaicompanionProject": "agy-project",
                    "currentTier": {"id": "standard-tier"},
                },
            )
        assert request.url.path.endswith("v1internal:retrieveUserQuotaSummary")
        assert json.loads(request.content) == {"project": "agy-project"}
        return httpx.Response(
            200,
            json={
                "groups": [
                    {
                        "displayName": "GEMINI MODELS",
                        "buckets": [
                            {
                                "bucketId": "weekly",
                                "displayName": "Weekly Limit",
                                "window": "weekly",
                                "remainingFraction": 0.9172,
                                "resetTime": "2030-01-02T03:04:05Z",
                            },
                            {
                                "bucketId": "five-hour",
                                "displayName": "Five Hour Limit",
                                "window": "5h",
                                "remainingFraction": 0.9463,
                                "resetTime": "2030-01-02T03:04:05Z",
                            },
                        ],
                    },
                    {
                        "displayName": "FLASH MODELS",
                        "buckets": [
                            {
                                "displayName": "Weekly Limit",
                                "window": "weekly",
                                "remainingFraction": 0.75,
                            }
                        ],
                    },
                ]
            },
        )

    snapshot = asyncio.run(
        fetch_gemini_usage(
            credential=AgyCredential(access_token="agy-access"),
            transport=httpx.MockTransport(handler),
        )
    )

    assert len(requests) == 2
    assert requests[0].url.host == "daily-cloudcode-pa.googleapis.com"
    assert snapshot.provider == "Gemini"
    assert abs((snapshot.five_hour.used_percentage or 0) - 5.37) < 0.0001
    assert abs((snapshot.weekly.used_percentage or 0) - 8.28) < 0.0001
    assert snapshot.weekly.resets_at is not None
    assert snapshot.detail == "GEMINI MODELS · standard-tier"
    assert snapshot.model_windows[0].model_name == "FLASH MODELS · Weekly Limit"
    assert snapshot.model_windows[0].window.used_percentage == 25


def test_paid_tier_name_wins_over_current_tier_id() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("v1internal:loadCodeAssist"):
            return httpx.Response(
                200,
                json={
                    "cloudaicompanionProject": "agy-project",
                    "currentTier": {"id": "free-tier", "name": "Antigravity"},
                    "paidTier": {"id": "g1-pro-tier", "name": "Google AI Pro"},
                },
            )
        return httpx.Response(
            200,
            json={
                "groups": [
                    {
                        "displayName": "GEMINI MODELS",
                        "buckets": [
                            {
                                "window": "weekly",
                                "displayName": "Weekly Limit",
                                "remainingFraction": 1,
                            }
                        ],
                    }
                ]
            },
        )

    snapshot = asyncio.run(
        fetch_gemini_usage(
            credential=AgyCredential(access_token="agy-access"),
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.detail == "GEMINI MODELS · Google AI Pro"


def test_expired_token_refreshes_in_memory_before_quota_calls() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url == httpx.URL("https://oauth2.googleapis.com/token"):
            assert b"refresh_token=refresh-me" in request.content
            return httpx.Response(200, json={"access_token": "fresh-token"})
        assert request.headers["Authorization"] == "Bearer fresh-token"
        if request.url.path.endswith("v1internal:loadCodeAssist"):
            return httpx.Response(
                200, json={"cloudaicompanionProject": "agy-project"}
            )
        return httpx.Response(
            200,
            json={
                "groups": [
                    {
                        "displayName": "GEMINI MODELS",
                        "buckets": [],
                    }
                ]
            },
        )

    snapshot = asyncio.run(
        fetch_gemini_usage(
            credential=AgyCredential(
                access_token="expired",
                refresh_token="refresh-me",
                expiry=datetime(2020, 1, 1, tzinfo=timezone.utc),
            ),
            transport=httpx.MockTransport(handler),
        )
    )

    assert len(requests) == 3
    assert snapshot.provider == "Gemini"
    assert snapshot.five_hour.message == "No Gemini 5h limit returned."


def test_daily_host_failure_falls_back_to_production() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "daily-cloudcode-pa.googleapis.com":
            return httpx.Response(404)
        if request.url.path.endswith("v1internal:loadCodeAssist"):
            return httpx.Response(
                200, json={"cloudaicompanionProject": "agy-project"}
            )
        return httpx.Response(
            200,
            json={
                "groups": [
                    {"displayName": "GEMINI MODELS", "buckets": []}
                ]
            },
        )

    snapshot = asyncio.run(
        fetch_gemini_usage(
            credential=AgyCredential(access_token="agy-access"),
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "Gemini"
    assert snapshot.detail == "GEMINI MODELS"
