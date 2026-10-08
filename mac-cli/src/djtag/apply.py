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

import errno
import fcntl
import hashlib
import json
import os
import shutil
import unicodedata
import uuid
from collections.abc import Callable, Iterator
from contextlib import contextmanager, suppress
from dataclasses import asdict, dataclass, field, replace
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
from .scan import iso_from_timestamp, now_iso
from .settings import Settings, work_dir
from .state import ImportState
from .tags import TagOptions, TagWriteError, preserved_digest, read_managed, write_managed

ROLES = ("genre", "grouping", "comment", "rating")
FLUSH_EVERY = 50
SERATO_OPEN = (
    "Serato DJ est ouvert (ou impossible à vérifier) : le fermer avant d'écrire des tags (règle R6)."
)
SERATO_OPENED_DURING_RUN = (
    "Serato DJ a été ouvert pendant l'application : arrêt avant le fichier suivant (règle R6)."
)
TRIAL_CHECK = (
    "Dans Serato DJ : créer un crate « Essai MyTags » et y glisser le dossier des copies. Comparer chaque "
    "copie à son original (colonne Location pour les distinguer) : cue points, boucles, beatgrid, couleurs "
    "et aperçu identiques ; nouveaux GENRE, GROUPING, COMMENT et note visibles. Ensuite, retirer les copies "
    "de Serato avant de supprimer le dossier. Les originaux et le cloud n'ont pas changé."
)
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
    status: str  # written | already | conflict | error | dry_run | skipped
    message: str | None = None
    changes: list[dict[str, Any]] = field(default_factory=list)
    expected: Baseline | None = field(default=None, repr=False, compare=False)


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
    stopped: str | None = None  # why the run ended before the last file

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
            "already": self.count("already"),
            "skipped": self.count("skipped"),
            "stopped": self.stopped,
            "report_md": self.report_md,
            "report_json": self.report_json,
            "outcomes": [_outcome_json(o) for o in self.outcomes],
        }


def _outcome_json(o: TrackOutcome) -> dict[str, Any]:
    data = asdict(o)
    data.pop("expected", None)
    return data


def new_run_id() -> str:
    return datetime.now(UTC).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]


def baseline_equal(a: Baseline, b: Baseline) -> bool:
    return all(tags_equal(getattr(a, r), getattr(b, r)) for r in ROLES)


def _differences(a: Baseline, b: Baseline) -> list[str]:
    return [TAG_LABELS[r] for r in ROLES if not tags_equal(getattr(a, r), getattr(b, r))]


def check_preconditions(settings: Settings, paths: list[str]) -> None:
    if serato.is_running():
        raise ApplyRefused(SERATO_OPEN)
    if not fp.available():
        raise ApplyRefused("fpcalc est introuvable : `brew install chromaprint`.")
    settings.ensure_dirs()
    sizes: list[int] = []
    for p in paths:
        try:
            sizes.append(Path(p).stat().st_size)
        except OSError:
            continue
    needed = sum(sizes)
    free = shutil.disk_usage(settings.backups_dir).free
    if needed * 1.1 + 200_000_000 > free:
        raise ApplyRefused(
            f"Espace disque insuffisant pour les sauvegardes : {needed / 1e9:.1f} Go nécessaires, {free / 1e9:.1f} Go libres."
        )
    # The temporary copy is written next to the file: its volume needs room for the largest one.
    largest = max(sizes, default=0)
    for folder in {Path(p).parent for p in paths}:
        try:
            room = shutil.disk_usage(folder).free
        except OSError:
            continue
        if largest + 50_000_000 > room:
            raise ApplyRefused(f"Espace disque insuffisant dans {folder} pour la copie temporaire.")


@contextmanager
def exclusive_run() -> Iterator[None]:
    """Only one apply or rollback at a time (the user and Claude Code may both launch one)."""
    lock_path = work_dir() / "apply.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with open(lock_path, "w") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ApplyRefused("Une autre application ou annulation est en cours.") from None
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


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
    """Hidden temporary file next to `path`, with a short name whatever the length of the original."""
    tag = hashlib.sha1(os.fsencode(path.name)).hexdigest()[:12]
    return path.with_name(f".djtag-tmp-{tag}-{os.getpid()}{path.suffix.lower()[:8]}")


