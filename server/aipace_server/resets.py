"""List and apply explicit banked resets through injected provider operations.

The service coalesces concurrent attempts, retains one idempotency key per credit,
refreshes usage after upstream calls, and runs an opt-in expiry policy with an
injectable clock. It never constructs a live provider applier.
"""

import asyncio
import logging
from collections.abc import Awaitable, Callable, Mapping
from datetime import datetime, timedelta, timezone
from uuid import uuid4

from aipace_server.cache import UsageCache
from aipace_server.models import (
    ApplyResetResponse,
    AutoApplySettings,
    BankedReset,
    CachedProviderSnapshot,
    ResetApplyOutcome,
    ResetListItem,
    ResetsResponse,
)

logger = logging.getLogger(__name__)


PROVIDER_KEYS = ("claude", "codex", "gemini", "zai", "muse", "alicloud", "commandcode")
ResetApplier = Callable[[str, str], Awaitable[ResetApplyOutcome]]
Clock = Callable[[], datetime]


def reset_is_due(
    reset: BankedReset,
    now: datetime,
    lead_minutes: int,
    completed: bool = False,
    last_attempt: datetime | None = None,
) -> bool:
    """Select usable, uncompleted credits within the lead window and retry budget."""

    return bool(
        reset.usable
        and reset.expires_at is not None
        and not completed
        and now
        < reset.expires_at
        <= now + timedelta(minutes=max(1, min(60, lead_minutes)))
        and (last_attempt is None or now - last_attempt >= timedelta(seconds=60))
    )


def apply_status_code(response: ApplyResetResponse) -> int:
    """Select the contract's HTTP status for a normalized apply response."""

    if response.outcome == "not_found":
        return 404
    if response.outcome == "not_usable":
        return 409
    if response.outcome in ("rate_limited", "unconfirmed", "error"):
        return 502
    return 200


def _message(provider: str, outcome: str, detail: str | None = None) -> str:
    """Give callers a consistent explanation of confirmed and uncertain outcomes."""

    messages = {
        "reset": f"{provider} reset applied.",
        "already_redeemed": f"This {provider} reset was already applied.",
        "nothing_to_reset": f"{provider} has nothing to reset right now; the reset was kept.",
        "no_credit": f"{provider} reports no reset credits available.",
        "cooldown": f"{provider} allows another reset later; the reset was kept.",
        "ineligible": f"{provider} declined the reset; it was kept.",
        "unavailable": f"{provider} declined the reset; it was kept.",
        "rate_limited": f"{provider} rate limited the request; nothing was applied. Try again shortly.",
        "unconfirmed": f"Couldn't confirm whether the {provider} reset was applied. Check usage before trying again.",
        "error": f"{provider} reset failed: {detail or 'Unknown upstream error.'}",
        "not_found": "That reset is no longer listed. Refresh and try again.",
        "not_usable": "That reset can't be applied right now.",
    }
    message = messages[outcome]
    if detail and outcome in ("ineligible", "unavailable"):
        message += f" ({detail})"
    elif detail and outcome == "not_usable":
        message += " " + detail
    return message


