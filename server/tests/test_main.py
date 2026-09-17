"""Verify cached API routes and the bundled web dashboard."""

from fastapi.testclient import TestClient

from aipace_server.cache import UsageCache
from aipace_server.main import create_app
from aipace_server.models import ProviderSnapshot, UsageWindow


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
