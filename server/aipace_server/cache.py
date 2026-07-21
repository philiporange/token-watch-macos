"""Cache normalized provider snapshots behind one concurrency-safe refresh.

The cache refreshes all providers concurrently, then publishes their results
as one immutable point-in-time response so GET requests never trigger provider
calls or observe a partially completed refresh.
"""

import asyncio
from collections.abc import Awaitable, Callable
from datetime import datetime, timezone

from aipace_server.models import (
    CachedProviderSnapshot,
    ProviderSnapshot,
    UsageResponse,
)


ProviderFetcher = Callable[[], Awaitable[ProviderSnapshot]]


class UsageCache:
    """Store the latest combined provider response and serialize refreshes."""

    def __init__(
        self,
        fetch_claude: ProviderFetcher,
        fetch_codex: ProviderFetcher,
        fetch_gemini: ProviderFetcher,
        fetch_zai: ProviderFetcher,
    ) -> None:
        self._fetch_claude = fetch_claude
        self._fetch_codex = fetch_codex
        self._fetch_gemini = fetch_gemini
        self._fetch_zai = fetch_zai
        self._response: UsageResponse | None = None
        self._refresh_lock = asyncio.Lock()

    def get(self) -> UsageResponse | None:
        """Return an isolated copy of the current cached response."""

        if self._response is None:
            return None
        return self._response.model_copy(deep=True)

    async def refresh(self) -> UsageResponse:
        """Fetch all providers and atomically replace the cached response."""

        async with self._refresh_lock:
            claude, codex, gemini, zai = await asyncio.gather(
                self._fetch_claude(),
                self._fetch_codex(),
                self._fetch_gemini(),
                self._fetch_zai(),
            )
            cached_at = datetime.now(timezone.utc)
            self._response = UsageResponse(
                claude=CachedProviderSnapshot(
                    **claude.model_dump(),
                    cached_at=cached_at,
                ),
                codex=CachedProviderSnapshot(
                    **codex.model_dump(),
                    cached_at=cached_at,
                ),
                gemini=CachedProviderSnapshot(
                    **gemini.model_dump(),
                    cached_at=cached_at,
                ),
                zai=CachedProviderSnapshot(
                    **zai.model_dump(),
                    cached_at=cached_at,
                ),
            )
            return self._response.model_copy(deep=True)
