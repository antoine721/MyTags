"""Local import state (~/DJTag/cache/state.sqlite): what was already processed and uploaded.

This lets `djtag import` skip unchanged files and resume after an interruption.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
  path            TEXT PRIMARY KEY,
  track_id        TEXT NOT NULL,
  size            INTEGER NOT NULL,
  mtime           REAL NOT NULL,
  fingerprint     TEXT,
  duration        REAL,
  stage           TEXT NOT NULL,   -- processed | uploaded | cataloged
  audio_size      INTEGER,
  has_cover       INTEGER NOT NULL DEFAULT 0,
  error           TEXT,
  updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS files_track ON files (track_id);
CREATE INDEX IF NOT EXISTS files_fingerprint ON files (fingerprint);
"""


@dataclass
class FileState:
    path: str
    track_id: str
    size: int
    mtime: float
    fingerprint: str | None
    duration: float | None
    stage: str
    audio_size: int | None
    has_cover: bool
    error: str | None


class ImportState:
    def __init__(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.executescript(SCHEMA)

    def close(self) -> None:
        self.db.close()

    @contextmanager
    def transaction(self) -> Iterator[None]:
        with self.db:
            yield

    def get(self, path: str) -> FileState | None:
        row = self.db.execute("SELECT * FROM files WHERE path = ?", (path,)).fetchone()
        return _state(row) if row else None

    def all(self) -> list[FileState]:
        return [_state(r) for r in self.db.execute("SELECT * FROM files")]

    def by_fingerprint(self, fingerprint: str) -> list[FileState]:
        return [
            _state(r) for r in self.db.execute("SELECT * FROM files WHERE fingerprint = ?", (fingerprint,))
        ]

    def by_track(self, track_id: str) -> FileState | None:
        row = self.db.execute("SELECT * FROM files WHERE track_id = ?", (track_id,)).fetchone()
        return _state(row) if row else None

    def upsert(self, s: FileState) -> None:
        with self.db:
            self.db.execute(
                """INSERT INTO files (path, track_id, size, mtime, fingerprint, duration, stage, audio_size, has_cover, error,
                                      updated_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
                   ON CONFLICT(path) DO UPDATE SET track_id = excluded.track_id, size = excluded.size,
                     mtime = excluded.mtime, fingerprint = excluded.fingerprint, duration = excluded.duration,
                     stage = excluded.stage, audio_size = excluded.audio_size, has_cover = excluded.has_cover,
                     error = excluded.error, updated_at = excluded.updated_at""",
                (
                    s.path,
                    s.track_id,
                    s.size,
                    s.mtime,
                    s.fingerprint,
                    s.duration,
                    s.stage,
                    s.audio_size,
                    int(s.has_cover),
                    s.error,
                ),
            )

    def set_stage(self, path: str, stage: str, error: str | None = None) -> None:
        with self.db:
            self.db.execute(
                "UPDATE files SET stage = ?, error = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE path = ?",
                (stage, error, path),
            )

    def move(self, old_path: str, new_path: str) -> None:
        with self.db:
            self.db.execute("DELETE FROM files WHERE path = ?", (new_path,))
            self.db.execute("UPDATE files SET path = ? WHERE path = ?", (new_path, old_path))

    def delete(self, path: str) -> None:
        with self.db:
            self.db.execute("DELETE FROM files WHERE path = ?", (path,))


def _state(row: sqlite3.Row) -> FileState:
    return FileState(
        path=row["path"],
        track_id=row["track_id"],
        size=row["size"],
        mtime=row["mtime"],
        fingerprint=row["fingerprint"],
        duration=row["duration"],
        stage=row["stage"],
        audio_size=row["audio_size"],
        has_cover=bool(row["has_cover"]),
        error=row["error"],
    )
