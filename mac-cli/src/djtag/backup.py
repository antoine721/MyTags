"""Backups before writing (rule R2): APFS clones when possible, plain copies otherwise."""

from __future__ import annotations

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
    """Copy `src` to `dest` keeping metadata; returns 'clone' or 'copy'."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    if platform.system() == "Darwin":
        if subprocess.run(["cp", "-c", "-p", str(src), str(dest)], capture_output=True).returncode == 0:
            return "clone"
        subprocess.run(["cp", "-p", str(src), str(dest)], check=True, capture_output=True)
        return "copy"
    shutil.copy2(src, dest)
    return "copy"


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
        tmp.replace(path)
        return path

    @classmethod
    def load(cls, folder: Path) -> Manifest:
        data = json.loads((folder / "manifest.json").read_text())
        return cls(data["run_id"], data["created_at"], [BackupEntry(**e) for e in data["entries"]])
