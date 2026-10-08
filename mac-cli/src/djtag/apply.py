"""`djtag apply` and `djtag rollback`: the only commands that write audio files (spec section 12).

Safety barriers, in order, for every file:
1. Serato closed (R6), fingerprint and managed tags identical to the Reference (else Conflict);
2. backup of the original (APFS clone when possible) recorded in a manifest *before* writing (R2);
3. tags written into a temporary copy next to the file, never into the original;
4. verification of the copy: every unmanaged tag and the audio identical, managed tags as expected;
5. atomic replacement of the original by the verified copy, then a final read-back
   (restored from the backup if it ever differs).
"""

from __future__ import annotations

import json
import os
import shutil
import uuid
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from . import fingerprint as fp
from . import serato
from .api import Api
from .backup import BackupEntry, Manifest, clone_or_copy, fsync_dir, sha256_file
from .cloud import CloudState
from .model.values import tags_equal
from .model.values_types import Baseline
from .plan import TAG_LABELS, Plan, TrackPlan
from .scan import now_iso
from .settings import Settings
from .state import ImportState
from .tags import TagOptions, TagWriteError, preserved_digest, read_managed, write_managed

ROLES = ("genre", "grouping", "comment", "rating")
FLUSH_EVERY = 50
SERATO_RESCAN = (
    "Dans Serato DJ Pro 4 : sélectionner les morceaux modifiés, clic droit › « Re-Scan File Info ». "
    "Voir docs/serato.md."
)


class ApplyRefused(Exception):
    """Safety refusal (exit code 3): nothing was written."""


class VerifyError(Exception):
    pass


@dataclass
class TrackOutcome:
    track_id: str
    path: str
    status: str  # written | conflict | error | dry_run | skipped
    message: str | None = None
    changes: list[dict[str, Any]] = field(default_factory=list)


@dataclass
class RunResult:
    run_id: str
    mode: str
    started_at: str
    finished_at: str | None = None
    backup_dir: str | None = None
    outcomes: list[TrackOutcome] = field(default_factory=list)
    report_md: str | None = None
    report_json: str | None = None

    def count(self, status: str) -> int:
        return sum(1 for o in self.outcomes if o.status == status)

    def to_json(self) -> dict[str, Any]:
        return {
            "run_id": self.run_id,
            "mode": self.mode,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "backup_dir": self.backup_dir,
            "written": self.count("written"),
            "conflicts": self.count("conflict"),
            "errors": self.count("error"),
            "dry_run": self.count("dry_run"),
            "report_md": self.report_md,
            "report_json": self.report_json,
            "outcomes": [asdict(o) for o in self.outcomes],
        }


def new_run_id() -> str:
    return datetime.now(UTC).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]


def baseline_equal(a: Baseline, b: Baseline) -> bool:
    return all(tags_equal(getattr(a, r), getattr(b, r)) for r in ROLES)


def _differences(a: Baseline, b: Baseline) -> list[str]:
    return [TAG_LABELS[r] for r in ROLES if not tags_equal(getattr(a, r), getattr(b, r))]


def check_preconditions(settings: Settings, paths: list[str]) -> None:
    if serato.is_running():
        raise ApplyRefused("Serato DJ est ouvert : le fermer avant d'écrire des tags (règle R6).")
    if not fp.available():
        raise ApplyRefused("fpcalc est introuvable : `brew install chromaprint`.")
    settings.ensure_dirs()
    needed = 0
    for p in paths:
        try:
            needed += Path(p).stat().st_size
        except OSError:
            continue
    free = shutil.disk_usage(settings.backups_dir).free
    if needed * 1.1 + 200_000_000 > free:
        raise ApplyRefused(
            f"Espace disque insuffisant pour les sauvegardes : {needed / 1e9:.1f} Go nécessaires, {free / 1e9:.1f} Go libres."
        )


