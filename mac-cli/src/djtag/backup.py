"""Backups before writing (rule R2): APFS clones when possible, plain copies otherwise."""

from __future__ import annotations

import errno
import fcntl
import hashlib
import json
import os
import platform
import shutil
import subprocess
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def clone_or_copy(src: Path, dest: Path) -> str:
    """Copy `src` to `dest` keeping metadata and flush it to disk; returns 'clone' or 'copy'.

    `dest.parent` must exist: djtag never creates folders, least of all in the music library.
    """
    method = "copy"
    if platform.system() == "Darwin":
        if subprocess.run(["cp", "-c", "-p", str(src), str(dest)], capture_output=True).returncode == 0:
            method = "clone"
        else:
            done = subprocess.run(["cp", "-p", str(src), str(dest)], capture_output=True, text=True)
            if done.returncode != 0:
                raise OSError(errno.EIO, (done.stderr or "cp a échoué").strip(), str(dest))
    else:
        shutil.copy2(src, dest)
    fsync_file(dest)
    return method


def fsync_file(path: Path) -> None:
    """Flush a file to stable storage (F_FULLFSYNC on macOS, where fsync only reaches the drive cache)."""
    fd = os.open(path, os.O_RDONLY)
    try:
        full = getattr(fcntl, "F_FULLFSYNC", None)
        if full is not None:
            try:
                fcntl.fcntl(fd, full)
                return
            except OSError:
                pass
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_dir(path: Path) -> None:
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


@dataclass
class BackupEntry:
    track_id: str
    path: str
    backup: str  # file name inside the run's backup folder
    sha256: str
    baseline_before: dict[str, Any]
    targets: dict[str, Any]
    method: str = "copy"
    written: bool = False
    sha256_after: str | None = None


@dataclass
class Manifest:
    run_id: str
    created_at: str
    entries: list[BackupEntry] = field(default_factory=list)

    def save(self, folder: Path) -> Path:
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / "manifest.json"
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(
            json.dumps(
                {
                    "run_id": self.run_id,
                    "created_at": self.created_at,
                    "entries": [asdict(e) for e in self.entries],
                },
                ensure_ascii=False,
                indent=1,
            )
        )
        fsync_file(tmp)
        tmp.replace(path)
        fsync_dir(folder)
        return path

    @classmethod
    def load(cls, folder: Path) -> Manifest:
        data = json.loads((folder / "manifest.json").read_text())
        return cls(data["run_id"], data["created_at"], [BackupEntry(**e) for e in data["entries"]])
