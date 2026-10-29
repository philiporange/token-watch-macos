"""Verify reset parsing, safe fake-only redemption, coalescing, and expiry policy."""

import asyncio
import json
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

import httpx
import pytest

from aipace_server import claude, codex
from aipace_server.cache import UsageCache
from aipace_server.models import (
    AutoApplySettings,
    BankedReset,
    ProviderSnapshot,
    ResetApplyOutcome,
    UsageWindow,
)
from aipace_server.resets import ResetService, reset_is_due

NOW = datetime(2030, 1, 1, tzinfo=timezone.utc)
PROVIDERS = {
    "claude": "Claude",
    "codex": "Codex",
    "gemini": "Gemini",
    "zai": "Z.ai",
    "muse": "Muse",
    "alicloud": "AliCloud",
    "commandcode": "Command Code",
}


@pytest.fixture(autouse=True)
def forbid_live_operations(monkeypatch):
    """Fail closed if a reset test reaches a real process or HTTP transport."""

    async def forbidden(*args, **kwargs):
        raise AssertionError("Reset tests must never launch a real process.")

    monkeypatch.setattr(asyncio, "create_subprocess_exec", forbidden)
    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", forbidden)


def credit(reset_id="credit", **updates):
    """Build a usable credit whose timestamps are controlled by the test."""

    data = {
        "id": reset_id,
        "title": "Full reset",
        "status": "available",
        "usable": True,
        "remaining": 1,
        "expires_at": NOW + timedelta(minutes=4),
    }
    return BankedReset(**(data | updates))


def fake_cache(resets, calls=None):
    """Use fake fetchers for every provider; no default collectors are involved."""

    calls = calls if calls is not None else {key: 0 for key in PROVIDERS}

    def fetcher(key):
        async def fetch():
            calls[key] += 1
            return ProviderSnapshot(
                provider=PROVIDERS[key],
                five_hour=UsageWindow(kind="5h"),
                weekly=UsageWindow(kind="Week"),
                banked_resets=resets.get(key, []),
            )

        return fetch

    return UsageCache(*(fetcher(key) for key in PROVIDERS))


def test_codex_credit_parsing():
    parsed = codex._parse_banked_resets(
        {
            "availableCount": 9,
            "credits": [
                {
                    "id": "valid",
                    "status": "available",
                    "expiresAt": (NOW + timedelta(hours=1)).timestamp(),
                    "grantedAt": NOW.timestamp(),
                },
                {"id": "expired", "status": "available", "expiresAt": NOW.timestamp()},
                {"id": "redeeming", "status": "redeeming", "title": "Waiting"},
                {"id": "redeemed", "status": "redeemed"},
                {"id": "unknown", "status": "other"},
                {"id": "bad/id", "status": "available"},
                None,
            ],
        },
        NOW,
    )
    assert [reset.status for reset in parsed] == [
        "available",
        "expired",
        "redeeming",
        "redeemed",
        "unknown",
    ]
    assert parsed[0].title == "Codex reset"
    assert parsed[0].granted_at == NOW
    assert [reset.remaining for reset in parsed] == [1, 0, 0, 0, 0]
    for block in (None, {}, {"credits": None}, {"credits": "bad"}):
        assert codex._parse_banked_resets(block, NOW) == []


def grant(**updates):
    """Build a cedar grant without depending on an upstream account."""

    return {
        "id": "grant",
        "label": "Full reset",
        "resets_left": 1,
        "usable_now": True,
        "paused": False,
        "use_requires_limit": True,
        "clears": ["five_hour", "seven_day"],
        "ends_at": (NOW + timedelta(minutes=4)).isoformat(),
    } | updates