def _backup_name(index: int, name: str) -> str:
    stem, suffix = os.path.splitext(name)
    budget = 200 - len(os.fsencode(suffix))
    raw = os.fsencode(stem)
    if len(raw) > budget:
        stem = raw[:budget].decode("utf-8", "ignore")
    return f"{index:05d}-{stem}{suffix}"


def _discard(path: Path) -> None:
    with suppress(OSError):
        path.unlink(missing_ok=True)


def _copy_into_library(src: Path, dest: Path) -> None:
    """Copy next to a library file. djtag never creates folders in the library."""
    if not dest.parent.is_dir():
        raise FileNotFoundError(errno.ENOENT, "dossier introuvable", str(dest.parent))
    try:
        clone_or_copy(src, dest)
    except BaseException:
        _discard(dest)
        raise


def real_target(path: Path) -> Path:
    """The file to write: a symlink in the library is followed, so the link itself stays a link."""
    return path.resolve() if path.is_symlink() else path


def _expected(item: TrackPlan) -> Baseline:
    values = {r: getattr(item.baseline, r) for r in ROLES}
    for change in item.changes:
        values[change.tag] = change.new
    return Baseline(**values)


class _SeratoOpened(Exception):
    pass


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
    if ctx.dry_run:
        return _run_apply(ctx)
    with exclusive_run():
        return _run_apply(ctx)


def _run_apply(ctx: ApplyContext) -> RunResult:
    s = ctx.settings
    opts = s.tag_options
    run = RunResult(new_run_id(), "dry_run" if ctx.dry_run else "apply", now_iso())
    if not ctx.dry_run:
        check_preconditions(s, [i.path for i in ctx.plan.items])
    elif serato.is_running():
        raise ApplyRefused(SERATO_OPEN)
    elif not fp.available():
        raise ApplyRefused("fpcalc est introuvable : `brew install chromaprint`.")
    backup_dir = s.backups_dir / run.run_id
    manifest = Manifest(run.run_id, run.started_at)
    if not ctx.dry_run:
        run.backup_dir = str(backup_dir)
        backup_dir.mkdir(parents=True, exist_ok=True)
        ctx.api.upsert_apply_run(_run_row(run, backup_dir))

    pending = _Pending()
    total = len(ctx.plan.items)
    completed = False
    try:
        for index, item in enumerate(ctx.plan.items, 1):
            try:
                outcome = _apply_one(ctx, item, index, backup_dir, manifest, opts)
            except _SeratoOpened:
                run.stopped = SERATO_OPENED_DURING_RUN
                run.outcomes.extend(
                    _skipped(i, "non écrit : Serato DJ ouvert") for i in ctx.plan.items[index - 1 :]
                )
                break
            except Exception as exc:  # one bad file never stops the run
                outcome = TrackOutcome(
                    item.track_id, item.path, "error", f"erreur inattendue : {exc}", _change_rows(item)
                )
            run.outcomes.append(outcome)
            if not ctx.dry_run:
                pending.record(ctx, item, outcome)
            if ctx.progress:
                ctx.progress(index, total)
            if not ctx.dry_run and len(pending.patches) >= FLUSH_EVERY:
                pending.flush(ctx.api, run.run_id)
        completed = True
    finally:
        # Even when interrupted (Ctrl-C, network), the files already written are reported to the cloud.
        _finish(ctx, run, backup_dir, pending, strict=completed)
    return run


