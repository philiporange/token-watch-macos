"""Serve cached Claude, Codex, Gemini, z.ai, Muse, AliCloud, and Command Code usage snapshots and a dashboard.

The cache is warmed at startup and refreshed explicitly through one POST route.
Reset routes apply explicit credits, with opt-in expiry checks in the lifespan.
GET routes only read cached values, while static assets render the same response
as a responsive local dashboard.
"""

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager, suppress
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from aipace_server.alicloud import fetch_alicloud_usage
from aipace_server.cache import UsageCache
from aipace_server.claude import apply_claude_reset, fetch_claude_usage
from aipace_server.codex import apply_codex_reset, fetch_codex_usage
from aipace_server.commandcode import fetch_commandcode_usage
from aipace_server.config import settings
from aipace_server.gemini import fetch_gemini_usage
from aipace_server.models import (
    ApplyResetResponse,
    AutoApplySettings,
    CachedProviderSnapshot,
    HealthResponse,
    ResetsResponse,
    UsageResponse,
)
from aipace_server.muse import fetch_muse_usage
from aipace_server.resets import ResetService, apply_status_code
from aipace_server.zai import fetch_zai_usage

static_directory = Path(__file__).parent / "static"
usage_cache = UsageCache(
    fetch_claude=lambda: fetch_claude_usage(settings.request_timeout),
    fetch_codex=lambda: fetch_codex_usage(settings.codex_timeout),
    fetch_gemini=lambda: fetch_gemini_usage(settings.request_timeout),
    fetch_zai=lambda: fetch_zai_usage(settings.request_timeout),
    fetch_muse=lambda: fetch_muse_usage(settings.request_timeout),
    fetch_alicloud=lambda: fetch_alicloud_usage(settings.request_timeout),
    fetch_commandcode=lambda: fetch_commandcode_usage(settings.request_timeout),
)


def _cached_response(cache: UsageCache) -> UsageResponse:
    """Return the cache contents or a service-unavailable response."""

    response = cache.get()
    if response is None:
        raise HTTPException(status_code=503, detail="Usage cache is not ready.")
    return response


def create_app(
    cache: UsageCache = usage_cache,
    reset_service: ResetService | None = None,
) -> FastAPI:
    """Build routes with injected reset operations; this factory creates no live appliers."""

    resets = reset_service or ResetService(cache, {})

    def response_with_settings(response: UsageResponse) -> UsageResponse:
        return response.model_copy(update={"banked_reset_auto_apply": resets.settings})

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        await cache.refresh()
        task = asyncio.create_task(resets.run()) if resets.settings.enabled else None
        try:
            yield
        finally:
            if task is not None:
                task.cancel()
                with suppress(asyncio.CancelledError):
                    await task

    application = FastAPI(
        title="Token Watch Usage API",
        description="Serve local Claude, Codex, Gemini, z.ai, Muse, AliCloud, and Command Code usage data.",
        version="0.1.0",
        lifespan=lifespan,
    )
    application.mount(
        "/static",
        StaticFiles(directory=static_directory),
        name="static",
    )

    @application.get("/", include_in_schema=False)
    async def dashboard() -> FileResponse:
        """Serve the local usage dashboard."""

        return FileResponse(static_directory / "index.html")

    @application.get("/health", response_model=HealthResponse)
    async def health() -> HealthResponse:
        """Report server liveness without contacting any provider."""

        return HealthResponse()

    @application.get("/usage/claude", response_model=CachedProviderSnapshot)
    async def claude_usage() -> CachedProviderSnapshot:
        """Return the current cached Claude quota windows."""

        return _cached_response(cache).claude

    @application.get("/usage/codex", response_model=CachedProviderSnapshot)
    async def codex_usage() -> CachedProviderSnapshot:
        """Return the current cached Codex quota windows."""

        return _cached_response(cache).codex

    @application.get("/usage/gemini", response_model=CachedProviderSnapshot)
    async def gemini_usage() -> CachedProviderSnapshot:
        """Return the current cached Gemini quota windows."""

        return _cached_response(cache).gemini

    @application.get("/usage/zai", response_model=CachedProviderSnapshot)
    async def zai_usage() -> CachedProviderSnapshot:
        """Return the current cached z.ai quota windows."""

        return _cached_response(cache).zai

    @application.get("/usage/muse", response_model=CachedProviderSnapshot)
    async def muse_usage() -> CachedProviderSnapshot:
        """Return the current cached Muse quota windows."""

        return _cached_response(cache).muse

    @application.get("/usage/alicloud", response_model=CachedProviderSnapshot)
    async def alicloud_usage() -> CachedProviderSnapshot:
        """Return the current cached AliCloud quota windows."""

        return _cached_response(cache).alicloud

    @application.get("/usage/commandcode", response_model=CachedProviderSnapshot)
    async def commandcode_usage() -> CachedProviderSnapshot:
        """Return the current cached Command Code quota windows."""

        return _cached_response(cache).commandcode

    @application.get("/usage", response_model=UsageResponse)
    async def usage() -> UsageResponse:
        """Return all current cached provider snapshots."""

        return response_with_settings(_cached_response(cache))

    @application.post("/refresh", response_model=UsageResponse)
    async def refresh() -> UsageResponse:
        """Refresh all providers concurrently and replace the cache."""

        return response_with_settings(await cache.refresh())

    @application.get("/resets", response_model=ResetsResponse)
    async def list_resets() -> ResetsResponse:
        """List cached reset credits across providers without upstream calls."""

        _cached_response(cache)
        return resets.list_resets()

    @application.post(
        "/resets/{provider}/{reset_id}/apply", response_model=ApplyResetResponse
    )
    async def apply_reset(provider: str, reset_id: str) -> JSONResponse:
        """Apply an explicitly selected usable credit through the reset service."""

        _cached_response(cache)
        try:
            result = await resets.apply(provider, reset_id)
        except KeyError:
            raise HTTPException(status_code=404, detail="Unknown provider.") from None
        return JSONResponse(
            result.model_dump(mode="json"), status_code=apply_status_code(result)
        )

    return application


reset_service = ResetService(
    usage_cache,
    {
        "codex": lambda reset_id, key: apply_codex_reset(reset_id, key),
        "claude": lambda reset_id, key: apply_claude_reset(
            reset_id, key, settings.request_timeout
        ),
    },
    AutoApplySettings(
        enabled=settings.auto_apply_resets,
        lead_minutes=settings.auto_apply_lead_minutes,
    ),
)
app = create_app(usage_cache, reset_service)
