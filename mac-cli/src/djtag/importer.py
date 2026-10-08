"""`djtag import`: send new and changed files to the cloud (spec section 12, "import").

Order of work:
1. scan the folders and skip files whose size and mtime did not change;
2. read tags, info and fingerprint of the others (in parallel);
3. recognise moved/renamed files by fingerprint (they keep their id);
4. build listening copies, waveform, start point and covers (in parallel);
5. upload audio and covers, then the catalogue rows;
6. mark vanished files as deleted (never when a music folder is missing).

The audio files of the library are only ever read.
"""

from __future__ import annotations

import os
import shutil
import uuid
from collections.abc import Callable
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from . import audio, cover
from . import fingerprint as fp
from .api import Api
from .cloud import CloudState
from .info import TrackInfo, read_info
from .model.comment import parse_comment
from .model.config import TagConfig
from .model.values import compute_targets, tags_equal
from .model.values_types import Baseline
from .scan import ScannedFile, iso_from_timestamp, now_iso, scan
from .settings import Settings
from .state import FileState, ImportState
from .tags import ManagedTags, TagOptions, read_managed

ROLE_TAG = {"genre": "GENRE", "grouping": "GROUPING", "comment": "COMMENT", "rating": "RATING"}
DELETED_BLOB_RETENTION = timedelta(days=30)
FLUSH_EVERY = 50


class ImportRefused(Exception):
    pass


# -- worker-side processing ------------------------------------------------------------------------


@dataclass
class Probe:
    path: str
    format: str
    managed: ManagedTags | None = None
    info: TrackInfo | None = None
    fingerprint: fp.Fingerprint | None = None
    error: str | None = None


def probe_file(args: tuple[str, str, TagOptions]) -> Probe:
    path, fmt, opts = args
    result = Probe(path, fmt)
    try:
        result.managed = read_managed(path, fmt, opts)
        result.info = read_info(Path(path), fmt)
        result.fingerprint = fp.compute(Path(path))
    except Exception as exc:
        result.error = f"{type(exc).__name__}: {exc}"
    return result


@dataclass
class Rendered:
    path: str
    track_id: str
    audio_path: str | None = None
    audio_size: int | None = None
    waveform: str | None = None
    start_ms: int | None = None
    covers: dict[int, str] | None = None
    error: str | None = None


def render_file(args: tuple[str, str, str, str, str, float, str]) -> Rendered:
    path, fmt, track_id, work, bitrate, lufs, encoder = args
    out = Rendered(path, track_id)
    work_dir = Path(work) / track_id
    try:
        src = Path(path)
        dest = work_dir / f"{track_id}.m4a"
        out.audio_size = audio.transcode(src, dest, bitrate=bitrate, target_lufs=lufs, encoder=encoder)
        out.audio_path = str(dest)
        samples = audio.decode_pcm(dest)
        out.waveform = audio.waveform_b64(samples)
        out.start_ms = audio.start_point_ms(samples)
        covers = cover.extract(src, fmt, work_dir, track_id)
        out.covers = {k: str(v) for k, v in covers.items()} if covers else None
    except Exception as exc:
        out.error = f"{type(exc).__name__}: {exc}"
    return out


# -- report -----------------------------------------------------------------------------------------


@dataclass
class ImportReport:
    scanned: int = 0
    unchanged: int = 0
    new: int = 0
    updated: int = 0
    moved: int = 0
    restored: int = 0
    deleted: int = 0
    conflicts: list[dict[str, str]] = field(default_factory=list)
    errors: list[dict[str, str]] = field(default_factory=list)
    uploaded_bytes: int = 0
    skipped_missing_folders: list[str] = field(default_factory=list)

    def to_json(self) -> dict[str, Any]:
        return self.__dict__.copy()


# -- orchestration -----------------------------------------------------------------------------------


@dataclass
class ImportContext:
    settings: Settings
    api: Api
    cloud: CloudState
    state: ImportState
    workers: int
    progress: Callable[[str, int, int], None] | None = None
    limit: int | None = None
    allow_mass_delete: bool = False
    report: ImportReport = field(default_factory=ImportReport)
    pending_rows: list[dict[str, Any]] = field(default_factory=list)
    pending_patches: list[dict[str, Any]] = field(default_factory=list)
    pending_reverts: list[dict[str, Any]] = field(default_factory=list)
    pending_state: list[FileState] = field(default_factory=list)

    @property
    def config(self) -> TagConfig:
        return self.cloud.config


