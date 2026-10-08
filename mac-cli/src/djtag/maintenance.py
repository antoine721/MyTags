"""`djtag backup-db` and `djtag prune-backups`."""

from __future__ import annotations

import gzip
import json
import shutil
from datetime import UTC, datetime
from pathlib import Path

from .api import ADMIN_TABLES, Api
from .settings import Settings


def backup_db(settings: Settings, api: Api) -> Path:
    """Export every cloud table to ~/DJTag/backups/db/<date>.json.gz."""
    rows = api.pull_all(ADMIN_TABLES)
    folder = settings.backups_dir / "db"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"mytags-{datetime.now(UTC).strftime('%Y%m%d-%H%M%S')}.json.gz"
    payload = {"exported_at": datetime.now(UTC).isoformat(), "tables": rows}
    with gzip.open(path, "wt", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
    return path


def prune_backups(settings: Settings, keep: int | None = None) -> list[Path]:
    """Delete apply backups beyond the `keep` most recent runs (never touches the library)."""
    keep = settings.keep_backups if keep is None else keep
    root = settings.backups_dir
    if not root.exists():
        return []
    runs = sorted(
        (p for p in root.iterdir() if p.is_dir() and (p / "manifest.json").exists()), key=lambda p: p.name
    )
    removed = runs[:-keep] if keep > 0 else runs
    for folder in removed:
        shutil.rmtree(folder)
    return removed
