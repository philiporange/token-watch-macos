"""Verify cached usage, injected reset routes, and the bundled web dashboard."""

import asyncio

import httpx
import pytest
from fastapi.testclient import TestClient

from aipace_server.cache import UsageCache
from aipace_server.main import create_app
from aipace_server.models import ProviderSnapshot, UsageWindow


@pytest.fixture(autouse=True)
def forbid_live_operations(monkeypatch):
    """Keep route tests confined to fake fetchers, appliers, and local ASGI calls."""

    async def forbidden(*args, **kwargs):
        raise AssertionError(
            "Route tests must never launch processes or send real HTTP."
        )

    monkeypatch.setattr(asyncio, "create_subprocess_exec", forbidden)
    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", forbidden)


def snapshot(provider: str, percentage: float) -> ProviderSnapshot:
    """Build a compact provider result for cache route tests."""

    return ProviderSnapshot(
        provider=provider,
        five_hour=UsageWindow(kind="5h", used_percentage=percentage),
        weekly=UsageWindow(kind="Week", used_percentage=percentage + 10),
    )


def test_gets_use_cache_and_post_refreshes() -> None:
    calls = {
        "claude": 0,
        "codex": 0,
        "gemini": 0,
        "zai": 0,
        "muse": 0,
        "alicloud": 0,
        "commandcode": 0,
    }

    async def fetch_claude() -> ProviderSnapshot:
        calls["claude"] += 1
        return snapshot("Claude", calls["claude"] * 10)

    async def fetch_codex() -> ProviderSnapshot:
        calls["codex"] += 1
        return snapshot("Codex", calls["codex"] * 20)

    async def fetch_gemini() -> ProviderSnapshot:
        calls["gemini"] += 1
        return snapshot("Gemini", calls["gemini"] * 15)

    async def fetch_zai() -> ProviderSnapshot:
        calls["zai"] += 1
        return ProviderSnapshot(
            provider="Z.ai",
            five_hour=UsageWindow(kind="5h", used_percentage=calls["zai"] * 5),
            weekly=UsageWindow(kind="Month", used_percentage=calls["zai"] * 7),
        )

    async def fetch_muse() -> ProviderSnapshot:
        calls["muse"] += 1
        return ProviderSnapshot(
            provider="Muse",
            five_hour=UsageWindow(kind="5h", used_percentage=calls["muse"] * 8),
            weekly=UsageWindow(kind="Week", used_percentage=calls["muse"] * 12),
        )

    async def fetch_alicloud() -> ProviderSnapshot:
        calls["alicloud"] += 1
        return ProviderSnapshot(
            provider="AliCloud",
            five_hour=UsageWindow(kind="5h", message="Token Plan has no 5h window."),
            weekly=UsageWindow(kind="Week", used_percentage=calls["alicloud"] * 6),
        )

    async def fetch_commandcode() -> ProviderSnapshot:
        calls["commandcode"] += 1
        return ProviderSnapshot(
            provider="Command Code",
            five_hour=UsageWindow(kind="5h", used_percentage=calls["commandcode"] * 9),
            weekly=UsageWindow(kind="Week", used_percentage=calls["commandcode"] * 11),
        )

    app = create_app(
        UsageCache(
            fetch_claude,
            fetch_codex,
            fetch_gemini,
            fetch_zai,
            fetch_muse,
            fetch_alicloud,
            fetch_commandcode,
        )
    )
    with TestClient(app) as client:
        first = client.get("/usage")
        second = client.get("/usage/claude")
        gemini = client.get("/usage/gemini")
        zai = client.get("/usage/zai")
        muse = client.get("/usage/muse")
        alicloud = client.get("/usage/alicloud")
        commandcode = client.get("/usage/commandcode")
        refreshed = client.post("/refresh")

        assert first.status_code == 200
        assert second.status_code == 200
        assert first.json()["claude"]["cached_at"]
        assert second.json()["cached_at"] == first.json()["claude"]["cached_at"]
        assert gemini.json()["provider"] == "Gemini"
        assert zai.json()["weekly"]["kind"] == "Month"
        assert muse.json()["provider"] == "Muse"
        assert alicloud.json()["provider"] == "AliCloud"
        assert commandcode.json()["provider"] == "Command Code"
        assert calls == {
            "claude": 2,
            "codex": 2,
            "gemini": 2,
            "zai": 2,
            "muse": 2,
            "alicloud": 2,
            "commandcode": 2,
        }
        assert refreshed.json()["claude"]["five_hour"]["used_percentage"] == 20


