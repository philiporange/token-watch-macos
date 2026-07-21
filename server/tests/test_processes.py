"""Verify CLI discovery includes installations managed outside the shell PATH."""

from pathlib import Path

from aipace_server.processes import _version_manager_directories


def test_nvm_directories_are_newest_first(tmp_path: Path) -> None:
    for version in ("v18.20.0", "v20.19.0", "v9.9.9"):
        (tmp_path / ".nvm" / "versions" / "node" / version / "bin").mkdir(parents=True)

    directories = _version_manager_directories(tmp_path)

    assert directories[:3] == (
        str(tmp_path / ".nvm" / "versions" / "node" / "v20.19.0" / "bin"),
        str(tmp_path / ".nvm" / "versions" / "node" / "v18.20.0" / "bin"),
        str(tmp_path / ".nvm" / "versions" / "node" / "v9.9.9" / "bin"),
    )
