"""Define provider usage, banked reset inventory, settings, and apply responses.

The models translate providers into the same five-hour, secondary, and
model-scoped window structure used by the native AIPace application.
"""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


class UsageWindow(BaseModel):
    """A provider quota window and its next reset time."""

    kind: Literal["5h", "Week", "Model", "Month"]
    used_percentage: float | None = None
    resets_at: datetime | None = None
    message: str | None = None


class ModelUsageWindow(BaseModel):
    """A quota window scoped to one provider model or model group."""

    model_name: str
    window: UsageWindow
    is_active: bool = False


class BankedReset(BaseModel):
    """A named account reset credit with eligibility and expiry metadata."""

    id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,128}$")
    title: str
    description: str | None = None
    granted_at: datetime | None = None
    expires_at: datetime | None = None
    status: Literal[
        "available",
        "redeeming",
        "redeemed",
        "paused",
        "unavailable",
        "expired",
        "unknown",
    ]
    usable: bool
    remaining: int
    note: str | None = None


class AutoApplySettings(BaseModel):
    """Control opt-in application of credits shortly before they expire."""

    enabled: bool = False
    lead_minutes: int = 5

    def model_post_init(self, context: object) -> None:
        self.lead_minutes = max(1, min(60, self.lead_minutes))


class ResetListItem(BankedReset):
    """A reset credit annotated with its provider route key."""

    provider: str


class ResetsResponse(BaseModel):
    """All cached credits ordered by expiry, with automatic apply settings."""

    auto_apply: AutoApplySettings
    resets: list[ResetListItem]


ResetOutcome = Literal[
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
    "not_found",
    "not_usable",
]


class ResetApplyOutcome(BaseModel):
    """An upstream apply outcome with optional provider explanation."""

    outcome: ResetOutcome
    detail: str | None = None


class ProviderSnapshot(BaseModel):
    """The current normalized usage state for one provider."""

    provider: Literal[
        "Claude", "Codex", "Gemini", "Z.ai", "Muse", "AliCloud", "Command Code"
    ]
    five_hour: UsageWindow
    weekly: UsageWindow
    model_windows: list[ModelUsageWindow] = Field(default_factory=list)
    detail: str | None = None
    banked_resets: list[BankedReset] = Field(default_factory=list)


class CachedProviderSnapshot(ProviderSnapshot):
    """A provider snapshot annotated with the time it entered the cache."""

    cached_at: datetime


class UsageResponse(BaseModel):
    """The current cached snapshots for all providers."""

    claude: CachedProviderSnapshot
    codex: CachedProviderSnapshot
    gemini: CachedProviderSnapshot
    zai: CachedProviderSnapshot
    muse: CachedProviderSnapshot
    alicloud: CachedProviderSnapshot
    commandcode: CachedProviderSnapshot
    banked_reset_auto_apply: AutoApplySettings = Field(
        default_factory=AutoApplySettings
    )


class ApplyResetResponse(BaseModel):
    """The result of applying one explicit reset and its refreshed usage."""

    provider: str
    reset_id: str
    outcome: ResetOutcome
    applied: bool
    message: str
    usage: CachedProviderSnapshot


class HealthResponse(BaseModel):
    """A lightweight liveness response that does not contact any provider."""

    status: Literal["ok"] = "ok"
