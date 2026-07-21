"""Verify Codex JSON parsing and duration-based quota classification."""

from aipace_server.codex import _classify_windows, _parse_window


def test_weekly_only_primary_is_not_mislabeled_as_five_hour() -> None:
    weekly = _parse_window(
        {
            "usedPercent": "25",
            "resetsAt": 1_710_000_000,
            "windowDurationMins": 10_080,
        }
    )

    five_hour, classified_weekly = _classify_windows(weekly, None)

    assert five_hour is None
    assert classified_weekly == weekly


def test_windows_without_durations_fall_back_to_position() -> None:
    primary = _parse_window({"usedPercent": 10})
    secondary = _parse_window({"usedPercent": 40})

    five_hour, weekly = _classify_windows(primary, secondary)

    assert five_hour == primary
    assert weekly == secondary