def test_claude_cedar_mapping_and_malformed_blocks():
    block = {
        "eligible": True,
        "next_grant_id": "grant",
        "grants": [grant(), None, grant(id="bad/id"), grant(resets_left="bad")],
    }
    parsed = claude._parse_banked_resets(block, NOW)
    assert len(parsed) == 1
    assert parsed[0].usable and parsed[0].description == "Refills 5h and weekly limits"
    surface = claude._parse_banked_resets(
        block | {"eligible": False, "ineligible_reason": "surface"}, NOW
    )[0]
    assert not surface.usable and surface.status == "unavailable"
    assert (
        surface.note == "Claude only allows this reset on claude.ai or Claude Desktop."
    )
    cooldown = claude._parse_banked_resets(
        block | {"cooldown_until": (NOW + timedelta(minutes=1)).isoformat()}, NOW
    )[0]
    assert not cooldown.usable and "another reset after" in cooldown.note
    for changes, status in (
        ({"resets_left": 0}, "redeemed"),
        ({"paused": True}, "paused"),
        ({"ends_at": NOW.isoformat()}, "expired"),
    ):
        assert (
            claude._parse_banked_resets(block | {"grants": [grant(**changes)]}, NOW)[
                0
            ].status
            == status
        )
    limit = claude._parse_banked_resets(
        block | {"grants": [grant(usable_now=False)]}, NOW
    )[0]
    assert "once you reach a limit" in limit.note
    for malformed in (
        None,
        [],
        "bad",
        {},
        {"grants": {}},
        {"eligible": [], "grants": [grant()]},
    ):
        assert claude._parse_banked_resets(malformed, NOW) == []


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("reset", "reset"),
        ("nothingToReset", "nothing_to_reset"),
        ("noCredit", "no_credit"),
        ("alreadyRedeemed", "already_redeemed"),
        ("future", "unconfirmed"),
    ],
)
def test_codex_consume_mapping_uses_fake_rpc(monkeypatch, raw, expected):
    async def fake_rpc(method, params, timeout, on_written):
        assert (
            method == "account/rateLimitResetCredit/consume"
        )  # Fake RPC assertion only.
        assert params == {"creditId": "credit", "idempotencyKey": "stable"}
        on_written()
        return {"result": {"outcome": raw}}

    monkeypatch.setattr(codex, "_rpc_call", fake_rpc)
    assert asyncio.run(codex.apply_codex_reset("credit", "stable")).outcome == expected


@pytest.mark.parametrize(
    "written,error,expected",
    [
        (False, TimeoutError(), "error"),
        (True, TimeoutError(), "unconfirmed"),
        (True, codex.CodexError("EOF"), "unconfirmed"),
        (True, codex.CodexRPCError("Rejected"), "error"),
    ],
)
def test_codex_delivery_failure_mapping(monkeypatch, written, error, expected):
    async def fake_rpc(method, params, timeout, on_written):
        if written:
            on_written()
        raise error

    monkeypatch.setattr(codex, "_rpc_call", fake_rpc)
    assert asyncio.run(codex.apply_codex_reset("credit", "stable")).outcome == expected


def test_codex_shared_handshake_marks_written_before_drain(monkeypatch):
    """A fake stream fails after write, proving delivery is tracked before drain."""

    writes = []

    class Input:
        def write(self, value):
            writes.append(json.loads(value))

        async def drain(self):
            if len(writes) == 3:
                raise OSError("closed during drain")

        def close(self):
            pass

    class Output:
        async def readline(self):
            return b'{"id":1,"result":{}}\n'

    process = SimpleNamespace(stdin=Input(), stdout=Output(), returncode=0)

    async def spawn(*args, **kwargs):
        return process

    monkeypatch.setattr(codex, "find_executable", lambda name: "/fake/codex")
    monkeypatch.setattr(asyncio, "create_subprocess_exec", spawn)
    assert (
        asyncio.run(codex.apply_codex_reset("credit", "stable")).outcome
        == "unconfirmed"
    )
    assert [write["method"] for write in writes[:2]] == ["initialize", "initialized"]


class FakeLoader:
    """Keep test OAuth credentials entirely in memory, including refresh saves."""

    def __init__(self, home):
        self.home = home
        self.saved = 0
        self.credentials = claude.ClaudeCredentials(
            "token", "refresh", 9_999_999_999_999, None, "file", {}
        )

    def resolve(self):
        return self.credentials

    def needs_refresh(self, credentials):
        return False

    def save(self, credentials):
        self.saved += 1


@pytest.mark.parametrize(
    "result,expected",
    [
        ("reset", "reset"),
        ("already_used", "already_redeemed"),
        ("not_limited", "nothing_to_reset"),
        ("cooldown", "cooldown"),
        ("ineligible", "ineligible"),
        ("unavailable", "unavailable"),
        ("future", "unavailable"),
    ],
)
def test_claude_apply_mock_transport(tmp_path, result, expected):
    seen = []

    def handler(request):
        seen.append(request)
        assert request.headers["Authorization"] == "Bearer token"
        assert request.headers["anthropic-beta"] == "oauth-2025-04-20"
        if request.url.path == "/api/oauth/profile":
            return httpx.Response(200, json={"organization": {"uuid": "org_1"}})
        assert (
            request.url.path == "/api/organizations/org_1/reset_rate_limits"
        )  # MockTransport assertion.
        assert json.loads(request.content) == {
            "program": "cedar_ember",
            "grant_id": "grant",
            "request_id": "stable",
        }
        return httpx.Response(200, json={"result": result, "reason": "explanation"})

    outcome = asyncio.run(
        claude.apply_claude_reset(
            "grant",
            "stable",
            loader=FakeLoader(tmp_path),
            transport=httpx.MockTransport(handler),
        )
    )
    assert outcome.outcome == expected and outcome.detail == "explanation"
    assert len(seen) == 2


