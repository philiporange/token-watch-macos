"""Retain fresh quota samples in lazy SQLite storage and calculate usage paces.

Each store owns its Peewee binding and latest in-memory readings. Samples are
retained on hourly or one-percentage-point changes; queries combine those
samples with the latest readings and pure average/least-squares projections.
"""

from collections.abc import Callable, Iterable
from datetime import datetime, timezone
from pathlib import Path
import re
from threading import RLock

from peewee import AutoField, FloatField, Model, SqliteDatabase, TextField

from aipace_server.models import (
    HistoryCoordinate, HistoryPoint, HistoryProjection, HistoryRange,
    HistoryResponse, HistorySeries, ProviderSnapshot, UsageWindow,
)

PROVIDERS = dict(zip(
    ("claude", "codex", "gemini", "zai", "muse", "alicloud", "commandcode"),
    ("Claude", "Codex", "Gemini", "Z.ai", "Muse", "AliCloud", "Command Code"),
))
RANGE_SECONDS = {"24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400,
                 "90d": 90 * 86400, "365d": 365 * 86400}
WINDOW_HOURS = {"5h": (5, 1), "Week": (168, 24), "Model": (168, 24),
                "Month": (720, 72)}


class Sample(Model):
    """The permanent SQLite sample schema, bound separately by each store."""

    id = AutoField()
    series = TextField()
    provider = TextField()
    window = TextField()
    label = TextField()
    kind = TextField()
    t = FloatField()
    used = FloatField()
    resets_at = FloatField(null=True)

    class Meta:
        table_name = "samples"
        indexes = ((("series", "t"), False),)


def utc_second(value: datetime | float) -> datetime:
    """Normalize a date or Unix timestamp to UTC rounded to a whole second."""

    stamp = value.timestamp() if isinstance(value, datetime) else value
    return datetime.fromtimestamp(round(stamp), timezone.utc)


def extract_series(snapshot: ProviderSnapshot) -> Iterable[tuple[str, str, UsageWindow]]:
    """Yield non-null quota windows with stable model slugs, keeping duplicates first."""

    windows = [("five_hour", "5-hour", snapshot.five_hour),
               ("weekly", "Monthly" if snapshot.weekly.kind == "Month" else "Weekly",
                snapshot.weekly)]
    seen = set()
    for model in snapshot.model_windows:
        slug = re.sub(r"[^a-z0-9]+", "-", model.model_name.lower()).strip("-")
        if slug not in seen:
            seen.add(slug)
            windows.append((f"model:{slug}", model.model_name, model.window))
    return (entry for entry in windows if entry[2].used_percentage is not None)


def project_usage(kind: str, current: HistoryPoint,
                  samples: Iterable[HistoryPoint]) -> list[HistoryProjection]:
    """Calculate independent average and nonnegative least-squares trend estimates."""

    now, used, reset = current.t.timestamp(), current.used, current.resets_at
    if reset is None or reset.timestamp() <= now:
        return []
    duration, lookback = WINDOW_HOURS[kind]
    end = reset.timestamp()
    start = end - duration * 3600
    elapsed = (now - start) / 3600
    rates = []
    if 0.25 <= elapsed <= duration:
        rates.append(("average", max(0, used) / elapsed))
    lower = max(now - lookback * 3600, start)
    points = [((p.t.timestamp() - now) / 3600, p.used) for p in samples
              if lower <= p.t.timestamp() < now]
    points.append((0, used))
    if len(points) >= 2 and -min(x for x, _ in points) >= lookback / 4:
        mean_x = sum(x for x, _ in points) / len(points)
        mean_y = sum(y for _, y in points) / len(points)
        variance = sum((x - mean_x) ** 2 for x, _ in points)
        slope = sum((x - mean_x) * (y - mean_y) for x, y in points) / variance
        rates.append(("trend", max(0, slope)))
    projections = []
    for method, rate in rates:
        at_reset = used + rate * (end - now) / 3600
        limit = now if used >= 100 else (
            now + (100 - used) / rate * 3600 if at_reset >= 100 and rate > 0 else None
        )
        origin = HistoryCoordinate(t=current.t, used=used)
        target = origin if used >= 100 else HistoryCoordinate(
            t=utc_second(limit if limit is not None else end),
            used=100 if limit is not None else at_reset,
        )
        projections.append(HistoryProjection(
            method=method, rate_per_hour=rate, at_reset=at_reset,
            limit_at=utc_second(limit) if limit is not None else None,
            **{"from": origin, "to": target},
        ))
    return projections


