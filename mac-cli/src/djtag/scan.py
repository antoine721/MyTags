"""Walk the music folders and list supported audio files."""

from __future__ import annotations

import os
from collections.abc import Iterator, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from .tags import detect_format

TEMP_MARKER = ".djtag-tmp"


@dataclass(frozen=True)
class ScannedFile:
    path: Path
    format: str
    size: int
    mtime: float

    @property
    def mtime_iso(self) -> str:
        return iso_from_timestamp(self.mtime)


def iso_from_timestamp(ts: float) -> str:
    return datetime.fromtimestamp(ts, UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def now_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def scan(folders: Sequence[Path], exclude: Sequence[str]) -> Iterator[ScannedFile]:
    excluded = set(exclude)
    seen: set[str] = set()
    for folder in folders:
        folder = folder.expanduser()
        if not folder.exists():
            continue
        for root, dirs, files in os.walk(folder):
            dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in excluded)
            for name in sorted(files):
                if name.startswith(".") or TEMP_MARKER in name:
                    continue
                path = Path(root) / name
                fmt = detect_format(path)
                if fmt is None:
                    continue
                real = os.path.realpath(path)
                if real in seen:
                    continue
                seen.add(real)
                try:
                    st = path.stat()
                except OSError:
                    continue
                yield ScannedFile(path, fmt, st.st_size, st.st_mtime)