def test_claude_401_refresh_retry_preserves_request_id(tmp_path):
    loader = FakeLoader(tmp_path)
    keys = []

    def handler(request):
        if request.url.path.endswith("/token"):
            assert json.loads(request.content)["refresh_token"] == "refresh"
            return httpx.Response(
                200,
                json={
                    "access_token": "rotated",
                    "refresh_token": "rotated-refresh",
                    "expires_in": 3600,
                },
            )
        if request.url.path.endswith("/profile"):
            return httpx.Response(200, json={"organization": {"uuid": "org"}})
        keys.append(json.loads(request.content)["request_id"])
        if len(keys) == 1:
            return httpx.Response(401)
        assert request.headers["Authorization"] == "Bearer rotated"
        return httpx.Response(200, json={"result": "reset"})

    outcome = asyncio.run(
        claude.apply_claude_reset(
            "grant", "stable", loader=loader, transport=httpx.MockTransport(handler)
        )
    )
    assert outcome.outcome == "reset"
    assert keys == ["stable", "stable"] and loader.saved == 1


@pytest.mark.parametrize(
    "status,expected,posts",
    [(429, "rate_limited", 1), (500, "error", 1), (403, "error", 2)],
)
def test_claude_http_failure_retry_limits(tmp_path, status, expected, posts):
    count = 0

    def handler(request):
        nonlocal count
        if request.url.path.endswith("/token"):
            return httpx.Response(200, json={"access_token": "rotated"})
        if request.url.path.endswith("/profile"):
            return httpx.Response(200, json={"organization": {"uuid": "org"}})
        count += 1
        return httpx.Response(status)

    outcome = asyncio.run(
        claude.apply_claude_reset(
            "grant",
            "stable",
            loader=FakeLoader(tmp_path),
            transport=httpx.MockTransport(handler),
        )
    )
    assert outcome.outcome == expected and count == posts
    if status == 403:
        assert outcome.detail == "Claude authentication failed."


def test_claude_transport_failure_never_retries(tmp_path):
    posts = 0

    def handler(request):
        nonlocal posts
        if request.url.path.endswith("/profile"):
            return httpx.Response(200, json={"organization": {"uuid": "org"}})
        posts += 1
        raise httpx.ReadError("connection closed", request=request)

    outcome = asyncio.run(
        claude.apply_claude_reset(
            "grant",
            "stable",
            loader=FakeLoader(tmp_path),
            transport=httpx.MockTransport(handler),
        )
    )
    assert outcome.outcome == "unconfirmed" and posts == 1


def test_claude_invalid_org_and_malformed_cedar_do_not_escape(tmp_path):
    def handler(request):
        assert request.method == "GET"
        if request.url.path.endswith("/profile"):
            return httpx.Response(
                200, json={"organization": {"uuid": "bad/organization"}}
            )
        assert (
            request.url.params["cedar_ember"] == "1"
            and request.url.params["skip_spend"] == "1"
        )
        return httpx.Response(
            200,
            json={
                "five_hour": {"utilization": 25},
                "cedar_ember": {"eligible": True, "grants": [grant(resets_left={})]},
            },
        )

    transport = httpx.MockTransport(handler)
    assert (
        asyncio.run(
            claude.apply_claude_reset(
                "grant", "stable", loader=FakeLoader(tmp_path), transport=transport
            )
        ).outcome
        == "error"
    )
    usage = asyncio.run(
        claude.fetch_claude_usage(loader=FakeLoader(tmp_path), transport=transport)
    )
    assert usage.five_hour.used_percentage == 25 and usage.banked_resets == []


