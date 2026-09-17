"""Verify AliCloud ticket isolation, request headers, and quota normalization."""

import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib

import httpx
import pytest

from aipace_server.alicloud import (
    AliCloudError,
    fetch_alicloud_usage,
    load_alicloud_ticket,
)


def test_env_ticket_wins_over_dotenv_file(tmp_path: Path) -> None:
    (tmp_path / ".env").write_text("ALICLOUD_CONSOLE_TICKET=env-file-ticket\n")

    ticket = load_alicloud_ticket(
        home=tmp_path,
        environment={"ALICLOUD_CONSOLE_TICKET": "env-ticket"},
    )
    assert ticket == "env-ticket"


def test_dotenv_fallback(tmp_path: Path) -> None:
    (tmp_path / ".env").write_text("ALICLOUD_CONSOLE_TICKET=env-file-ticket\n")

    ticket = load_alicloud_ticket(home=tmp_path, environment={})
    assert ticket == "env-file-ticket"


def test_muon_plist_fallback(tmp_path: Path) -> None:
    sessions_dir = (
        tmp_path / "Library" / "Application Support" / "Muon" / "website-sessions"
    )
    sessions_dir.mkdir(parents=True, exist_ok=True)
    plist_file = sessions_dir / "default.plist"
    with plist_file.open("wb") as fp:
        plistlib.dump(
            {
                "cookies": [
                    {
                        "Domain": ".example.com",
                        "Name": "other_cookie",
                        "Value": "ignored",
                    },
                    {
                        "Domain": ".alibabacloud.com",
                        "Name": "login_aliyunid_ticket",
                        "Value": "muon-ticket",
                    },
                ]
            },
            fp,
        )

    ticket = load_alicloud_ticket(home=tmp_path, environment={})
    assert ticket == "muon-ticket"


def test_credentials_not_found_raises(tmp_path: Path) -> None:
    with pytest.raises(
        AliCloudError,
        match="AliCloud credentials not found. Sign in to the Model Studio console in Muon or set ALICLOUD_CONSOLE_TICKET.",
    ):
        load_alicloud_ticket(home=tmp_path, environment={})


def test_fetch_alicloud_usage_end_to_end() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.method == "POST"
        assert request.headers["Cookie"] == "login_aliyunid_ticket=muon-ticket"
        assert request.headers["Content-Type"] == "application/x-www-form-urlencoded"
        assert request.headers["Accept"] == "application/json"
        assert request.headers["User-Agent"] == "AIPace"

        form = httpx.QueryParams(request.content.decode())
        assert form.get("region") == "ap-southeast-1"
        params = json.loads(form.get("params", "{}"))

        if "usage" in request.url.params.get("api", "") or len(requests) == 1:
            assert "api=zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage" in str(
                request.url
            )
            assert params == {
                "Api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
                "V": "1.0",
                "Data": {"cornerstoneParam": {"switchUserType": 3}},
            }
            return httpx.Response(
                200,
                json={
                    "code": "200",
                    "data": {
                        "DataV2": {
                            "data": {
                                "code": "SUCCESS",
                                "data": {
                                    "per1WeekResetTime": 1790211240000,
                                    "per1WeekPercentage": 0.00025387552460000003,
                                },
                            }
                        },
                        "success": True,
                        "errorCode": "",
                    },
                },
            )

        assert (
            "api=zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
            in str(request.url)
        )
        assert params == {
            "Api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription",
            "V": "1.0",
            "Data": {
                "queryInstanceInfoRequest": {},
                "cornerstoneParam": {"switchUserType": 3},
            },
        }
        return httpx.Response(
            200,
            json={
                "code": "200",
                "data": {
                    "DataV2": {
                        "data": {
                            "code": "SUCCESS",
                            "data": {
                                "instanceCode": "inst-123",
                                "specCode": "lite",
                                "remainingDays": 4,
                                "startTime": 1780000000000,
                                "endTime": 1790006400000,
                                "autoRenewFlag": False,
                                "status": "VALID",
                            },
                        }
                    },
                    "success": True,
                    "errorCode": "",
                },
            },
        )

    snapshot = asyncio.run(
        fetch_alicloud_usage(
            ticket="muon-ticket",
            transport=httpx.MockTransport(handler),
        )
    )

    assert len(requests) == 2
    assert snapshot.provider == "AliCloud"
    assert snapshot.five_hour.kind == "5h"
    assert snapshot.five_hour.message == "Token Plan has no 5h window."
    assert snapshot.five_hour.used_percentage is None
    assert snapshot.weekly.kind == "Week"
    assert snapshot.weekly.used_percentage == pytest.approx(0.0253875, abs=1e-5)
    assert snapshot.weekly.resets_at == datetime.fromtimestamp(
        1790211240000 / 1000, timezone.utc
    )
    assert snapshot.detail == "Lite plan · 4 days left"


