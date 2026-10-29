"""Check lazy quota storage, contract projections, routes and fake-only refreshes.

All history files live under pytest's temporary directory or in memory, and
autouse guards reject subprocess launches and real HTTP provider requests.
"""

import asyncio
from dataclasses import replace
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
from threading import Event

import httpx
import pytest
from fastapi.testclient import TestClient

from aipace_server.cache import UsageCache
from aipace_server.history import PROVIDERS, UsageHistory, extract_series, project_usage
from aipace_server.main import create_app
from aipace_server.models import HistoryPoint, ModelUsageWindow, ProviderSnapshot, UsageWindow


@pytest.fixture(autouse=True)
def forbid_live_operations(monkeypatch):
    """Forbid provider HTTP and CLI operations even if a fake is misconfigured."""

    async def forbidden(*args, **kwargs):
        raise AssertionError("History tests must never send real HTTP or launch processes")

    monkeypatch.setattr(asyncio, "create_subprocess_exec", forbidden)
    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", forbidden)


def dt(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


NOW = dt("2026-10-29T12:00:00Z")


def reading(used=30, provider="Claude", kind="Week", reset=None):
    return ProviderSnapshot(
        provider=provider,
        five_hour=UsageWindow(kind="5h"),
        weekly=UsageWindow(kind=kind, used_percentage=used, resets_at=reset),
    )


def fake_cache(on_snapshot=None, used=30):
    def fetcher(name):
        async def fetch():
            return reading(used=used, provider=name)
        return fetch
    return UsageCache(*(fetcher(name) for name in PROVIDERS.values()), on_snapshot=on_snapshot)


def test_recording_vector_r_and_series_extraction(tmp_path):
    history = UsageHistory(tmp_path / "nested/history.sqlite3", clock=lambda: NOW)
    assert not Path(history.path).exists()
    for minutes, used, count in [(0, 30, 1), (10, 30.5, 1), (20, 31, 2),
                                 (80, 31.2, 3), (90, 30, 4)]:
        history.record("claude", reading(used), NOW + timedelta(minutes=minutes))
        assert history.sample.select().count() == count
        assert history.query("all").series[0].current.used == used
    history.record("claude", reading(None), NOW + timedelta(minutes=100))
    assert history.sample.select().count() == 4
    assert history.query("all").series[0].current.t == NOW + timedelta(minutes=90)
    assert ["series", "t"] in [index.columns for index in history.database.get_indexes("samples")]
    monthly = reading(kind="Month")
    monthly.model_windows = [
        ModelUsageWindow(model_name=" --Opus / 4.5-- ", window=UsageWindow(kind="Model", used_percentage=3)),
        ModelUsageWindow(model_name="Opus 4 5", window=UsageWindow(kind="Model", used_percentage=9)),
        ModelUsageWindow(model_name="Missing", window=UsageWindow(kind="Model")),
    ]
    entries = list(extract_series(monthly))
    assert [(window, label) for window, label, _ in entries] == [
        ("weekly", "Monthly"), ("model:opus-4-5", " --Opus / 4.5-- ")]
    assert entries[1][2].used_percentage == 3
    history.record("zai", reading(provider="Z.ai", kind="Month"), NOW)
    assert history.query("all", "zai").series[0].label == "Monthly"
    history.close()


def test_recording_tolerance_seconds_and_restart_threshold(tmp_path):
    path = tmp_path / "history.sqlite3"
    history = UsageHistory(path)
    history.record("claude", reading(30), NOW + timedelta(microseconds=100000))
    history.record("claude", reading(31 - 5e-10), NOW + timedelta(seconds=1))
    assert history.sample.select().count() == 2
    assert history.query("all").series[0].points[0].t.microsecond == 0
    history.close()
    restarted = UsageHistory(path)
    restarted.record("claude", reading(31.2), NOW + timedelta(minutes=10))
    assert restarted.sample.select().count() == 2
    restarted.close()


def point(value, used, reset=None):
    return HistoryPoint(t=dt(value), used=used, resets_at=dt(reset) if reset else None)


@pytest.mark.parametrize("kind,reset,samples,rates,at_reset,limits", [
    ("5h", "2026-10-29T15:00:00Z",
     [("2026-10-29T10:30:00Z", 5), ("2026-10-29T11:00:00Z", 10), ("2026-10-29T11:30:00Z", 20)],
     [15, 20], [75, 90], [None, None]),
    ("Week", "2026-11-03T00:00:00Z",
     [("2026-10-27T06:00:00Z", 2), ("2026-10-28T12:00:00Z", 10), ("2026-10-29T00:00:00Z", 20)],
     [.5, 5 / 6], [84, 120], [None, "2026-11-02T00:00:00Z"]),
    ("Week", None, [], [], [], []),
    ("Week", "2026-11-03T00:00:00Z", [], [.5], [84], [None]),
])
def test_projection_vectors_v1_to_v4(kind, reset, samples, rates, at_reset, limits):
    current = HistoryPoint(t=NOW, used=30, resets_at=dt(reset) if reset else None)
    projections = project_usage(kind, current, [point(t, used) for t, used in samples])
    assert [p.method for p in projections] == ["average", "trend"][:len(rates)]
    for index, projection in enumerate(projections):
        assert projection.rate_per_hour == pytest.approx(rates[index], abs=.01)
        assert projection.at_reset == pytest.approx(at_reset[index], abs=.01)
        assert projection.from_.t == NOW and projection.from_.used == 30
        assert projection.limit_at == (dt(limits[index]) if limits[index] else None)
        assert projection.to.t == dt(limits[index] or reset)
        assert projection.to.used == pytest.approx(100 if limits[index] else at_reset[index])


def test_projection_vector_v5_and_boundaries():
    current = HistoryPoint(t=NOW, used=100, resets_at=dt("2026-11-03T00:00:00Z"))
    projection = project_usage("Week", current, [])[0]
    assert projection.limit_at == NOW
    assert projection.to == projection.from_
    assert project_usage("Week", current.model_copy(update={"resets_at": NOW}), []) == []
    early = current.model_copy(update={"resets_at": NOW + timedelta(hours=168)})
    assert project_usage("Week", early, []) == []
    decreasing = [HistoryPoint(t=NOW - timedelta(hours=6), used=110)]
    assert project_usage("Week", current, decreasing)[1].rate_per_hour == 0
    too_recent = [HistoryPoint(t=NOW - timedelta(hours=5), used=80)]
    assert len(project_usage("Week", current, too_recent)) == 1


def test_history_route_filters_current_restart_and_ordering(tmp_path):
    path = tmp_path / "history.sqlite3"
    history = UsageHistory(path, clock=lambda: NOW)
    old = NOW - timedelta(days=2)
    history.record("claude", reading(10), old)
    history.record("claude", reading(10.5), old + timedelta(minutes=10))
    # The current reading crosses the range boundary without meeting a storage threshold.
    boundary = NOW - timedelta(hours=24)
    history.record("codex", reading(20, provider="Codex"), boundary - timedelta(minutes=5))
    history.record("codex", reading(20.5, provider="Codex"), boundary + timedelta(minutes=5))
    ordered = reading(30, reset=NOW + timedelta(days=1))
    ordered.five_hour = UsageWindow(kind="5h", used_percentage=20)
    ordered.model_windows = [ModelUsageWindow(model_name=name, window=UsageWindow(kind="Model", used_percentage=3)) for name in ("Zeta", "Alpha")]
    history.record("claude", ordered, NOW - timedelta(hours=1))
    history.record("claude", reading(30.5, reset=ordered.weekly.resets_at), NOW - timedelta(minutes=50))
    history.record("muse", reading(5, provider="Muse"), old)
    # Failed/null startup readings leave the previously recorded history intact.
    with TestClient(create_app(fake_cache(used=None), history=history), raise_server_exceptions=True) as client:
        payload = client.get("/history?range=24h").json()
        assert payload["range"] == "24h" and payload["since"] == "2026-10-28T12:00:00Z"
        assert payload["generated_at"] == "2026-10-29T12:00:00Z"
        assert [s["id"] for s in payload["series"][:4]] == ["claude.five_hour", "claude.weekly", "claude.model:alpha", "claude.model:zeta"]
        weekly = next(s for s in payload["series"] if s["id"] == "claude.weekly")
        assert weekly["current"]["used"] == 30.5
        assert all(dt(p["t"]) >= boundary for p in weekly["points"])
        assert "from" in weekly["projections"][0]
        codex = client.get("/history?range=24h&provider=codex").json()["series"]
        assert len(codex) == 1 and codex[0]["provider"] == "codex"
        assert codex[0]["points"] == [] and codex[0]["current"]["used"] == 20.5
        assert all(s["provider"] != "muse" for s in payload["series"])
        assert client.get("/history?provider=unknown").status_code == 404
        assert client.get("/history?range=1d").status_code == 422
        assert client.get("/history?range=all").json()["since"] is None
        assert client.get("/dashboard/history").status_code == 200
        assert "history.js" in client.get("/dashboard/history").text
        assert client.get("/static/history.js").status_code == 200
    history.close()
    restarted = UsageHistory(path, clock=lambda: NOW)
    with TestClient(create_app(fake_cache(used=None), history=restarted)) as client:
        stored = client.get("/history?range=all&provider=claude").json()["series"][1]
        assert stored["current"] == stored["points"][-1]
        assert stored["current"]["used"] == 30
    restarted.close()


def test_current_in_range_without_stored_point_and_restart_fallback(tmp_path):
    path = tmp_path / "history.sqlite3"
    history = UsageHistory(path, clock=lambda: NOW)
    boundary = NOW - timedelta(hours=24)
    history.record("codex", reading(20, provider="Codex"), boundary - timedelta(minutes=5))
    history.record("codex", reading(20.5, provider="Codex"), boundary + timedelta(minutes=5))
    series = history.query("24h").series[0]
    assert series.points == [] and series.current.used == 20.5
    history.close()
    restarted = UsageHistory(path, clock=lambda: NOW)
    assert restarted.query("24h").series == []
    assert restarted.query("all").series[0].current.used == 20
    restarted.close()


def test_cache_hook_full_single_and_failure_isolation(tmp_path, caplog):
    history = UsageHistory(tmp_path / "history.sqlite3")
    events = []

    def hook(key, snapshot, stamp):
        events.append(key)
        history.record(key, snapshot, stamp)

    async def exercise():
        cache = fake_cache(hook)
        await cache.refresh()
        assert events == list(PROVIDERS)
        assert len(history.query("all").series) == 7
        await cache.refresh_provider("claude")
        assert events == list(PROVIDERS) + ["claude"]

        def raising(*args):
            raise RuntimeError("storage unavailable")

        cache.on_snapshot = raising
        assert (await cache.refresh()).claude.weekly.used_percentage == 30
        assert (await cache.refresh_provider("codex")).weekly.used_percentage == 30

    asyncio.run(exercise())
    assert "Snapshot hook failed" in caplog.text
    history.close()


def test_import_main_does_not_create_history_file(monkeypatch, tmp_path):
    from aipace_server import config

    monkeypatch.setenv("HOME", str(tmp_path))
    target = tmp_path / ".local/share/aipace/usage-history.sqlite3"
    monkeypatch.setattr(config, "settings", replace(config.settings, history_path=target))
    source = Path(__file__).parents[1] / "aipace_server/main.py"
    spec = importlib.util.spec_from_file_location("isolated_history_main", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    assert module.usage_history.path == str(target)
    assert not target.parent.exists()


def test_periodic_refresh_survives_error_and_cancels(caplog):
    started, cancelled = Event(), Event()
    cache = fake_cache()
    original = cache.refresh
    calls = 0

    async def refresh():
        nonlocal calls
        calls += 1
        if calls == 2:
            raise RuntimeError("fake fetch error")
        if calls >= 3:
            started.set()
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()
        return await original()

    cache.refresh = refresh
    with TestClient(create_app(cache, refresh_minutes=.0001)):
        assert started.wait(2)
    assert cancelled.is_set()
    assert "Periodic usage refresh failed" in caplog.text
