"""Verify agy credential handling and Gemini quota normalization."""

import asyncio
import base64
from datetime import datetime, timezone
import json
from pathlib import Path

import httpx

from aipace_server.gemini import (
    AgyCredential,
    decode_agy_secret,
    fetch_gemini_usage,
    load_agy_credential,
)


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