def test_dashboard_and_health() -> None:
    async def fetch_claude() -> ProviderSnapshot:
        return snapshot("Claude", 10)

    async def fetch_codex() -> ProviderSnapshot:
        return snapshot("Codex", 20)

    async def fetch_gemini() -> ProviderSnapshot:
        return snapshot("Gemini", 25)

    async def fetch_zai() -> ProviderSnapshot:
        return ProviderSnapshot(
            provider="Z.ai",
            five_hour=UsageWindow(kind="5h", used_percentage=30),
            weekly=UsageWindow(kind="Month", used_percentage=40),
        )

    async def fetch_muse() -> ProviderSnapshot:
        return ProviderSnapshot(
            provider="Muse",
            five_hour=UsageWindow(kind="5h", used_percentage=35),
            weekly=UsageWindow(kind="Week", used_percentage=45),
        )

    async def fetch_alicloud() -> ProviderSnapshot:
        return ProviderSnapshot(
            provider="AliCloud",
            five_hour=UsageWindow(kind="5h", message="Token Plan has no 5h window."),
            weekly=UsageWindow(kind="Week", used_percentage=50),
        )

    async def fetch_commandcode() -> ProviderSnapshot:
        return ProviderSnapshot(
            provider="Command Code",
            five_hour=UsageWindow(kind="5h", used_percentage=55),
            weekly=UsageWindow(kind="Week", used_percentage=65),
        )

    app = create_app(
        UsageCache(
            fetch_claude,
            fetch_codex,
            fetch_gemini,
            fetch_zai,
            fetch_muse,
            fetch_alicloud,
            fetch_commandcode,
        )
    )
    with TestClient(app) as client:
        dashboard = client.get("/")
        health = client.get("/health")

        assert dashboard.status_code == 200
        assert "Usage, at a glance." in dashboard.text
        assert "provider-card--gemini" in dashboard.text
        assert "provider-card--zai" in dashboard.text
        assert "provider-card--muse" in dashboard.text
        assert "provider-card--alicloud" in dashboard.text
        assert "provider-card--commandcode" in dashboard.text
        assert health.json() == {"status": "ok"}


def reset_app(outcome="reset", enabled=False):
    """Build route tests with fake inventory and appliers for every operation."""

    from datetime import datetime, timezone

    from aipace_server.models import AutoApplySettings, BankedReset, ResetApplyOutcome
    from aipace_server.resets import ResetService

    names = ("Claude", "Codex", "Gemini", "Z.ai", "Muse", "AliCloud", "Command Code")

    def fetcher(name):
        async def fetch():
            result = snapshot(name, 10)
            if name in ("Claude", "Codex"):
                result.banked_resets = [
                    BankedReset(
                        id="ready",
                        title="Full reset",
                        status="available",
                        usable=True,
                        remaining=1,
                        expires_at=datetime(
                            2030 if name == "Codex" else 2031, 1, 1, tzinfo=timezone.utc
                        ),
                    ),
                    BankedReset(
                        id="blocked",
                        title="Blocked",
                        status="unavailable",
                        usable=False,
                        remaining=1,
                        note="Wait for eligibility.",
                    ),
                ]
            return result

        return fetch

    cache = UsageCache(*(fetcher(name) for name in names))

    async def apply(reset_id, request_key):
        assert reset_id == "ready" and request_key
        return ResetApplyOutcome(outcome=outcome, detail="test detail")

    service = ResetService(
        cache,
        {"codex": apply, "claude": apply},
        AutoApplySettings(enabled=enabled, lead_minutes=7),
    )
    return create_app(cache, service)


def test_resets_order_settings_and_payload_keys():
    with TestClient(reset_app()) as client:
        payload = client.get("/resets").json()
        assert payload["auto_apply"] == {"enabled": False, "lead_minutes": 7}
        assert [(reset["provider"], reset["id"]) for reset in payload["resets"]] == [
            ("codex", "ready"),
            ("claude", "ready"),
            ("claude", "blocked"),
            ("codex", "blocked"),
        ]
        assert set(payload["resets"][0]) == {
            "provider",
            "id",
            "title",
            "description",
            "granted_at",
            "expires_at",
            "status",
            "usable",
            "remaining",
            "note",
        }
        for response in (client.get("/usage"), client.post("/refresh")):
            usage = response.json()
            assert usage["banked_reset_auto_apply"] == payload["auto_apply"]
            assert usage["gemini"]["banked_resets"] == []
        assert client.get("/usage/codex").json()["banked_resets"]
        assert client.get("/resets/codex/ready/apply").status_code == 405
        assert client.post("/resets/unknown/ready/apply").status_code == 404
        for reset_id, status, outcome in (
            ("missing", 404, "not_found"),
            ("blocked", 409, "not_usable"),
        ):
            response = client.post(f"/resets/codex/{reset_id}/apply")
            assert response.status_code == status
            assert response.json()["outcome"] == outcome
            assert response.json()["usage"]["provider"] == "Codex"


def test_apply_route_upstream_status_codes_and_payload():
    for outcome in (
        "reset",
        "already_redeemed",
        "nothing_to_reset",
        "no_credit",
        "cooldown",
        "ineligible",
        "unavailable",
        "rate_limited",
        "unconfirmed",
        "error",
    ):
        with TestClient(reset_app(outcome)) as client:
            response = client.post("/resets/codex/ready/apply")
            assert response.status_code == (
                502 if outcome in ("rate_limited", "unconfirmed", "error") else 200
            )
            payload = response.json()
            assert set(payload) == {
                "provider",
                "reset_id",
                "outcome",
                "applied",
                "message",
                "usage",
            }
            assert payload["provider"] == "codex" and payload["reset_id"] == "ready"
            assert payload["outcome"] == outcome
            assert payload["applied"] == (outcome in ("reset", "already_redeemed"))
            assert payload["message"] and payload["usage"]["cached_at"]


def test_auto_apply_lifespan_only_runs_when_enabled_and_cancels(monkeypatch):
    """Exercise startup/shutdown with an inert loop, never a provider applier."""

    from threading import Event

    from aipace_server.resets import ResetService

    started, cancelled = Event(), Event()

    async def inert_loop(self):
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            cancelled.set()

    monkeypatch.setattr(ResetService, "run", inert_loop)
    with TestClient(reset_app()) as client:
        assert client.get("/health").status_code == 200
        assert not started.is_set()
    with TestClient(reset_app(enabled=True)) as client:
        assert client.get("/health").status_code == 200
        assert started.wait(1)
        assert not cancelled.is_set()
    assert cancelled.is_set()