def test_service_validation_coalescing_keys_and_refresh():
    async def scenario():
        calls = {key: 0 for key in PROVIDERS}
        cache = fake_cache(
            {"codex": [credit(), credit("blocked", usable=False, note="Wait.")]}, calls
        )
        await cache.refresh()
        entered, release = asyncio.Event(), asyncio.Event()
        keys = []

        async def applier(reset_id, key):
            keys.append(key)
            entered.set()
            await release.wait()
            return ResetApplyOutcome(outcome="nothing_to_reset")

        service = ResetService(cache, {"codex": applier})
        assert (await service.apply("codex", "missing")).outcome == "not_found"
        blocked = await service.apply("codex", "blocked")
        assert blocked.outcome == "not_usable" and blocked.message.endswith("Wait.")
        assert calls["codex"] == 1 and keys == []
        first = asyncio.create_task(service.apply("codex", "credit"))
        await entered.wait()
        second = asyncio.create_task(service.apply("codex", "credit"))
        await asyncio.sleep(0)
        release.set()
        a, b = await asyncio.gather(first, second)
        assert a == b and len(keys) == 1 and calls["codex"] == 2
        await service.apply("codex", "credit")
        assert len(keys) == 2 and keys[0] == keys[1]
        assert calls == {key: 3 if key == "codex" else 1 for key in PROVIDERS}

    asyncio.run(scenario())


@pytest.mark.parametrize("outcome", ["reset", "unconfirmed", "error"])
def test_service_refreshes_after_all_upstream_outcomes(outcome):
    async def scenario():
        resets = {"codex": [credit()]}
        cache = fake_cache(resets)
        await cache.refresh()

        async def applier(reset_id, key):
            resets["codex"] = []
            return ResetApplyOutcome(
                outcome=outcome, detail="failure" if outcome == "error" else None
            )

        result = await ResetService(cache, {"codex": applier}).apply("codex", "credit")
        assert result.outcome == outcome and result.usage.banked_resets == []
        assert result.applied == (outcome == "reset")

    asyncio.run(scenario())


def test_due_policy_boundaries():
    assert reset_is_due(credit(), NOW, 5)
    assert reset_is_due(credit(expires_at=NOW + timedelta(minutes=5)), NOW, 5)
    assert reset_is_due(credit(), NOW, 5, last_attempt=NOW - timedelta(seconds=60))
    assert not reset_is_due(credit(), NOW, 5, last_attempt=NOW - timedelta(seconds=59))
    assert not reset_is_due(credit(), NOW, 5, completed=True)
    for changes in (
        {"usable": False},
        {"expires_at": None},
        {"expires_at": NOW},
        {"expires_at": NOW + timedelta(minutes=6)},
    ):
        assert not reset_is_due(credit(**changes), NOW, 5)
    assert AutoApplySettings(lead_minutes=0).lead_minutes == 1
    assert AutoApplySettings(lead_minutes=90).lead_minutes == 60


def test_auto_tick_with_fake_clock_and_disabled_setting():
    async def scenario():
        calls = {key: 0 for key in PROVIDERS}
        cache = fake_cache(
            {
                "codex": [
                    credit("due"),
                    credit("later", expires_at=NOW + timedelta(hours=1)),
                    credit("expired", expires_at=NOW),
                    credit("none", expires_at=None),
                    credit("blocked", usable=False),
                ]
            },
            calls,
        )
        await cache.refresh()
        applied = []

        async def applier(reset_id, key):
            applied.append(reset_id)
            return ResetApplyOutcome(outcome="reset")

        current = [NOW]
        service = ResetService(
            cache,
            {"codex": applier},
            AutoApplySettings(enabled=True),
            lambda: current[0],
        )
        assert len(await service.tick()) == 1 and applied == ["due"]
        current[0] += timedelta(seconds=61)
        assert await service.tick() == [] and applied == ["due"]
        before = dict(calls)
        service.settings.enabled = False
        assert await service.tick() == [] and calls == before

    asyncio.run(scenario())


def test_tick_rechecks_inventory_and_waits_before_retry():
    async def scenario():
        cache = fake_cache({"codex": [credit()]})
        await cache.refresh()
        keys, current = [], [NOW]

        async def applier(reset_id, key):
            keys.append(key)
            return ResetApplyOutcome(outcome="nothing_to_reset")

        service = ResetService(
            cache,
            {"codex": applier},
            AutoApplySettings(enabled=True),
            lambda: current[0],
        )
        await service.tick()
        current[0] += timedelta(seconds=30)
        assert await service.tick() == []
        current[0] += timedelta(seconds=30)
        await service.tick()
        assert len(keys) == 2 and keys[0] == keys[1]

        async def fetch_without_credit():
            return ProviderSnapshot(
                provider="Codex",
                five_hour=UsageWindow(kind="5h"),
                weekly=UsageWindow(kind="Week"),
            )

        cache._fetch_codex = fetch_without_credit
        current[0] += timedelta(seconds=60)
        assert await service.tick() == [] and len(keys) == 2

    asyncio.run(scenario())