def run_import(ctx: ImportContext) -> ImportReport:
    s = ctx.settings
    s.ensure_dirs()
    work = s.cache_dir / "import"
    work.mkdir(parents=True, exist_ok=True)
    report = ctx.report

    missing = [str(f) for f in s.music_folders if _unavailable(f.expanduser())]
    report.skipped_missing_folders = missing
    files = list(scan(s.music_folders, s.exclude))
    report.scanned = len(files)
    present = {str(f.path) for f in files}

    todo: list[tuple[ScannedFile, FileState | None]] = []
    for f in files:
        st = ctx.state.get(str(f.path))
        track = ctx.cloud.tracks.get(st.track_id) if st else None
        if (
            st is not None
            and st.stage == "cataloged"
            and st.size == f.size
            and st.mtime == f.mtime
            and track is not None
            and not track.get("deleted_at")
        ):
            report.unchanged += 1
            continue
        todo.append((f, st))
    if ctx.limit is not None:
        todo = todo[: ctx.limit]

    vanished = [
        st
        for st in ctx.state.all()
        if st.path not in present and not Path(st.path).exists() and not _under_missing(st.path, missing)
    ]

    # 2. probe
    probes = _parallel(ctx, "Lecture", probe_file, [(str(f.path), f.format, s.tag_options) for f, _ in todo])
    by_path = {p.path: p for p in probes}

    # 3. decide what each file is
    vanished_by_fp: dict[str, list[FileState]] = {}
    for st in vanished:
        if st.fingerprint:
            vanished_by_fp.setdefault(st.fingerprint, []).append(st)
    deleted_by_fp = _recently_deleted_by_fingerprint(ctx.cloud)
    to_render: list[tuple[ScannedFile, str, Probe]] = []
    for f, st in todo:
        probe = by_path[str(f.path)]
        if probe.error or probe.managed is None or probe.info is None:
            report.errors.append({"path": str(f.path), "error": probe.error or "illisible"})
            continue
        if st is not None and st.track_id in ctx.cloud.tracks:
            _handle_known(ctx, f, st, probe, to_render)
            continue
        moved = _match_moved(probe.fingerprint, vanished_by_fp)
        if moved is not None:
            vanished.remove(moved)
            _handle_moved(ctx, f, moved, probe)
            continue
        restored = _match_deleted(probe.fingerprint, deleted_by_fp)
        if restored is not None:
            _handle_restored(ctx, f, restored, probe, to_render)
            continue
        track_id = st.track_id if st is not None else str(uuid.uuid4())
        to_render.append((f, track_id, probe))

    # 4-5. render and upload
    encoder = audio.pick_encoder(s.encoder)
    jobs = [
        (str(f.path), f.format, tid, str(work), s.aac_bitrate, s.loudness_lufs, encoder)
        for f, tid, _ in to_render
    ]
    meta = {str(f.path): (f, tid, probe) for f, tid, probe in to_render}
    with ThreadPoolExecutor(max_workers=4) as uploads:
        for rendered in _parallel(ctx, "Conversion", render_file, jobs, stream=True):
            f, tid, probe = meta[rendered.path]
            if rendered.error:
                report.errors.append({"path": rendered.path, "error": rendered.error})
                shutil.rmtree(work / tid, ignore_errors=True)
                continue
            _upload_rendered(ctx, uploads, rendered)
            if tid not in ctx.cloud.tracks:
                ctx.pending_rows.append(_track_row(f, tid, probe, rendered, ctx.config))
                report.new += 1
            else:
                ctx.pending_patches.append(_audio_patch(f, tid, probe, rendered))
                report.updated += 1
            ctx.pending_state.append(
                _file_state(f, tid, probe, "cataloged", rendered.audio_size, bool(rendered.covers))
            )
            shutil.rmtree(work / tid, ignore_errors=True)
            if len(ctx.pending_rows) + len(ctx.pending_patches) >= FLUSH_EVERY:
                _flush(ctx)
    _flush(ctx)

    # 6. vanished files
    _mark_deleted(ctx, vanished, len(ctx.cloud.live_tracks()))
    _flush(ctx)
    _purge_old_blobs(ctx)
    return report