def test_fetch_alicloud_session_expired() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "code": "200",
                "data": {
                    "success": False,
                    "errorCode": "BailianGateway.Login.NotLogined",
                    "errorMsg": "BailianGateway.Login.NotLogined",
                },
            },
        )

    snapshot = asyncio.run(
        fetch_alicloud_usage(
            ticket="expired-ticket",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "AliCloud"
    assert (
        snapshot.five_hour.message
        == snapshot.weekly.message
        == "AliCloud session expired. Sign in to the Model Studio console again."
    )


def test_fetch_alicloud_subscription_failure_is_best_effort() -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if calls == 1:
            return httpx.Response(
                200,
                json={
                    "code": "200",
                    "data": {
                        "DataV2": {
                            "data": {
                                "code": "SUCCESS",
                                "data": {
                                    "per1WeekResetTime": 1790211240000,
                                    "per1WeekPercentage": 0.5,
                                },
                            }
                        },
                        "success": True,
                        "errorCode": "",
                    },
                },
            )
        return httpx.Response(500, text="Internal Server Error")

    snapshot = asyncio.run(
        fetch_alicloud_usage(
            ticket="my-ticket",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "AliCloud"
    assert snapshot.weekly.used_percentage == 50.0
    assert snapshot.detail is None


def test_fetch_alicloud_handles_server_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="Internal Server Error")

    snapshot = asyncio.run(
        fetch_alicloud_usage(
            ticket="my-ticket",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "AliCloud"
    assert snapshot.five_hour.message == "AliCloud console returned HTTP 500."
    assert snapshot.weekly.message == "AliCloud console returned HTTP 500."


def test_fetch_alicloud_handles_other_error_code() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "code": "200",
                "data": {
                    "success": False,
                    "errorCode": "CustomGatewayError",
                },
            },
        )

    snapshot = asyncio.run(
        fetch_alicloud_usage(
            ticket="my-ticket",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "AliCloud"
    assert (
        snapshot.five_hour.message
        == snapshot.weekly.message
        == "AliCloud console returned CustomGatewayError."
    )


def test_muon_skips_invalid_plist(tmp_path: Path) -> None:
    sessions_dir = (
        tmp_path / "Library" / "Application Support" / "Muon" / "website-sessions"
    )
    sessions_dir.mkdir(parents=True, exist_ok=True)
    corrupt_file = sessions_dir / "00_corrupt.plist"
    corrupt_file.write_text("not a valid plist content")

    valid_file = sessions_dir / "01_valid.plist"
    with valid_file.open("wb") as fp:
        plistlib.dump(
            {
                "cookies": [
                    {
                        "Domain": ".alibabacloud.com",
                        "Name": "login_aliyunid_ticket",
                        "Value": "valid-muon-ticket",
                    },
                ]
            },
            fp,
        )

    ticket = load_alicloud_ticket(home=tmp_path, environment={})
    assert ticket == "valid-muon-ticket"
