"""Locate CLI tools using the same augmented PATH strategy as the macOS app.

The inherited PATH is combined with a login shell PATH, version-manager
installations, and common user locations so services launched outside a terminal
can still find Codex and Claude.
"""

from functools import lru_cache
import os
from pathlib import Path
import shutil
import subprocess


def _node_version_key(path: Path) -> tuple[int, ...]:
    """Return a sortable numeric key for an NVM Node version directory."""

    try:
        return tuple(
            int(part) for part in path.parent.name.removeprefix("v").split(".")
        )
    except ValueError:
        return ()


def _version_manager_directories(home: Path) -> tuple[str, ...]:
    """Return executable directories created by common user version managers."""

    nvm_directories = sorted(
        (path for path in (home / ".nvm" / "versions" / "node").glob("*/bin")),
        key=_node_version_key,
        reverse=True,
    )
    fixed_directories = (
        home / ".volta" / "bin",
        home / ".asdf" / "shims",
        home / ".local" / "share" / "mise" / "shims",
        home / ".npm-global" / "bin",
    )
    return tuple(str(path) for path in (*nvm_directories, *fixed_directories))


def _append_path_entries(entries: list[str], value: str | None) -> None:
    """Append unique, expanded directories from a PATH-like string."""

    if not value:
        return
    for raw_entry in value.split(os.pathsep):
        entry = str(Path(raw_entry).expanduser())
        if entry and entry not in entries:
            entries.append(entry)


@lru_cache(maxsize=1)
def path_directories() -> tuple[str, ...]:
    """Return inherited, login-shell, and conventional executable directories."""

    directories: list[str] = []
    _append_path_entries(directories, os.environ.get("PATH"))

    candidates = [os.environ.get("SHELL"), "/bin/zsh", "/bin/bash"]
    for shell in dict.fromkeys(candidate for candidate in candidates if candidate):
        if not os.access(shell, os.X_OK):
            continue
        try:
            result = subprocess.run(
                [shell, "-l", "-c", 'printf %s "$PATH"'],
                cwd=Path.home(),
                env=os.environ,
                capture_output=True,
                check=True,
                text=True,
                timeout=5,
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if result.stdout.strip():
            _append_path_entries(directories, result.stdout.strip())
            break

    for directory in _version_manager_directories(Path.home()):
        _append_path_entries(directories, directory)

    for directory in (
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "~/bin",
        "~/.local/bin",
    ):
        _append_path_entries(directories, directory)
    return tuple(directories)


def process_environment() -> dict[str, str]:
    """Return the current environment with the augmented executable PATH."""

    environment = dict(os.environ)
    environment["PATH"] = os.pathsep.join(path_directories())
    return environment


def find_executable(name: str) -> str | None:
    """Find an executable using the augmented service PATH."""

    return shutil.which(name, path=os.pathsep.join(path_directories()))
