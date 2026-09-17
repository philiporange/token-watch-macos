"""Verify Command Code credential isolation, request headers, and quota normalization."""

import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path

import httpx
import pytest

from aipace_server.commandcode import (
    CommandCodeError,
    fetch_commandcode_usage,
    load_commandcode_api_key,
    plan_info,
)


def test_env_key_wins_over_auth_file(tmp_path: Path) -> None:
    config_dir = tmp_path / ".commandcode"
    config_dir.mkdir(parents=True, exist_ok=True)
    auth_file = config_dir / "auth.json"
    auth_file.write_text(json.dumps({"apiKey": "file-key"}))

    api_key = load_commandcode_api_key(
        home=tmp_path,
        environment={"COMMANDCODE_API_KEY": "env-key"},
    )
    assert api_key == "env-key"


def test_auth_file_fallback(tmp_path: Path) -> None:
    config_dir = tmp_path / ".commandcode"
    config_dir.mkdir(parents=True, exist_ok=True)
    auth_file = config_dir / "auth.json"
    auth_file.write_text(json.dumps({"apiKey": "file-key"}))

    api_key = load_commandcode_api_key(home=tmp_path, environment={})
    assert api_key == "file-key"


def test_credentials_not_found_raises(tmp_path: Path) -> None:
    with pytest.raises(
        CommandCodeError,
        match="Command Code credentials not found. Run command-code and sign in.",
    ):
        load_commandcode_api_key(home=tmp_path, environment={})


def test_plan_info_longest_prefix_match() -> None:
    assert plan_info("individual-goat-x") == ("GOAT", 70.0)
    assert plan_info("individual_pro_v1") == ("Pro", 80.0)
    assert plan_info("individual-pro") == ("Pro", 30.0)
    assert plan_info("nonexistent-plan") is None


def test_fetch_commandcode_usage_end_to_end() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.headers["Authorization"] == "Bearer test-key"
        assert request.headers["Accept"] == "application/json"
        assert request.headers["User-Agent"] == "AIPace"

        if "/alpha/billing/credits" in str(request.url):
            return httpx.Response(
                200,
                json={
                    "credits": {
                        "monthlyCredits": 9.456792772,
                        "purchasedCredits": 0,
                        "freeCredits": 0,
                    },
                    "windowLimits": {
                        "limited": True,
                        "fiveHour": {
                            "used": 0.533506296,
                            "cap": 3,
                            "exceeded": False,
                            "resetAt": 1789624802266,
                        },
                        "weekly": {
                            "used": 0.533506296,
                            "cap": 6,
                            "exceeded": False,
                            "resetAt": 1790211602266,
                        },
                    },
                },
            )

        if "/alpha/billing/subscriptions" in str(request.url):
            return httpx.Response(
                200,
                json={
                    "success": True,
                    "data": {
                        "planId": "individual-go",
                        "currentPeriodEnd": "2026-09-20T22:26:41.000Z",
                        "status": "active",
                    },
                },
            )

        return httpx.Response(404)

    snapshot = asyncio.run(
        fetch_commandcode_usage(
            api_key="test-key",
            transport=httpx.MockTransport(handler),
        )
    )

    assert len(requests) == 2
    assert snapshot.provider == "Command Code"
    assert snapshot.five_hour.used_percentage == pytest.approx(17.7835, abs=1e-3)
    assert snapshot.weekly.used_percentage == pytest.approx(8.8918, abs=1e-3)
    assert snapshot.five_hour.resets_at == datetime.fromtimestamp(
        1789624802266 / 1000, timezone.utc
    )
    assert snapshot.weekly.resets_at == datetime.fromtimestamp(
        1790211602266 / 1000, timezone.utc
    )
    assert len(snapshot.model_windows) == 1
    model_window = snapshot.model_windows[0]
    assert model_window.model_name == "Credits"
    assert model_window.is_active is True
    assert model_window.window.used_percentage == pytest.approx(5.4321, abs=1e-3)
    assert model_window.window.resets_at == datetime(
        2026, 9, 20, 22, 26, 41, tzinfo=timezone.utc
    )
    assert snapshot.detail == "Go plan · $9.46 credits left"


