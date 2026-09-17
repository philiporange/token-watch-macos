"""Verify Muse token isolation, request headers, and quota normalization."""

import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path

import httpx
import pytest

from aipace_server.muse import (
    MuseError,
    fetch_muse_usage,
    load_muse_access_token,
)


def test_file_token_wins_over_keychain_and_honors_xdg(tmp_path: Path) -> None:
    config_dir = tmp_path / "muse"
    config_dir.mkdir(parents=True, exist_ok=True)
    auth_file = config_dir / "auth.json"
    auth_file.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "providers": {
                    "meta": {
                        "mechanism": "oauth",
                        "storage": "file",
                        "access_token": "file-token",
                    }
                },
            }
        )
    )

    token = load_muse_access_token(
        environment={"XDG_CONFIG_HOME": str(tmp_path)},
        raw_keychain='{"access_token": "keychain-token"}',
    )
    assert token == "file-token"


def test_keychain_fallback(tmp_path: Path) -> None:
    token = load_muse_access_token(
        home=tmp_path,
        environment={},
        raw_keychain='{"secret_schema_version": 1, "api_key": "LLM|abc", "access_token": "dca:xyz"}',
    )
    assert token == "dca:xyz"


def test_fetch_muse_usage_end_to_end() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "POST"
        assert request.url == httpx.URL("https://api.meta.ai/muse-code/key")
        assert request.headers["Authorization"] == "Bearer dca:xyz"
        assert request.headers["x-api-version"] == "1.0.0"
        assert request.headers["Content-Type"] == "application/json"
        assert request.headers["Accept"] == "application/json"
        assert request.headers["User-Agent"] == "AIPace"
        assert json.loads(request.content) == {}
        return httpx.Response(
            200,
            json={
                "api_key": "sk-...",
                "base_url": "https://api.meta.ai/v1",
                "is_subs_active": True,
                "subs_tier_id": "2768",
                "subs_tier_name": "Muse Code High Usage",
                "subs_usage": {
                    "window": {
                        "used_percent": 42,
                        "window_duration_mins": 300,
                        "resets_at": 1789623043,
                    },
                    "weekly": {"used_percent": 7, "resets_at": 1789948800},
                    "tier": "2768",
                },
            },
        )

    snapshot = asyncio.run(
        fetch_muse_usage(
            access_token="dca:xyz",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "Muse"
    assert snapshot.five_hour.kind == "5h"
    assert snapshot.five_hour.used_percentage == 42
    assert snapshot.five_hour.resets_at == datetime.fromtimestamp(
        1789623043, timezone.utc
    )
    assert snapshot.weekly.kind == "Week"
    assert snapshot.weekly.used_percentage == 7
    assert snapshot.detail == "Muse Code High Usage"


def test_malformed_credentials_file_raises(tmp_path: Path) -> None:
    config_dir = tmp_path / "muse"
    config_dir.mkdir(parents=True, exist_ok=True)
    auth_file = config_dir / "auth.json"
    auth_file.write_text("invalid json content")

    with pytest.raises(MuseError, match="Muse credentials could not be read."):
        load_muse_access_token(environment={"XDG_CONFIG_HOME": str(tmp_path)})


def test_credentials_not_found_raises(tmp_path: Path) -> None:
    with pytest.raises(MuseError, match="Muse credentials not found. Run muse login."):
        load_muse_access_token(
            home=tmp_path,
            environment={},
            raw_keychain="",
        )


def test_fetch_handles_auth_failure() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, json={"error": "unauthorized"})

    snapshot = asyncio.run(
        fetch_muse_usage(
            access_token="invalid",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "Muse"
    assert snapshot.five_hour.message == "Muse authentication failed. Run muse login again."
    assert snapshot.weekly.message == "Muse authentication failed. Run muse login again."


def test_fetch_handles_missing_limits() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "subs_tier_name": "Basic",
                "subs_usage": {},
            },
        )

    snapshot = asyncio.run(
        fetch_muse_usage(
            access_token="tok",
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "Muse"
    assert snapshot.five_hour.message == "No 5h limit returned."
    assert snapshot.weekly.message == "No weekly limit returned."
    assert snapshot.detail == "Basic"


def test_file_without_token_falls_back_to_keychain(tmp_path: Path) -> None:
    config_dir = tmp_path / "muse"
    config_dir.mkdir(parents=True, exist_ok=True)
    auth_file = config_dir / "auth.json"
    auth_file.write_text(
        json.dumps(
            {
                "schema_version": 2,
                "providers": {
                    "meta": {
                        "mechanism": "oauth",
                        "storage": "keychain",
                    }
                },
            }
        )
    )
    token = load_muse_access_token(
        environment={"XDG_CONFIG_HOME": str(tmp_path)},
        raw_keychain='{"access_token": "keychain-token"}',
    )
    assert token == "keychain-token"


def test_malformed_keychain_raises(tmp_path: Path) -> None:
    with pytest.raises(MuseError, match="Muse credentials could not be read."):
        load_muse_access_token(
            home=tmp_path,
            environment={},
            raw_keychain="invalid json",
        )


def test_non_dict_file_raises(tmp_path: Path) -> None:
    config_dir = tmp_path / "muse"
    config_dir.mkdir(parents=True, exist_ok=True)
    (config_dir / "auth.json").write_text("[1, 2, 3]")
    with pytest.raises(MuseError, match="Muse credentials could not be read."):
        load_muse_access_token(environment={"XDG_CONFIG_HOME": str(tmp_path)})


def test_non_dict_keychain_raises(tmp_path: Path) -> None:
    with pytest.raises(MuseError, match="Muse credentials could not be read."):
        load_muse_access_token(
            home=tmp_path,
            environment={},
            raw_keychain="[1, 2, 3]",
        )


def test_fetch_handles_server_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="Internal Server Error")

    snapshot = asyncio.run(
        fetch_muse_usage(
            access_token="tok",
            transport=httpx.MockTransport(handler),
        )
    )
    assert snapshot.provider == "Muse"
    assert snapshot.five_hour.message == "Muse account endpoint returned HTTP 500."
    assert snapshot.weekly.message == "Muse account endpoint returned HTTP 500."


def test_fetch_handles_invalid_json_response() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"not json")

    snapshot = asyncio.run(
        fetch_muse_usage(
            access_token="tok",
            transport=httpx.MockTransport(handler),
        )
    )
    assert snapshot.provider == "Muse"
    assert snapshot.five_hour.message == "Muse response could not be read."


def test_fetch_handles_missing_credentials(tmp_path: Path) -> None:
    snapshot = asyncio.run(
        fetch_muse_usage(
            home=tmp_path,
            environment={},
            raw_keychain="",
        )
    )
    assert snapshot.provider == "Muse"
    assert (
        snapshot.five_hour.message
        == "Muse credentials not found. Run muse login."
    )
    assert (
        snapshot.weekly.message
        == "Muse credentials not found. Run muse login."
    )
