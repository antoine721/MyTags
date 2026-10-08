"""`djtag resolve`: settle a Conflict without writing any audio file.

--keep-file : the file's tags become the track's values (the app's rows are reverted).
--keep-app  : the file's tags become the new Reference; the next `apply` writes the app's values.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import fingerprint as fp
from .api import Api
from .cloud import CloudState
from .model.comment import parse_comment
from .model.values import compute_targets, tags_equal
from .scan import now_iso
from .settings import Settings
from .tags import read_managed

ROLE_TAG = {"genre": "GENRE", "grouping": "GROUPING", "comment": "COMMENT", "rating": "RATING"}


@dataclass
class ResolveResult:
    resolved: list[str] = field(default_factory=list)
    errors: list[dict[str, str]] = field(default_factory=list)


def resolve(
    settings: Settings, api: Api, cloud: CloudState, track_ids: list[str], keep: str
) -> ResolveResult:
    if keep not in ("file", "app"):
        raise ValueError("keep must be 'file' or 'app'")
    result = ResolveResult()
    patches: list[dict[str, Any]] = []
    reverts: list[dict[str, Any]] = []
    config = cloud.config
    for track_id in track_ids:
        track = cloud.tracks.get(track_id)
        if track is None:
            result.errors.append({"track_id": track_id, "error": "morceau inconnu"})
            continue
        path = Path(track.get("file_path") or "")
        fmt = track.get("file_format") or ""
        try:
            current = read_managed(path, fmt, settings.tag_options).baseline()
        except Exception as exc:
            result.errors.append({"track_id": track_id, "error": f"lecture impossible : {exc}"})
            continue
        # The file as it is now becomes the reference, its acoustic fingerprint included.
        acoustic = fp.compute(path)
        if acoustic is None:
            result.errors.append({"track_id": track_id, "error": "empreinte acoustique impossible (fpcalc)"})
            continue
        rows = cloud.rows_for(track_id)
        if keep == "file":
            targets = compute_targets(fmt, current, rows, config)
            for role, tag in ROLE_TAG.items():
                if tags_equal(getattr(targets, role), getattr(current, role)):
                    continue
                for f in config.fields:
                    if f.target_tag == tag and f.id in rows:
                        reverts.append(
                            {
                                "id": str(uuid.uuid4()),
                                "track_id": track_id,
                                "field_id": f.id,
                                "old_value": rows[f.id].to_json(),
                                "new_value": None,
                                "source": "file",
                                "created_at": now_iso(),
                            }
                        )
        patches.append(
            {
                "id": track_id,
                "baseline": current.to_json(),
                "fingerprint": acoustic.digest,
                "comment_status": parse_comment(current.comment, config).status,
                "apply_status": "aucun",
                "apply_message": None,
            }
        )
        result.resolved.append(track_id)
    if reverts:
        api.push(reverts)
    if patches:
        api.patch_tracks(patches)
    return result