def _unavailable(folder: Path) -> bool:
    """A missing folder, or an empty one (unmounted drive leaving its mount point): never delete from it."""
    try:
        return not folder.is_dir() or next(folder.iterdir(), None) is None
    except OSError:
        return True


def _under_missing(path: str, missing: list[str]) -> bool:
    return any(path.startswith(str(Path(m).expanduser()) + os.sep) for m in missing)


def _parallel(
    ctx: ImportContext, label: str, fn: Callable[[Any], Any], jobs: list[Any], stream: bool = False
):
    total = len(jobs)
    if total == 0:
        return iter(()) if stream else []

    def gen():
        done = 0
        if ctx.workers <= 1:
            for job in jobs:
                done += 1
                result = fn(job)
                if ctx.progress:
                    ctx.progress(label, done, total)
                yield result
            return
        with ProcessPoolExecutor(max_workers=ctx.workers) as pool:
            for result in pool.map(fn, jobs, chunksize=1 if stream else 8):
                done += 1
                if ctx.progress:
                    ctx.progress(label, done, total)
                yield result

    return gen() if stream else list(gen())


def _match_moved(f: fp.Fingerprint | None, vanished_by_fp: dict[str, list[FileState]]) -> FileState | None:
    if f is None:
        return None
    for st in vanished_by_fp.get(f.digest, []):
        if st.duration is None or abs(st.duration - f.duration) <= 1.0:
            vanished_by_fp[f.digest].remove(st)
            return st
    return None


def _recently_deleted_by_fingerprint(cloud: CloudState) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = {}
    for t in cloud.tracks.values():
        if t.get("deleted_at") and t.get("fingerprint"):
            out.setdefault(t["fingerprint"], []).append(t)
    return out


def _match_deleted(
    f: fp.Fingerprint | None, deleted: dict[str, list[dict[str, Any]]]
) -> dict[str, Any] | None:
    if f is None:
        return None
    for t in deleted.get(f.digest, []):
        duration = (t.get("duration_ms") or 0) / 1000
        if abs(duration - f.duration) <= 1.0:
            deleted[f.digest].remove(t)
            return t
    return None


def _baseline_of(managed: ManagedTags) -> Baseline:
    return managed.baseline()


def _source_tags(managed: ManagedTags) -> dict[str, Any]:
    return {
        "genre": managed.genre,
        "grouping": managed.grouping,
        "comment": managed.comment,
        "rating": managed.rating,
        "rating_raw": managed.rating_raw,
        "issues": managed.issues,
    }


def _added_at(path: Path) -> str:
    st = path.stat()
    birth = getattr(st, "st_birthtime", None)
    return iso_from_timestamp(birth if birth else st.st_mtime)


def _info_fields(f: ScannedFile, probe: Probe) -> dict[str, Any]:
    info = probe.info or TrackInfo()
    return {
        "file_path": str(f.path),
        "file_format": f.format,
        "file_size": f.size,
        "file_mtime": f.mtime_iso,
        "fingerprint": probe.fingerprint.digest if probe.fingerprint else None,
        "title": info.title or f.path.stem,
        "artist": info.artist,
        "album": info.album,
        "bpm": info.bpm,
        "musical_key": info.musical_key,
        "duration_ms": info.duration_ms,
    }


def _track_row(
    f: ScannedFile, track_id: str, probe: Probe, rendered: Rendered, config: TagConfig
) -> dict[str, Any]:
    assert probe.managed is not None
    baseline = _baseline_of(probe.managed)
    return {
        "id": track_id,
        **_info_fields(f, probe),
        "added_at": _added_at(f.path),
        "start_ms": rendered.start_ms,
        "waveform": rendered.waveform,
        "audio_key": f"audio/{track_id}.m4a",
        "audio_size": rendered.audio_size,
        "cover_key": f"covers/{track_id}" if rendered.covers else None,
        "source_tags": _source_tags(probe.managed),
        "baseline": baseline.to_json(),
        "comment_status": parse_comment(baseline.comment, config).status,
        "apply_status": "aucun",
        "apply_message": None,
        "applied_at": None,
        "deleted_at": None,
    }