def verify_copy(original: Path, copy: Path, fmt: str, opts: TagOptions, expected: Baseline) -> None:
    before = preserved_digest(original, fmt, opts)
    after = preserved_digest(copy, fmt, opts)
    if not any(name == "id3.header" for name, _ in before):
        after = [d for d in after if d[0] != "id3.header"]
    if before != after:
        names_before = dict(before)
        changed = [n for n, h in after if names_before.get(n) != h] or ["structure"]
        raise VerifyError("données non gérées modifiées : " + ", ".join(changed[:5]))
    got = read_managed(copy, fmt, opts).baseline()
    diffs = _differences(got, expected)
    if diffs:
        raise VerifyError("relecture différente pour " + ", ".join(diffs))


def _temp_path(path: Path) -> Path:
    return path.with_name(f".{path.name}.djtag-tmp-{os.getpid()}")


def _expected(item: TrackPlan) -> Baseline:
    values = {r: getattr(item.baseline, r) for r in ROLES}
    for change in item.changes:
        values[change.tag] = change.new
    return Baseline(**values)


@dataclass
class ApplyContext:
    settings: Settings
    api: Api
    cloud: CloudState
    state: ImportState
    plan: Plan
    dry_run: bool = False
    progress: Callable[[int, int], None] | None = None


def run_apply(ctx: ApplyContext) -> RunResult:
    s = ctx.settings
    opts = s.tag_options
    run = RunResult(new_run_id(), "dry_run" if ctx.dry_run else "apply", now_iso())
    if not ctx.dry_run:
        check_preconditions(s, [i.path for i in ctx.plan.items])
    elif serato.is_running():
        raise ApplyRefused("Serato DJ est ouvert : le fermer avant d'appliquer (règle R6).")
    backup_dir = s.backups_dir / run.run_id
    manifest = Manifest(run.run_id, run.started_at)
    if not ctx.dry_run:
        run.backup_dir = str(backup_dir)
        backup_dir.mkdir(parents=True, exist_ok=True)
        ctx.api.upsert_apply_run(_run_row(run, backup_dir))

    patches: list[dict[str, Any]] = []
    written_ids: list[str] = []
    total = len(ctx.plan.items)
    for index, item in enumerate(ctx.plan.items, 1):
        outcome = _apply_one(ctx, item, index, backup_dir, manifest, opts)
        run.outcomes.append(outcome)
        if outcome.status == "written":
            written_ids.append(item.track_id)
            patches.append(_success_patch(item, Path(item.path)))
            _update_state(ctx.state, Path(item.path))
        elif outcome.status in ("conflict", "error") and not ctx.dry_run:
            patches.append(
                {
                    "id": item.track_id,
                    "apply_status": "conflit" if outcome.status == "conflict" else "erreur",
                    "apply_message": outcome.message,
                }
            )
        if ctx.progress:
            ctx.progress(index, total)
        if not ctx.dry_run and len(patches) >= FLUSH_EVERY:
            _flush(ctx.api, patches, written_ids, run.run_id)
            patches, written_ids = [], []
    if not ctx.dry_run:
        _flush(ctx.api, patches, written_ids, run.run_id)
    run.finished_at = now_iso()
    if not ctx.dry_run:
        ctx.api.upsert_apply_run(_run_row(run, backup_dir))
    _write_reports(s, run)
    return run


