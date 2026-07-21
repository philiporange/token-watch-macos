"""Serve cached Claude, Codex, Gemini, and z.ai usage snapshots and a dashboard.

The cache is warmed at startup and refreshed explicitly through one POST route.
GET routes only read cached values, while static assets render the same response
as a responsive local dashboard.
"""

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from aipace_server.cache import UsageCache
from aipace_server.claude import fetch_claude_usage
from aipace_server.codex import fetch_codex_usage
from aipace_server.gemini import fetch_gemini_usage
from aipace_server.zai import fetch_zai_usage
from aipace_server.config import settings
from aipace_server.models import (
    CachedProviderSnapshot,
    HealthResponse,
    UsageResponse,
)


static_directory = Path(__file__).parent / "static"
usage_cache = UsageCache(
    fetch_claude=lambda: fetch_claude_usage(settings.request_timeout),
    fetch_codex=lambda: fetch_codex_usage(settings.codex_timeout),
    fetch_gemini=lambda: fetch_gemini_usage(settings.request_timeout),
    fetch_zai=lambda: fetch_zai_usage(settings.request_timeout),
)


def _cached_response(cache: UsageCache) -> UsageResponse:
    """Return the cache contents or a service-unavailable response."""

    response = cache.get()
    if response is None:
        raise HTTPException(status_code=503, detail="Usage cache is not ready.")
    return response


def create_app(cache: UsageCache = usage_cache) -> FastAPI:
    """Build the FastAPI application around a supplied usage cache."""

    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        await cache.refresh()
        yield

    application = FastAPI(
        title="Token Watch Usage API",
        description="Serve local Claude, Codex, Gemini, and z.ai usage data.",
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

    @application.get("/usage", response_model=UsageResponse)
    async def usage() -> UsageResponse:
        """Return all current cached provider snapshots."""

        return _cached_response(cache)

    @application.post("/refresh", response_model=UsageResponse)
    async def refresh() -> UsageResponse:
        """Refresh all providers concurrently and replace the cache."""

        return await cache.refresh()

    return application


app = create_app()