@dataclass
class _Pending:
    patches: list[dict[str, Any]] = field(default_factory=list)
    written_ids: list[str] = field(default_factory=list)

    def record(self, ctx: ApplyContext, item: TrackPlan, outcome: TrackOutcome) -> None:
        if outcome.status in ("written", "already"):
            self.written_ids.append(item.track_id)
            self.patches.append(
                _success_patch(outcome.expected or _expected(item), item.track_id, Path(item.path))
            )
            _update_state(ctx.state, Path(item.path))
        elif outcome.status in ("conflict", "error"):
            self.patches.append(
                {
                    "id": item.track_id,
                    "apply_status": "conflit" if outcome.status == "conflict" else "erreur",
                    "apply_message": outcome.message,
                }
            )

    def flush(self, api: Api, run_id: str) -> None:
        _flush(api, self.patches, self.written_ids, run_id)
        self.patches, self.written_ids = [], []


def _finish(ctx: ApplyContext, run: RunResult, backup_dir: Path, pending: _Pending, strict: bool) -> None:
    error: Exception | None = None
    if not ctx.dry_run:
        try:
            pending.flush(ctx.api, run.run_id)
        except Exception as exc:
            error = exc
    run.finished_at = now_iso()
    if not ctx.dry_run:
        try:
            ctx.api.upsert_apply_run(_run_row(run, backup_dir))
        except Exception as exc:
            error = error or exc
    try:
        _write_reports(ctx.settings, run)
    except Exception as exc:
        error = error or exc
    if error is not None and strict:
        raise error


def _change_rows(item: TrackPlan) -> list[dict[str, Any]]:
    return [{"tag": TAG_LABELS[c.tag], "current": c.current, "new": c.new} for c in item.changes]


def _skipped(item: TrackPlan, message: str) -> TrackOutcome:
    return TrackOutcome(item.track_id, item.path, "skipped", message, _change_rows(item))


def _without_blocked_rating(item: TrackPlan, block: str | None) -> tuple[TrackPlan, str | None]:
    """Decision 0006: a rating that cannot be written is left out; the other tags are still written."""
    if block is None or not any(c.tag == "rating" for c in item.changes):
        return item, None
    changes = [c for c in item.changes if c.tag != "rating"]
    targets = replace(item.targets, rating=item.baseline.rating)
    return replace(item, changes=changes, targets=targets), block


@dataclass
class _Ready:
    """A track that passed every pre-check and has tags to write."""

    item: TrackPlan
    path: Path
    target: Path  # the file to write (a library symlink is followed)
    expected: Baseline
    todo: dict[str, str | int | None]
    note: str | None


def _prepare(item: TrackPlan, opts: TagOptions, outcome: TrackOutcome) -> _Ready | None:
    """Pre-checks shared by apply and the trial on copies; fills `outcome` and returns None to stop."""
    path = Path(item.path)
    if not path.exists():
        outcome.message = "fichier introuvable (lancer `djtag import`)"
        return None
    target = real_target(path)
    try:
        managed = read_managed(target, item.format, opts)
    except Exception as exc:
        outcome.message = f"lecture impossible : {exc}"
        return None
    item, note = _without_blocked_rating(item, managed.rating_block)
    outcome.changes = _change_rows(item)
    if not item.changes:
        outcome.status, outcome.message = "skipped", note
        return None
    current = managed.baseline()
    expected = _expected(item)
    # Each tag must be as imported, or already as wanted (a run interrupted before it told the cloud).
    foreign = [
        TAG_LABELS[r]
        for r in ROLES
        if not tags_equal(getattr(current, r), getattr(item.baseline, r))
        and not tags_equal(getattr(current, r), getattr(expected, r))
    ]
    if foreign:
        outcome.status, outcome.message = "conflict", "modifié depuis l'import : " + ", ".join(foreign)
        return None
    if not item.fingerprint:
        outcome.status, outcome.message = (
            "conflict",
            "empreinte acoustique inconnue : relancer `djtag import`",
        )
        return None
    f = fp.compute(target)
    if f is None or f.digest != item.fingerprint:
        outcome.status, outcome.message = "conflict", "empreinte acoustique différente (fichier remplacé ?)"
        return None
    outcome.expected = expected
    todo = {c.tag: c.new for c in item.changes if not tags_equal(getattr(current, c.tag), c.new)}
    if not todo:
        outcome.status, outcome.message = "already", "déjà à jour"
        return None
    return _Ready(item, path, target, expected, todo, note)