class ResetService:
    """Own reset inventory, idempotency, concurrent attempts, and automatic ticks."""

    def __init__(
        self,
        cache: UsageCache,
        appliers: Mapping[str, ResetApplier],
        settings: AutoApplySettings | None = None,
        clock: Clock | None = None,
    ) -> None:
        self.cache = cache
        self.appliers = dict(appliers)
        self.settings = settings or AutoApplySettings()
        self.clock = clock or (lambda: datetime.now(timezone.utc))
        self._keys: dict[tuple[str, str], str] = {}
        self._in_flight: dict[tuple[str, str], asyncio.Task[ApplyResetResponse]] = {}
        self._completed: set[tuple[str, str]] = set()
        self._attempted: dict[tuple[str, str], datetime] = {}
        self._tick_lock = asyncio.Lock()

    def _provider(self, provider: str) -> CachedProviderSnapshot:
        if provider not in PROVIDER_KEYS:
            raise KeyError(provider)
        response = self.cache.get()
        if response is None:
            raise RuntimeError("Usage cache is not ready.")
        return getattr(response, provider)

    def list_resets(self) -> ResetsResponse:
        """Return every cached reset with the soonest expiry first and null last."""

        response = self.cache.get()
        if response is None:
            raise RuntimeError("Usage cache is not ready.")
        resets = [
            ResetListItem(provider=provider, **reset.model_dump())
            for provider in PROVIDER_KEYS
            for reset in getattr(response, provider).banked_resets
        ]
        resets.sort(
            key=lambda reset: (
                reset.expires_at or datetime.max.replace(tzinfo=timezone.utc)
            )
        )
        return ResetsResponse(auto_apply=self.settings, resets=resets)

    async def apply(self, provider: str, reset_id: str) -> ApplyResetResponse:
        """Join an existing attempt or apply one cached reset using its stable key."""

        if provider not in PROVIDER_KEYS:
            raise KeyError(provider)
        key = (provider, reset_id)
        task = self._in_flight.get(key)
        if task is None:
            task = asyncio.create_task(self._apply(provider, reset_id))
            self._in_flight[key] = task
            task.add_done_callback(lambda done: self._in_flight.pop(key, None))
        return await asyncio.shield(task)

    async def _apply(self, provider: str, reset_id: str) -> ApplyResetResponse:
        usage = self._provider(provider)
        reset = next(
            (reset for reset in usage.banked_resets if reset.id == reset_id), None
        )
        detail = None
        if reset is None:
            outcome = "not_found"
        elif not reset.usable:
            outcome, detail = "not_usable", reset.note
        else:
            key = (provider, reset_id)
            request_key = self._keys.setdefault(key, str(uuid4()))
            self._attempted[key] = self.clock()
            try:
                applier = self.appliers.get(provider)
                result = (
                    await applier(reset_id, request_key)
                    if applier
                    else ResetApplyOutcome(
                        outcome="error", detail="No reset applier configured."
                    )
                )
            except Exception as error:
                logger.exception("Reset applier failed for %s/%s", provider, reset_id)
                result = ResetApplyOutcome(outcome="error", detail=str(error))
            outcome, detail = result.outcome, result.detail
            if outcome in ("reset", "already_redeemed"):
                self._completed.add(key)
            try:
                usage = await self.cache.refresh_provider(provider)
            except Exception:
                logger.exception(
                    "Usage refresh failed after applying %s/%s", provider, reset_id
                )
                # Preserve the upstream result when a follow-up read is unavailable.
                usage = self._provider(provider)
        return ApplyResetResponse(
            provider=provider,
            reset_id=reset_id,
            outcome=outcome,
            applied=outcome in ("reset", "already_redeemed"),
            message=_message(usage.provider, outcome, detail),
            usage=usage,
        )

    async def tick(self) -> list[ApplyResetResponse]:
        """Refresh and sequentially apply only credits still due at the injected time."""

        if not self.settings.enabled:
            return []
        async with self._tick_lock:
            results = []
            for item in self.list_resets().resets:
                key = (item.provider, item.id)
                if not reset_is_due(
                    item,
                    self.clock(),
                    self.settings.lead_minutes,
                    key in self._completed,
                    self._attempted.get(key),
                ):
                    continue
                self._attempted[key] = self.clock()
                try:
                    usage = await self.cache.refresh_provider(item.provider)
                except Exception:
                    logger.exception(
                        "Usage refresh failed before applying %s/%s",
                        item.provider,
                        item.id,
                    )
                    continue
                fresh = next(
                    (reset for reset in usage.banked_resets if reset.id == item.id),
                    None,
                )
                if fresh is not None and reset_is_due(
                    fresh,
                    self.clock(),
                    self.settings.lead_minutes,
                    key in self._completed,
                ):
                    results.append(await self.apply(item.provider, item.id))
            return results

    async def run(self) -> None:
        """Check expiring credits every thirty seconds until shutdown cancellation."""

        while self.settings.enabled:
            try:
                await self.tick()
            except Exception:
                logger.exception("Automatic reset check failed")
            await asyncio.sleep(30)
