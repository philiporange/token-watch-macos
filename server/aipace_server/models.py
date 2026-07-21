"""Define the stable API representation of provider usage snapshots.

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


class ProviderSnapshot(BaseModel):
    """The current normalized usage state for one provider."""

    provider: Literal["Claude", "Codex", "Gemini", "Z.ai"]
    five_hour: UsageWindow
    weekly: UsageWindow
    model_windows: list[ModelUsageWindow] = Field(default_factory=list)
    detail: str | None = None


class CachedProviderSnapshot(ProviderSnapshot):
    """A provider snapshot annotated with the time it entered the cache."""

    cached_at: datetime


class UsageResponse(BaseModel):
    """The current cached snapshots for all providers."""

    claude: CachedProviderSnapshot
    codex: CachedProviderSnapshot
    gemini: CachedProviderSnapshot
    zai: CachedProviderSnapshot


class HealthResponse(BaseModel):
    """A lightweight liveness response that does not contact any provider."""

    status: Literal["ok"] = "ok"
