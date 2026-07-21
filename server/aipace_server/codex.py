"""Collect Codex quota usage through the local ``codex app-server`` process.

The collector performs the app-server JSON-RPC initialization handshake, reads
``account/rateLimits/read``, and classifies returned windows by duration because
Codex does not guarantee that primary and secondary map to fixed quota periods.
"""

import asyncio
from datetime import datetime, timezone
import json
from pathlib import Path
from typing import Any

from aipace_server.models import ProviderSnapshot, UsageWindow
from aipace_server.processes import find_executable, process_environment


class CodexError(RuntimeError):
    """Report a failure to retrieve or understand Codex rate limits."""


async def _write_json_line(
    process: asyncio.subprocess.Process,
    payload: dict[str, Any],
) -> None:
    """Write one JSON-RPC message to the app-server standard input."""

    if process.stdin is None:
        raise CodexError("Codex app-server standard input is unavailable.")
    process.stdin.write(json.dumps(payload, separators=(",", ":")).encode() + b"\n")
    await process.stdin.drain()


async def _read_response(
    process: asyncio.subprocess.Process,
    response_id: int,
) -> dict[str, Any]:
    """Read app-server output until the matching JSON-RPC response arrives."""

    if process.stdout is None:
        raise CodexError("Codex app-server standard output is unavailable.")
    while line := await process.stdout.readline():
        try:
            payload = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if payload.get("id") != response_id:
            continue
        error = payload.get("error")
        if isinstance(error, dict) and isinstance(error.get("message"), str):
            raise CodexError(error["message"])
        return payload
    raise CodexError(
        f"Codex app-server closed before returning response id {response_id}."
    )


def _numeric(value: Any) -> float | None:
    """Parse numeric JSON values while rejecting booleans."""

    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float, str)):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _parse_window(value: Any) -> dict[str, Any] | None:
    """Normalize one raw Codex rate-limit window."""

    if not isinstance(value, dict):
        return None
    used_percentage = _numeric(value.get("usedPercent"))
    if used_percentage is None:
        return None
    resets_at = _numeric(value.get("resetsAt"))
    return {
        "used_percentage": used_percentage,
        "resets_at": (
            datetime.fromtimestamp(resets_at, timezone.utc)
            if resets_at is not None
            else None
        ),
        "window_duration_mins": _numeric(value.get("windowDurationMins")),
    }


def _classify_windows(
    primary: dict[str, Any] | None,
    secondary: dict[str, Any] | None,
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    """Assign Codex windows by duration, falling back to response position."""

    five_hour = None
    weekly = None
    unclassified = []
    for window in (primary, secondary):
        if window is None:
            continue
        duration = window["window_duration_mins"]
        if duration is None:
            unclassified.append(window)
        elif duration <= 720:
            five_hour = five_hour or window
        else:
            weekly = weekly or window

    for window in unclassified:
        if five_hour is None:
            five_hour = window
        elif weekly is None:
            weekly = window
    return five_hour, weekly


def _usage_window(kind: str, window: dict[str, Any] | None) -> UsageWindow:
    """Convert a parsed Codex window into the public API model."""

    if window is None:
        label = "5h" if kind == "5h" else "weekly"
        return UsageWindow(kind=kind, message=f"No {label} limit returned.")
    return UsageWindow(
        kind=kind,
        used_percentage=window["used_percentage"],
        resets_at=window["resets_at"],
    )


async def fetch_codex_usage(timeout: float = 20) -> ProviderSnapshot:
    """Return the current Codex usage snapshot, including provider-local errors."""

    try:
        executable = find_executable("codex")
        if executable is None:
            raise CodexError("codex is not installed or not on PATH.")

        process = await asyncio.create_subprocess_exec(
            executable,
            "-s",
            "read-only",
            "app-server",
            cwd=Path.home(),
            env=process_environment(),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            async with asyncio.timeout(timeout):
                await _write_json_line(
                    process,
                    {
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "clientInfo": {"name": "aipace", "version": "0.1.0"}
                        },
                    },
                )
                await _read_response(process, 1)
                await _write_json_line(
                    process,
                    {"jsonrpc": "2.0", "method": "initialized", "params": {}},
                )
                await _write_json_line(
                    process,
                    {
                        "jsonrpc": "2.0",
                        "id": 2,
                        "method": "account/rateLimits/read",
                        "params": {},
                    },
                )
                payload = await _read_response(process, 2)
        finally:
            if process.stdin is not None:
                process.stdin.close()
            if process.returncode is None:
                try:
                    process.terminate()
                    await asyncio.wait_for(process.wait(), timeout=1)
                except ProcessLookupError:
                    pass
                except asyncio.TimeoutError:
                    process.kill()
                    await process.wait()

        result = payload.get("result")
        rate_limits = result.get("rateLimits") if isinstance(result, dict) else None
        if not isinstance(rate_limits, dict):
            raise CodexError("Codex rate limit response was missing result.rateLimits.")

        five_hour, weekly = _classify_windows(
            _parse_window(rate_limits.get("primary")),
            _parse_window(rate_limits.get("secondary")),
        )
        plan_type = rate_limits.get("planType")
        return ProviderSnapshot(
            provider="Codex",
            five_hour=_usage_window("5h", five_hour),
            weekly=_usage_window("Week", weekly),
            detail=f"Plan: {plan_type}" if isinstance(plan_type, str) else None,
        )
    except (CodexError, OSError, asyncio.TimeoutError) as error:
        message = (
            "Codex app-server timed out."
            if isinstance(error, asyncio.TimeoutError)
            else str(error)
        )
        return ProviderSnapshot(
            provider="Codex",
            five_hour=UsageWindow(kind="5h", message=message),
            weekly=UsageWindow(kind="Week", message=message),
        )