def _apply_one(
    ctx: ApplyContext, item: TrackPlan, index: int, backup_dir: Path, manifest: Manifest, opts: TagOptions
) -> TrackOutcome:
    outcome = TrackOutcome(item.track_id, item.path, "error", changes=_change_rows(item))
    ready = _prepare(item, opts, outcome)
    if ready is None:
        return outcome
    item, path, target, expected, todo, note = (
        ready.item,
        ready.path,
        ready.target,
        ready.expected,
        ready.todo,
        ready.note,
    )
    if ctx.dry_run:
        outcome.status, outcome.message = "dry_run", note
        return outcome

    backup_name = _backup_name(index, path.name)
    method = clone_or_copy(target, backup_dir / backup_name)
    digest = sha256_file(backup_dir / backup_name)
    if sha256_file(target) != digest:
        outcome.message = "le fichier a changé pendant la sauvegarde"
        return outcome
    entry = BackupEntry(
        item.track_id, str(path), backup_name, digest, item.baseline.to_json(), item.targets.to_json(), method
    )
    manifest.entries.append(entry)
    manifest.save(backup_dir)

    temp = _temp_path(target)
    try:
        try:
            _copy_into_library(target, temp)
            write_managed(temp, item.format, todo, opts)
            verify_copy(target, temp, item.format, opts, expected)
        except (TagWriteError, VerifyError, OSError) as exc:
            outcome.message = str(exc)
            return outcome
        # Recorded before the replace: a crash right after it can still be rolled back.
        entry.sha256_after = sha256_file(temp)
        manifest.save(backup_dir)
        if serato.is_running():
            raise _SeratoOpened
        if sha256_file(target) != digest:
            outcome.message = "le fichier a changé pendant l'écriture"
            return outcome
        os.replace(temp, target)
        fsync_dir(target.parent)
    finally:
        _discard(temp)

    final = read_managed(target, item.format, opts).baseline()
    if not baseline_equal(final, expected):
        _restore(backup_dir / backup_name, target)
        outcome.message = "relecture finale différente : fichier restauré depuis la sauvegarde"
        return outcome
    entry.written = True
    manifest.save(backup_dir)
    outcome.status, outcome.message = "written", note
    return outcome


def _restore(backup: Path, path: Path) -> None:
    temp = _temp_path(path)
    _copy_into_library(backup, temp)
    try:
        os.replace(temp, path)
    finally:
        _discard(temp)
    fsync_dir(path.parent)