def _audio_patch(f: ScannedFile, track_id: str, probe: Probe, rendered: Rendered) -> dict[str, Any]:
    return {
        "id": track_id,
        **_info_fields(f, probe),
        "start_ms": rendered.start_ms,
        "waveform": rendered.waveform,
        "audio_key": f"audio/{track_id}.m4a",
        "audio_size": rendered.audio_size,
        "cover_key": f"covers/{track_id}" if rendered.covers else None,
        "deleted_at": None,
    }


def _file_state(
    f: ScannedFile, track_id: str, probe: Probe, stage: str, audio_size: int | None, has_cover: bool
) -> FileState:
    return FileState(
        path=str(f.path),
        track_id=track_id,
        size=f.size,
        mtime=f.mtime,
        fingerprint=probe.fingerprint.digest if probe.fingerprint else None,
        duration=probe.fingerprint.duration if probe.fingerprint else None,
        stage=stage,
        audio_size=audio_size,
        has_cover=has_cover,
        error=None,
    )


def _upload_rendered(ctx: ImportContext, pool: ThreadPoolExecutor, r: Rendered) -> None:
    assert r.audio_path is not None
    futures = [pool.submit(ctx.api.put_blob, f"audio/{r.track_id}.m4a", Path(r.audio_path), "audio/mp4")]
    for size, path in (r.covers or {}).items():
        futures.append(
            pool.submit(ctx.api.put_blob, f"covers/{r.track_id}_{size}.jpg", Path(path), "image/jpeg")
        )
    for fut in futures:
        fut.result()
    ctx.report.uploaded_bytes += (r.audio_size or 0) + sum(
        Path(p).stat().st_size for p in (r.covers or {}).values()
    )


def _handle_known(
    ctx: ImportContext,
    f: ScannedFile,
    st: FileState,
    probe: Probe,
    to_render: list[tuple[ScannedFile, str, Probe]],
) -> None:
    """A file already in the catalogue changed on disk (tags edited in Serato, re-encoded…)."""
    track = ctx.cloud.tracks[st.track_id]
    audio_changed = (
        probe.fingerprint is None
        or st.fingerprint != probe.fingerprint.digest
        or not track.get("audio_key")
        or st.stage != "cataloged"
    )
    patch = _baseline_patch(ctx, track, f, probe)
    if audio_changed:
        ctx.pending_patches.append(patch)
        to_render.append((f, st.track_id, probe))
        return
    ctx.pending_patches.append({**patch, **_info_fields(f, probe), "deleted_at": None})
    ctx.pending_state.append(_file_state(f, st.track_id, probe, "cataloged", st.audio_size, st.has_cover))
    ctx.report.updated += 1


def _baseline_patch(
    ctx: ImportContext, track: dict[str, Any], f: ScannedFile, probe: Probe
) -> dict[str, Any]:
    """Apply the import rule for tags changed outside the app (spec section 11, "À l'import")."""
    assert probe.managed is not None
    config = ctx.config
    old = Baseline.from_json(track.get("baseline"))
    new = _baseline_of(probe.managed)
    rows = ctx.cloud.rows_for(track["id"])
    targets = compute_targets(track.get("file_format") or f.format, old, rows, config)
    patch: dict[str, Any] = {"id": track["id"], "source_tags": _source_tags(probe.managed)}
    conflicts: list[str] = []
    reverted: list[str] = []
    for tag in ROLE_TAG.values():
        if tags_equal(old.get(tag), new.get(tag)):
            continue
        if tags_equal(targets.get(tag), new.get(tag)):
            continue  # the file already holds the app's value (an apply that could not report back)
        if tags_equal(targets.get(tag), old.get(tag)):
            reverted.append(tag)
        else:
            conflicts.append(tag)
    if conflicts:
        message = "Modifié hors de l'app depuis l'import : " + ", ".join(conflicts)
        patch.update({"apply_status": "conflit", "apply_message": message})
        ctx.report.conflicts.append({"path": str(f.path), "tags": ", ".join(conflicts)})
        return patch
    patch["baseline"] = new.to_json()
    patch["comment_status"] = parse_comment(new.comment, config).status
    for tag in reverted:
        for field_ in config.fields:
            if field_.target_tag == tag and field_.id in rows:
                ctx.pending_reverts.append(_revert_change(track["id"], field_.id, rows[field_.id]))
    return patch


