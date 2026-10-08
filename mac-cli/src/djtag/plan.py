"""`djtag diff` / `djtag status`: what `apply` would write, track by track."""

from __future__ import annotations

from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass, field
from typing import Any

from .cloud import CloudState
from .model.values import compute_targets, differing_tags
from .model.values_types import Baseline
from .settings import Settings
from .tags import containers

TAG_LABELS = {"genre": "GENRE", "grouping": "GROUPING", "comment": "COMMENT", "rating": "NOTE"}


@dataclass
class TagChange:
    tag: str  # genre | grouping | comment | rating
    current: str | int | None
    new: str | int | None


@dataclass
class TrackPlan:
    track_id: str
    path: str
    format: str
    title: str | None
    artist: str | None
    baseline: Baseline
    targets: Baseline
    fingerprint: str | None
    changes: list[TagChange]
    warnings: list[str] = field(default_factory=list)

    def change_map(self) -> dict[str, str | int | None]:
        return {c.tag: c.new for c in self.changes}


@dataclass
class Plan:
    items: list[TrackPlan] = field(default_factory=list)
    conflicts: list[dict[str, Any]] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def totals(self) -> dict[str, int]:
        counter = Counter(c.tag for item in self.items for c in item.changes)
        return {TAG_LABELS[k]: counter[k] for k in TAG_LABELS if counter[k]}

    def to_json(self) -> dict[str, Any]:
        return {
            "to_apply": len(self.items),
            "totals": self.totals,
            "conflicts": self.conflicts,
            "warnings": self.warnings,
            "tracks": [
                {
                    "track_id": i.track_id,
                    "path": i.path,
                    "title": i.title,
                    "artist": i.artist,
                    "changes": [
                        {"tag": TAG_LABELS[c.tag], "current": c.current, "new": c.new} for c in i.changes
                    ],
                    "warnings": i.warnings,
                }
                for i in self.items
            ],
        }


def build_plan(
    cloud: CloudState, settings: Settings, *, track_ids: Iterable[str] | None = None, limit: int | None = None
) -> Plan:
    wanted = set(track_ids) if track_ids else None
    plan = Plan()
    config = cloud.config
    popm_missing = 0
    for track in sorted(cloud.live_tracks(), key=lambda t: t.get("file_path") or ""):
        if wanted is not None and track["id"] not in wanted:
            continue
        if track.get("apply_status") == "conflit":
            plan.conflicts.append(
                {
                    "track_id": track["id"],
                    "path": track.get("file_path"),
                    "message": track.get("apply_message"),
                }
            )
            continue
        fmt = track.get("file_format") or ""
        baseline = Baseline.from_json(track.get("baseline"))
        targets = compute_targets(fmt, baseline, cloud.rows_for(track["id"]), config)
        tags = differing_tags(targets, baseline)
        if not tags:
            continue
        warnings: list[str] = []
        if "rating" in tags and targets.rating is not None and not 1 <= targets.rating <= 5:
            tags.remove("rating")
            warnings.append(f"note non écrite : valeur invalide ({targets.rating})")
            targets = Baseline(targets.genre, targets.grouping, targets.comment, baseline.rating)
            if not tags:
                continue
        if "rating" in tags and fmt in containers.ID3_FORMATS and not settings.popm_email:
            tags.remove("rating")
            popm_missing += 1
            warnings.append("note non écrite : propriétaire POPM inconnu")
            targets = Baseline(targets.genre, targets.grouping, targets.comment, baseline.rating)
            if not tags:
                continue
        plan.items.append(
            TrackPlan(
                track_id=track["id"],
                path=track.get("file_path") or "",
                format=fmt,
                title=track.get("title"),
                artist=track.get("artist"),
                baseline=baseline,
                targets=targets,
                fingerprint=track.get("fingerprint"),
                changes=[TagChange(t, getattr(baseline, t), getattr(targets, t)) for t in tags],
                warnings=warnings,
            )
        )
        if limit is not None and len(plan.items) >= limit:
            break
    if popm_missing:
        plan.warnings.append(
            f"{popm_missing} notes non écrites : régler le propriétaire POPM relevé par l'audit "
            "(djtag config set tags.popm_email <valeur>)"
        )
    return plan


def plan_markdown(plan: Plan) -> str:
    lines = ["# Aperçu des changements", "", f"{len(plan.items)} morceaux à appliquer."]
    if plan.totals:
        lines += ["", "| Tag | Morceaux |", "| --- | --- |"]
        lines += [f"| {k} | {v} |" for k, v in plan.totals.items()]
    for item in plan.items:
        lines += [
            "",
            f"## {item.artist or '?'} — {item.title or '?'}",
            "",
            f"`{item.path}`",
            "",
            "| Tag | Fichier | Nouveau |",
            "| --- | --- | --- |",
        ]
        lines += [f"| {TAG_LABELS[c.tag]} | {_fmt(c.current)} | {_fmt(c.new)} |" for c in item.changes]
        lines += [f"- ⚠️ {w}" for w in item.warnings]
    if plan.conflicts:
        lines += ["", "## Conflits", ""]
        lines += [f"- `{c['path']}` : {c['message']}" for c in plan.conflicts]
    return "\n".join(lines) + "\n"


def _fmt(value: object) -> str:
    return "(vide)" if value in (None, "") else str(value)