def _success_patch(expected: Baseline, track_id: str, path: Path) -> dict[str, Any]:
    st = path.stat()
    return {
        "id": track_id,
        "baseline": expected.to_json(),
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
    title = {
        "apply": "Application",
        "dry_run": "Simulation",
        "rollback": "Annulation",
        "trial": "Essai sur copies",
    }[run.mode]
    lines = [
        f"# {title} {run.run_id}",
        "",
        f"- Début : {run.started_at} ; fin : {run.finished_at}",
        f"- Écrits : {run.count('written')} ; conflits : {run.count('conflict')} ; erreurs : {run.count('error')}"
        + (f" ; simulés : {run.count('dry_run')}" if run.mode == "dry_run" else ""),
    ]
    if run.stopped:
        lines.append(f"- **Arrêt** : {run.stopped}")
    if run.backup_dir:
        where = "Copies" if run.mode == "trial" else "Sauvegarde"
        lines.append(f"- {where} : `{run.backup_dir}`")
    for status, label in (
        ("written", "Écrits"),
        ("already", "Déjà à jour"),
        ("conflict", "Conflits"),
        ("error", "Erreurs"),
        ("skipped", "Non traités"),
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
    if run.mode == "trial" and run.count("written"):
        lines += ["", "## Contrôle dans Serato", "", TRIAL_CHECK]
    md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    js.write_text(json.dumps(run.to_json(), ensure_ascii=False, indent=1), encoding="utf-8")


# -- trial on copies (rule R4) --------------------------------------------------------------------


def run_trial(ctx: ApplyContext, dest: Path) -> RunResult:
    """Write the pending tags into copies in a new subfolder of `dest`, outside the library (rule R4).

    The library, the cloud and the import state are left untouched: the copies are meant to be
    opened in Serato and compared with the originals before the first real application.
    """
    s = ctx.settings
    dest = dest.expanduser().resolve()
    _check_trial_folder(dest, s.music_folders)
    if serato.is_running():
        raise ApplyRefused(SERATO_OPEN)
    if not fp.available():
        raise ApplyRefused("fpcalc est introuvable : `brew install chromaprint`.")
    with exclusive_run():
        run = RunResult(new_run_id(), "trial", now_iso())
        folder = dest / f"essai-{run.run_id}"  # a new folder per trial: no stale file is ever reused
        try:
            dest.mkdir(parents=True, exist_ok=True)
            needed = sum(_size(Path(i.path)) for i in ctx.plan.items)
            free = shutil.disk_usage(dest).free
            folder.mkdir()
        except OSError as exc:
            raise ApplyRefused(f"Dossier des copies inutilisable : {exc}") from exc
        if needed * 1.1 + 200_000_000 > free:
            folder.rmdir()
            raise ApplyRefused(f"Espace disque insuffisant dans {dest} pour les copies.")
        run.backup_dir = str(folder)
        total = len(ctx.plan.items)
        for index, item in enumerate(ctx.plan.items, 1):
            try:
                outcome = _trial_one(item, folder, s.tag_options)
            except Exception as exc:
                outcome = TrackOutcome(
                    item.track_id, item.path, "error", f"erreur inattendue : {exc}", _change_rows(item)
                )
            run.outcomes.append(outcome)
            if ctx.progress:
                ctx.progress(index, total)
        run.finished_at = now_iso()
        _write_reports(s, run)
        return run


def _size(path: Path) -> int:
    try:
        return path.stat().st_size
    except OSError:
        return 0


SERATO_FOLDERS = ("_serato_", "_serato_backup")


def _check_trial_folder(dest: Path, music_folders: list[Path]) -> None:
    """Refuse a copies folder inside or around a music folder, whatever its spelling, or Serato's own."""
    if any(part.casefold() in SERATO_FOLDERS for part in dest.parts):
        raise ApplyRefused("Le dossier des copies ne peut pas être dans un dossier de Serato.")
    for folder in music_folders:
        root = folder.expanduser().resolve()
        if _same_or_inside(dest, root) or _same_or_inside(root, dest):
            raise ApplyRefused(f"Le dossier des copies doit être hors des dossiers de musique ({root}).")


def _same_or_inside(path: Path, root: Path) -> bool:
    """`path` is `root` or below it, by file identity when possible (case and Unicode spellings)."""
    try:
        root_stat = root.stat()
    except OSError:
        root_stat = None
    for candidate in (path, *path.parents):
        if root_stat is not None:
            try:
                if os.path.samestat(candidate.stat(), root_stat):
                    return True
            except OSError:
                pass
        if _spelling(candidate) == _spelling(root):
            return True
    return False


def _spelling(path: Path) -> str:
    return unicodedata.normalize("NFC", str(path)).casefold()


def _trial_one(item: TrackPlan, folder: Path, opts: TagOptions) -> TrackOutcome:
    outcome = TrackOutcome(item.track_id, item.path, "error", changes=_change_rows(item))
    ready = _prepare(item, opts, outcome)
    if ready is None:
        return outcome
    copy = _free_name(folder / ready.path.name)
    try:
        clone_or_copy(ready.target, copy)
        write_managed(copy, ready.item.format, ready.todo, opts)
        verify_copy(ready.target, copy, ready.item.format, opts, ready.expected)
    except (TagWriteError, VerifyError, OSError) as exc:
        _discard(copy)
        outcome.message = str(exc)
        return outcome
    except BaseException:
        _discard(copy)  # never leave a half-written copy to be checked in Serato
        raise
    outcome.status = "written"
    outcome.message = str(copy) + (f" — {ready.note}" if ready.note else "")
    return outcome


def _free_name(path: Path) -> Path:
    if not os.path.lexists(path):
        return path
    for n in range(2, 10_000):
        candidate = path.with_name(f"{path.stem} ({n}){path.suffix}")
        if not os.path.lexists(candidate):
            return candidate
    raise OSError(errno.EEXIST, "trop de copies portant ce nom", str(path))


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
    with exclusive_run():
        return _run_rollback(ctx)


def _run_rollback(ctx: RollbackContext) -> RunResult:
    if serato.is_running():
        raise ApplyRefused(SERATO_OPEN)
    folder = ctx.settings.backups_dir / ctx.run_id
    if not (folder / "manifest.json").exists():
        raise ApplyRefused(f"aucune sauvegarde pour l'application {ctx.run_id}")
    manifest = Manifest.load(folder)
    run = RunResult(new_run_id(), "rollback", now_iso(), backup_dir=str(folder))
    ctx.api.upsert_apply_run(_run_row(run, folder))
    patches: list[dict[str, Any]] = []
    restored: list[str] = []
    try:
        for entry in manifest.entries:
            if ctx.track_ids and entry.track_id not in ctx.track_ids:
                continue
            if not entry.written and not _replaced_unconfirmed(entry):
                continue
            if serato.is_running():
                run.stopped = SERATO_OPENED_DURING_RUN
                break
            outcome = TrackOutcome(entry.track_id, entry.path, "error")
            run.outcomes.append(outcome)
            try:
                _rollback_one(ctx, folder, entry, outcome)
            except Exception as exc:
                outcome.status, outcome.message = "error", f"erreur inattendue : {exc}"
            if outcome.status != "written":
                continue
            target = real_target(Path(entry.path))
            st = target.stat()
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
            _update_state(ctx.state, Path(entry.path))
    finally:
        if patches:
            ctx.api.patch_tracks(patches)
        if restored:
            ctx.api.mark_changes(restored, "sent", run.run_id, from_status="applied")
        run.finished_at = now_iso()
        ctx.api.upsert_apply_run(_run_row(run, folder))
        _write_reports(ctx.settings, run)
    return run


def _replaced_unconfirmed(entry: BackupEntry) -> bool:
    """The run stopped between the replace and its confirmation: the file holds the verified copy."""
    if not entry.sha256_after:
        return False
    target = real_target(Path(entry.path))
    return target.is_file() and sha256_file(target) == entry.sha256_after


def _rollback_one(ctx: RollbackContext, folder: Path, entry: BackupEntry, outcome: TrackOutcome) -> None:
    backup = folder / entry.backup
    target = real_target(Path(entry.path))
    if not backup.exists() or sha256_file(backup) != entry.sha256:
        outcome.message = "sauvegarde absente ou altérée"
        return
    if not target.exists():
        # Moved, renamed or deleted since: restoring would put a copy back at the old place (R1).
        if not ctx.force:
            outcome.message = (
                "fichier introuvable (déplacé ou supprimé) : relancer avec --force pour le recréer"
            )
            return
        if not target.parent.is_dir():
            outcome.message = "dossier introuvable : djtag ne recrée pas de dossier"
            return
    else:
        current = sha256_file(target)
        if current == entry.sha256:
            outcome.status, outcome.message = "written", "déjà restauré"
            return
        if entry.sha256_after and current != entry.sha256_after and not ctx.force:
            outcome.message = (
                "fichier modifié depuis l'application (Serato ?) : relancer avec --force pour écraser"
            )
            return
    _restore(backup, target)
    if sha256_file(target) != entry.sha256:
        outcome.message = "restauration incomplète"
        return
    outcome.status = "written"