def _apply_one(
    ctx: ApplyContext, item: TrackPlan, index: int, backup_dir: Path, manifest: Manifest, opts: TagOptions
) -> TrackOutcome:
    path = Path(item.path)
    outcome = TrackOutcome(
        item.track_id,
        item.path,
        "error",
        changes=[{"tag": TAG_LABELS[c.tag], "current": c.current, "new": c.new} for c in item.changes],
    )
    if not path.exists():
        outcome.message = "fichier introuvable (lancer `djtag import`)"
        return outcome
    try:
        current = read_managed(path, item.format, opts).baseline()
    except Exception as exc:
        outcome.message = f"lecture impossible : {exc}"
        return outcome
    diffs = _differences(current, item.baseline)
    if diffs:
        outcome.status, outcome.message = "conflict", "modifié depuis l'import : " + ", ".join(diffs)
        return outcome
    if item.fingerprint:
        f = fp.compute(path)
        if f is None or f.digest != item.fingerprint:
            outcome.status, outcome.message = (
                "conflict",
                "empreinte acoustique différente (fichier remplacé ?)",
            )
            return outcome
    if ctx.dry_run:
        outcome.status = "dry_run"
        return outcome

    backup_name = f"{index:05d}-{path.name}"
    method = clone_or_copy(path, backup_dir / backup_name)
    digest = sha256_file(backup_dir / backup_name)
    if sha256_file(path) != digest:
        outcome.message = "le fichier a changé pendant la sauvegarde"
        return outcome
    entry = BackupEntry(
        item.track_id, str(path), backup_name, digest, item.baseline.to_json(), item.targets.to_json(), method
    )
    manifest.entries.append(entry)
    manifest.save(backup_dir)

    expected = _expected(item)
    temp = _temp_path(path)
    try:
        clone_or_copy(path, temp)
        write_managed(temp, item.format, item.change_map(), opts)
        verify_copy(path, temp, item.format, opts, expected)
        os.replace(temp, path)
        fsync_dir(path.parent)
    except (TagWriteError, VerifyError, OSError) as exc:
        outcome.message = str(exc)
        return outcome
    finally:
        if temp.exists():
            temp.unlink()

    final = read_managed(path, item.format, opts).baseline()
    if not baseline_equal(final, expected):
        _restore(backup_dir / backup_name, path)
        outcome.message = "relecture finale différente : fichier restauré depuis la sauvegarde"
        return outcome
    entry.written = True
    entry.sha256_after = sha256_file(path)
    manifest.save(backup_dir)
    outcome.status = "written"
    return outcome


def _restore(backup: Path, path: Path) -> None:
    temp = _temp_path(path)
    clone_or_copy(backup, temp)
    os.replace(temp, path)
    fsync_dir(path.parent)


def _success_patch(item: TrackPlan, path: Path) -> dict[str, Any]:
    st = path.stat()
    from .scan import iso_from_timestamp

    return {
        "id": item.track_id,
        "baseline": _expected(item).to_json(),
        "apply_status": "applique",
        "apply_message": None,
        "applied_at": now_iso(),
        "file_size": st.st_size,
        "file_mtime": iso_from_timestamp(st.st_mtime),
    }


def _update_state(state: ImportState, path: Path) -> None:
    current = state.get(str(path))
    if current is None:
        return
    st = path.stat()
    current.size, current.mtime = st.st_size, st.st_mtime
    state.upsert(current)


def _flush(api: Api, patches: list[dict[str, Any]], written_ids: list[str], run_id: str) -> None:
    if patches:
        api.patch_tracks(patches)
    if written_ids:
        api.mark_changes(written_ids, "applied", run_id)


def _run_row(run: RunResult, backup_dir: Path) -> dict[str, Any]:
    return {
        "id": run.run_id,
        "started_at": run.started_at,
        "finished_at": run.finished_at,
        "mode": run.mode,
        "tracks_written": run.count("written"),
        "conflicts": run.count("conflict"),
        "errors": run.count("error"),
        "backup_path": str(backup_dir),
        "report_path": run.report_md,
    }


