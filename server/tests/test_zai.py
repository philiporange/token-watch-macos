"""Verify z.ai key isolation, request headers, and quota normalization."""

import asyncio
from pathlib import Path

import httpx

from aipace_server.zai import fetch_zai_usage, load_zai_api_key


def test_key_loader_reads_only_zai_api_key(tmp_path: Path) -> None:
    (tmp_path / ".env").write_text(
        "ANTHROPIC_AUTH_TOKEN=must-not-be-used\nZAI_API_KEY=zai-secret\n"
    )

    assert load_zai_api_key(tmp_path, {}) == "zai-secret"

    (tmp_path / ".env").write_text("ANTHROPIC_AUTH_TOKEN=must-not-be-used\n")
    assert load_zai_api_key(tmp_path, {}) is None


def test_fetch_uses_direct_header_and_normalizes_limits(tmp_path: Path) -> None:
    (tmp_path / ".env").write_text("ZAI_API_KEY=zai-secret\n")

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "GET"
        assert request.url == httpx.URL(
            "https://api.z.ai/api/monitor/usage/quota/limit"
        )
        assert request.url.query == b""
        assert request.headers["Authorization"] == "zai-secret"
        assert request.headers["Accept-Language"] == "en-US,en"
        return httpx.Response(
            200,
            json={
                "data": {
                    "plan_type": "Pro",
                    "limits": [
                        {
                            "type": "TOKENS_LIMIT",
                            "percentage": "23.5",
                            "nextResetTime": 1_800_000_000_000,
                        },
                        {"type": "TIME_LIMIT", "percentage": 41},
                    ],
                }
            },
        )

    snapshot = asyncio.run(
        fetch_zai_usage(
            home=tmp_path,
            environment={},
            transport=httpx.MockTransport(handler),
        )
    )

    assert snapshot.provider == "Z.ai"
    assert snapshot.five_hour.used_percentage == 23.5
    assert snapshot.five_hour.resets_at is not None
    assert snapshot.weekly.kind == "Month"
    assert snapshot.weekly.used_percentage == 41
    assert snapshot.detail == "Pro"