def test_fetch_commandcode_usage_auth_failure() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={})

    snapshot = asyncio.run(
        fetch_commandcode_usage(
            api_key="invalid-key",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "Command Code"
    assert (
        snapshot.five_hour.message
        == snapshot.weekly.message
        == "Command Code authentication failed. Run command-code and sign in again."
    )


def test_fetch_commandcode_subscription_failure_is_best_effort() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if "/alpha/billing/credits" in str(request.url):
            return httpx.Response(
                200,
                json={
                    "credits": {
                        "monthlyCredits": 9.456792772,
                        "purchasedCredits": 0,
                        "freeCredits": 0,
                    },
                    "windowLimits": {
                        "limited": True,
                        "fiveHour": {
                            "used": 0.533506296,
                            "cap": 3,
                            "exceeded": False,
                            "resetAt": 1789624802266,
                        },
                        "weekly": {
                            "used": 0.533506296,
                            "cap": 6,
                            "exceeded": False,
                            "resetAt": 1790211602266,
                        },
                    },
                },
            )
        return httpx.Response(500, text="Internal Server Error")

    snapshot = asyncio.run(
        fetch_commandcode_usage(
            api_key="test-key",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "Command Code"
    assert snapshot.five_hour.used_percentage == pytest.approx(17.7835, abs=1e-3)
    assert snapshot.model_windows == []
    assert snapshot.detail == "$9.46 credits left"


def test_fetch_commandcode_handles_server_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="Internal Server Error")

    snapshot = asyncio.run(
        fetch_commandcode_usage(
            api_key="test-key",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "Command Code"
    assert snapshot.five_hour.message == "Command Code returned HTTP 500."
    assert snapshot.weekly.message == "Command Code returned HTTP 500."


def test_fetch_commandcode_handles_missing_credentials(tmp_path: Path) -> None:
    snapshot = asyncio.run(
        fetch_commandcode_usage(
            home=tmp_path,
            environment={},
        )
    )

    assert snapshot.provider == "Command Code"
    assert (
        snapshot.five_hour.message
        == "Command Code credentials not found. Run command-code and sign in."
    )
    assert (
        snapshot.weekly.message
        == "Command Code credentials not found. Run command-code and sign in."
    )


def test_fetch_commandcode_handles_invalid_json_response() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"not json")

    snapshot = asyncio.run(
        fetch_commandcode_usage(
            api_key="test-key",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "Command Code"
    assert snapshot.five_hour.message == "Command Code response could not be read."
    assert snapshot.weekly.message == "Command Code response could not be read."


def test_fetch_commandcode_handles_missing_limits() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json={"windowLimits": {}})

    snapshot = asyncio.run(
        fetch_commandcode_usage(
            api_key="test-key",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "Command Code"
    assert snapshot.five_hour.message == "No 5h limit returned."
    assert snapshot.weekly.message == "No weekly limit returned."


def test_plan_info_edge_cases() -> None:
    assert plan_info(None) is None
    assert plan_info("") is None
    assert plan_info("   ") is None
    assert plan_info("INDIVIDUAL-MAX") == ("Max", 150.0)
    assert plan_info("teams_pro_extra") == ("Teams Pro", 40.0)


def test_auth_file_invalid_json_raises(tmp_path: Path) -> None:
    config_dir = tmp_path / ".commandcode"
    config_dir.mkdir(parents=True, exist_ok=True)
    auth_file = config_dir / "auth.json"
    auth_file.write_text("not json")

    with pytest.raises(
        CommandCodeError,
        match="Command Code credentials not found. Run command-code and sign in.",
    ):
        load_commandcode_api_key(home=tmp_path, environment={})