class UsageHistory:
    """Own a lazy SQLite database and unthrottled last readings for each series."""

    def __init__(self, path: str | Path,
                 clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> None:
        self.path = str(Path(path).expanduser()) if str(path) != ":memory:" else ":memory:"
        self.clock = clock
        self.database = SqliteDatabase(self.path, thread_safe=False, check_same_thread=False)
        self.sample = type("StoreSample", (Sample,), {"Meta": type(
            "Meta", (), {"database": self.database, "table_name": "samples"})})
        self._last: dict[str, tuple[dict, HistoryPoint]] = {}
        self._lock = RLock()
        self._ready = False

    def _ensure(self) -> None:
        if not self._ready:
            if self.path != ":memory:":
                Path(self.path).parent.mkdir(parents=True, exist_ok=True)
            self.database.connect(reuse_if_open=True)
            self.database.create_tables([self.sample])
            self._ready = True

    def record(self, route_key: str, snapshot: ProviderSnapshot,
               t: datetime | float | None = None) -> None:
        """Update current readings and persist hourly or one-point quota changes."""

        if route_key not in PROVIDERS:
            raise KeyError(route_key)
        stamp = utc_second(self.clock() if t is None else t)
        with self._lock:
            for window, label, quota in extract_series(snapshot):
                metadata = dict(series=f"{route_key}.{window}", provider=route_key,
                                window=window, label=label, kind=quota.kind)
                point = HistoryPoint(t=stamp, used=quota.used_percentage,
                                     resets_at=utc_second(quota.resets_at)
                                     if quota.resets_at else None)
                self._last[metadata["series"]] = (metadata, point)
                self._ensure()
                previous = (self.sample.select().where(self.sample.series == metadata["series"])
                            .order_by(self.sample.t.desc(), self.sample.id.desc()).first())
                if (previous is None or stamp.timestamp() - previous.t >= 3600
                        or abs(point.used - previous.used) + 1e-9 >= 1):
                    self.sample.create(**metadata, t=stamp.timestamp(), used=point.used,
                                       resets_at=point.resets_at.timestamp()
                                       if point.resets_at else None)

    def query(self, range: HistoryRange = "7d", provider: str | None = None) -> HistoryResponse:
        """Return ordered series in range with current readings and all-history projections."""

        if provider is not None and provider not in PROVIDERS:
            raise KeyError(provider)
        now = utc_second(self.clock())
        since = None if range == "all" else utc_second(now.timestamp() - RANGE_SECONDS[range])
        with self._lock:
            self._ensure()
            query = self.sample.select().order_by(self.sample.t, self.sample.id)
            if since is not None:
                lookback = max(hours for _, hours in WINDOW_HOURS.values()) * 3600
                query = query.where(self.sample.t >= since.timestamp() - lookback)
            if provider:
                query = query.where(self.sample.provider == provider)
            grouped = {}
            for row in query:
                metadata = {key: getattr(row, key) for key in
                            ("series", "provider", "window", "label", "kind")}
                point = HistoryPoint(t=utc_second(row.t), used=row.used,
                                     resets_at=utc_second(row.resets_at)
                                     if row.resets_at is not None else None)
                grouped.setdefault(row.series, [metadata, []])[1].append(point)
                grouped[row.series][0] = metadata
            for key, (metadata, _) in self._last.items():
                if provider is None or metadata["provider"] == provider:
                    grouped.setdefault(key, [metadata, []])[0] = metadata
            result = []
            for key, (metadata, stored) in grouped.items():
                current = self._last[key][1] if key in self._last else stored[-1]
                points = [p for p in stored if since is None or p.t >= since]
                if not points and since is not None and current.t < since:
                    continue
                result.append(HistorySeries(
                    id=key, provider=metadata["provider"],
                    provider_name=PROVIDERS[metadata["provider"]],
                    window=metadata["window"], label=metadata["label"], kind=metadata["kind"],
                    points=points, current=current,
                    projections=project_usage(metadata["kind"], current, stored),
                ))
            order = list(PROVIDERS)
            result.sort(key=lambda s: (order.index(s.provider),
                        0 if s.window == "five_hour" else 1 if s.window == "weekly" else 2,
                        s.label))
            return HistoryResponse(generated_at=now, range=range, since=since, series=result)

    def close(self) -> None:
        """Release an opened connection without opening an unused store."""

        with self._lock:
            self.database.close()
            self._ready = False