def _write_reports(s: Settings, run: RunResult) -> None:
    s.reports_dir.mkdir(parents=True, exist_ok=True)
    md = s.reports_dir / f"{run.mode}-{run.run_id}.md"
    js = s.reports_dir / f"{run.mode}-{run.run_id}.json"
    run.report_md, run.report_json = str(md), str(js)
    title = {"apply": "Application", "dry_run": "Simulation", "rollback": "Annulation"}[run.mode]
    lines = [
        f"# {title} {run.run_id}",
        "",
        f"- Début : {run.started_at} ; fin : {run.finished_at}",
        f"- Écrits : {run.count('written')} ; conflits : {run.count('conflict')} ; erreurs : {run.count('error')}"
        + (f" ; simulés : {run.count('dry_run')}" if run.mode == "dry_run" else ""),
    ]
    if run.backup_dir:
        lines.append(f"- Sauvegarde : `{run.backup_dir}`")
    for status, label in (
        ("written", "Écrits"),
        ("conflict", "Conflits"),
        ("error", "Erreurs"),
        ("dry_run", "Simulés"),
    ):
        rows = [o for o in run.outcomes if o.status == status]
        if not rows:
            continue
        lines += ["", f"## {label}", ""]
        for o in rows:
            detail = "; ".join(
                f"{c['tag']} : {c['current'] or '(vide)'} → {c['new'] or '(vide)'}" for c in o.changes
            )
            lines.append(
                f"- `{o.path}`"
                + (f" — {o.message}" if o.message else "")
                + (f" — {detail}" if detail else "")
            )
    if run.mode in ("apply", "rollback") and run.count("written"):
        lines += ["", "## Relecture dans Serato", "", SERATO_RESCAN]
    md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    js.write_text(json.dumps(run.to_json(), ensure_ascii=False, indent=1), encoding="utf-8")


# -- rollback --------------------------------------------------------------------------------------


@dataclass
class RollbackContext:
    settings: Settings
    api: Api
    state: ImportState
    run_id: str
    track_ids: set[str] | None = None
    force: bool = False


def run_rollback(ctx: RollbackContext) -> RunResult:
    if serato.is_running():
        raise ApplyRefused("Serato DJ est ouvert : le fermer avant d'annuler (règle R6).")
    folder = ctx.settings.backups_dir / ctx.run_id
    if not (folder / "manifest.json").exists():
        raise ApplyRefused(f"aucune sauvegarde pour l'application {ctx.run_id}")
    manifest = Manifest.load(folder)
    run = RunResult(new_run_id(), "rollback", now_iso(), backup_dir=str(folder))
    ctx.api.upsert_apply_run(_run_row(run, folder))
    patches: list[dict[str, Any]] = []
    restored: list[str] = []
    for entry in manifest.entries:
        if not entry.written or (ctx.track_ids and entry.track_id not in ctx.track_ids):
            continue
        outcome = TrackOutcome(entry.track_id, entry.path, "error")
        run.outcomes.append(outcome)
        backup = folder / entry.backup
        path = Path(entry.path)
        if not backup.exists() or sha256_file(backup) != entry.sha256:
            outcome.message = "sauvegarde absente ou altérée"
            continue
        if path.exists() and entry.sha256_after and sha256_file(path) != entry.sha256_after and not ctx.force:
            outcome.message = (
                "fichier modifié depuis l'application (Serato ?) : relancer avec --force pour écraser"
            )
            continue
        _restore(backup, path)
        if sha256_file(path) != entry.sha256:
            outcome.message = "restauration incomplète"
            continue
        outcome.status = "written"
        st = path.stat()
        from .scan import iso_from_timestamp

        patches.append(
            {
                "id": entry.track_id,
                "baseline": entry.baseline_before,
                "apply_status": "aucun",
                "apply_message": f"Application {ctx.run_id} annulée",
                "file_size": st.st_size,
                "file_mtime": iso_from_timestamp(st.st_mtime),
            }
        )
        restored.append(entry.track_id)
        _update_state(ctx.state, path)
    if patches:
        ctx.api.patch_tracks(patches)
    if restored:
        ctx.api.mark_changes(restored, "sent", run.run_id, from_status="applied")
    run.finished_at = now_iso()
    ctx.api.upsert_apply_run(_run_row(run, folder))
    _write_reports(ctx.settings, run)
    return run