def _revert_change(track_id: str, field_id: str, old_value: Any) -> dict[str, Any]:
    return {
        "id": str(uuid.uuid4()),
        "track_id": track_id,
        "field_id": field_id,
        "old_value": old_value.to_json(),
        "new_value": None,
        "source": "file",
        "created_at": now_iso(),
    }


def _handle_moved(ctx: ImportContext, f: ScannedFile, old: FileState, probe: Probe) -> None:
    track = ctx.cloud.tracks.get(old.track_id)
    ctx.state.move(old.path, str(f.path))
    if track is None:
        return
    patch = _baseline_patch(ctx, track, f, probe)
    patch.update(_info_fields(f, probe))
    patch["deleted_at"] = None
    ctx.pending_patches.append(patch)
    ctx.pending_state.append(_file_state(f, old.track_id, probe, "cataloged", old.audio_size, old.has_cover))
    ctx.report.moved += 1


def _handle_restored(
    ctx: ImportContext,
    f: ScannedFile,
    track: dict[str, Any],
    probe: Probe,
    to_render: list[tuple[ScannedFile, str, Probe]],
) -> None:
    patch = _baseline_patch(ctx, track, f, probe)
    patch.update(_info_fields(f, probe))
    patch["deleted_at"] = None
    ctx.pending_patches.append(patch)
    ctx.report.restored += 1
    if not track.get("audio_key"):
        to_render.append((f, track["id"], probe))
    else:
        ctx.pending_state.append(
            _file_state(
                f, track["id"], probe, "cataloged", track.get("audio_size"), bool(track.get("cover_key"))
            )
        )


def _flush(ctx: ImportContext) -> None:
    if ctx.pending_rows:
        ctx.api.upsert_tracks(ctx.pending_rows)
        for row in ctx.pending_rows:
            ctx.cloud.tracks[row["id"]] = row
        ctx.pending_rows = []
    if ctx.pending_patches:
        ctx.api.patch_tracks(_merge_patches(ctx.pending_patches))
        for p in ctx.pending_patches:
            ctx.cloud.tracks.setdefault(p["id"], {}).update(p)
        ctx.pending_patches = []
    if ctx.pending_reverts:
        ctx.api.push(ctx.pending_reverts)
        ctx.pending_reverts = []
    for st in ctx.pending_state:
        ctx.state.upsert(st)
    ctx.pending_state = []


def _merge_patches(patches: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged: dict[str, dict[str, Any]] = {}
    for p in patches:
        merged.setdefault(p["id"], {}).update(p)
    return list(merged.values())


def _mark_deleted(ctx: ImportContext, vanished: list[FileState], live_count: int) -> None:
    if not vanished:
        return
    to_delete = [
        st
        for st in vanished
        if st.track_id in ctx.cloud.tracks and not ctx.cloud.tracks[st.track_id].get("deleted_at")
    ]
    everything = live_count > 0 and len(to_delete) >= live_count
    if (everything or len(to_delete) > max(20, live_count // 5)) and not ctx.allow_mass_delete:
        raise ImportRefused(
            f"{len(to_delete)} fichiers ont disparu : refus de les marquer supprimés sans --allow-mass-delete"
        )
    now = now_iso()
    for st in to_delete:
        ctx.pending_patches.append({"id": st.track_id, "deleted_at": now})
        ctx.state.delete(st.path)
        ctx.report.deleted += 1


def _purge_old_blobs(ctx: ImportContext) -> None:
    """Delete the listening copies of tracks deleted more than 30 days ago (their rows stay)."""
    limit = datetime.now(UTC) - DELETED_BLOB_RETENTION
    patches = []
    for t in ctx.cloud.tracks.values():
        deleted_at = t.get("deleted_at")
        if not deleted_at or not t.get("audio_key"):
            continue
        when = datetime.fromisoformat(deleted_at.replace("Z", "+00:00"))
        if when > limit:
            continue
        ctx.api.delete_blob(t["audio_key"])
        if t.get("cover_key"):
            for size in cover.SIZES:
                ctx.api.delete_blob(f"{t['cover_key']}_{size}.jpg")
        patches.append({"id": t["id"], "audio_key": None, "cover_key": None})
    if patches:
        ctx.api.patch_tracks(patches)
