"""In-memory snapshot of the cloud database, as seen by the Mac (admin token)."""

from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any

from .api import ADMIN_TABLES, Api
from .model.config import TagConfig, load_default_config_json
from .model.values_types import Baseline, FieldValue


@dataclass
class CloudState:
    tracks: dict[str, dict[str, Any]]
    config: TagConfig
    config_rows: dict[str, list[dict[str, Any]]]
    values: dict[str, dict[str, FieldValue]]  # track id -> field id -> confirmed value (live rows only)
    value_rows: dict[tuple[str, str], dict[str, Any]]
    changes: list[dict[str, Any]] = field(default_factory=list)
    apply_runs: list[dict[str, Any]] = field(default_factory=list)

    @classmethod
    def load(cls, api: Api) -> CloudState:
        return cls.from_rows(api.pull_all(ADMIN_TABLES))

    @classmethod
    def from_rows(cls, rows: dict[str, list[dict[str, Any]]]) -> CloudState:
        config_rows = {
            t: rows.get(t, []) for t in ("fields", "field_options", "rules", "saved_views", "settings")
        }
        if not any(r for r in config_rows["fields"] if not r.get("deleted_at")):
            config = TagConfig.from_json(load_default_config_json())
        else:
            config = TagConfig.from_json(config_rows)
        values: dict[str, dict[str, FieldValue]] = defaultdict(dict)
        value_rows: dict[tuple[str, str], dict[str, Any]] = {}
        for row in rows.get("track_values", []):
            value_rows[(row["track_id"], row["field_id"])] = row
            if row.get("deleted_at"):
                continue
            values[row["track_id"]][row["field_id"]] = FieldValue(
                option_ids=tuple(row.get("option_ids") or ()),
                rating=row.get("rating"),
                text=row.get("text_value"),
            )
        return cls(
            tracks={r["id"]: r for r in rows.get("tracks", [])},
            config=config,
            config_rows=config_rows,
            values=dict(values),
            value_rows=value_rows,
            changes=rows.get("changes", []),
            apply_runs=rows.get("apply_runs", []),
        )

    def live_tracks(self) -> list[dict[str, Any]]:
        return [t for t in self.tracks.values() if not t.get("deleted_at")]

    def baseline(self, track_id: str) -> Baseline:
        return Baseline.from_json(self.tracks[track_id].get("baseline"))

    def rows_for(self, track_id: str) -> dict[str, FieldValue]:
        return self.values.get(track_id, {})
