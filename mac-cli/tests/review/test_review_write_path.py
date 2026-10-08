"""Adversarial review of the write path (apply / rollback).

Every test here asserts the SAFE / CORRECT behaviour and FAILS on the current code:
each failure demonstrates a defect. Synthetic files only.
"""

from __future__ import annotations

import errno
import io
import os
import shutil
import struct
import subprocess
import uuid
from pathlib import Path

import pytest
from mutagen.id3 import COMM, ID3
from mutagen.mp4._atom import Atoms

import djtag.apply as apply_mod
from djtag import fingerprint as fp
from djtag.apply import (
    ApplyContext,
    RollbackContext,
    VerifyError,
    run_apply,
    run_rollback,
    verify_copy,
)
from djtag.cloud import CloudState
from djtag.importer import ImportContext, run_import
from djtag.model.config import load_default_config_json
from djtag.model.values_types import Baseline
from djtag.plan import build_plan
from djtag.settings import Settings
from djtag.state import ImportState
from djtag.tags import TagOptions, read_managed, write_managed
from djtag.tags.id3raw import encode_syncsafe

from ..fake_api import FakeWorker, make_api
from ..fixtures import SERATO_EMAIL, make_base_audio, tagged

# -- helpers -----------------------------------------------------------------------------------------


@pytest.fixture
def lib(tmp_path, monkeypatch):
    monkeypatch.setenv("DJTAG_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("DJTAG_SERATO_RUNNING", "0")
    music = tmp_path / "music" / "Shatta"
    music.mkdir(parents=True)
    worker = FakeWorker()
    api = make_api(worker)
    api.reset_config(load_default_config_json())
    settings = Settings(music_folders=[music.parent], popm_email=SERATO_EMAIL, api_url="https://fake.local")
    state = ImportState(tmp_path / "home" / "state.sqlite")
    env = {"tmp": tmp_path, "music": music, "api": api, "settings": settings, "state": state, "seed": 0}
    yield env
    state.close()


def base_audio(env, fmt: str) -> Path:
    env["seed"] += 1
    return make_base_audio(env["tmp"] / f"base{env['seed']}", 300 + 70 * env["seed"], 6, env["seed"])[fmt]


def do_import(env):
    cloud = CloudState.load(env["api"])
    return run_import(ImportContext(env["settings"], env["api"], cloud, env["state"], workers=1))


def track_named(env, name):
    cloud = CloudState.load(env["api"])
    return next(t for t in cloud.tracks.values() if Path(t["file_path"]).name == name), cloud


def set_genre(env, name, value="SHATTA"):
    track, cloud = track_named(env, name)
    f = cloud.config.field_by_key["genre"]
    oid = next(o.id for o in cloud.config.options(f.id) if o.value == value)
    env["api"].push(
        [
            {
                "id": str(uuid.uuid4()),
                "track_id": track["id"],
                "field_id": f.id,
                "old_value": None,
                "new_value": {"option_ids": [oid], "rating": None, "text": None},
                "source": "user",
                "created_at": "2026-10-08T12:00:00.000Z",
            }
        ]
    )
    return track


def set_comment_type(env, name, value="REMIX"):
    track, cloud = track_named(env, name)
    f = cloud.config.field_by_key["type"]
    oid = next(o.id for o in cloud.config.options(f.id) if o.value == value)
    env["api"].push(
        [
            {
                "id": str(uuid.uuid4()),
                "track_id": track["id"],
                "field_id": f.id,
                "old_value": None,
                "new_value": {"option_ids": [oid], "rating": None, "text": None},
                "source": "user",
                "created_at": "2026-10-08T12:00:00.000Z",
            }
        ]
    )
    return track


def apply_all(env, progress=None):
    cloud = CloudState.load(env["api"])
    plan = build_plan(cloud, env["settings"])
    return run_apply(ApplyContext(env["settings"], env["api"], cloud, env["state"], plan, progress=progress))


def frame_plain(fid: bytes, payload: bytes) -> bytes:
    """ID3v2.4 frame with a plain 32-bit size (old iTunes bug) instead of a syncsafe one."""
    return fid + struct.pack(">I", len(payload)) + b"\x00\x00" + payload


# -- A. ID3 parser treats the rest of a mis-sized v2.4 tag as padding; verify cannot see it ----------


def test_A_id3v24_plain_int_frame_sizes_must_not_lose_frames(lib):
    n = 16  # Serato Markers_-like payload: lots of 0x00 / 0x7F bytes
    markers = b"\x02\x05" + struct.pack(">I", n) + (b"\x00\x00\x00\x10\x00" + b"\x7f" * 4 + b"\x00" * 10 + b"\x01\x00") * n
    frames = (
        frame_plain(b"TCON", b"\x00Rap Fr")
        + frame_plain(b"COMM", b"\x00eng\x00fr extend sexy")
        + frame_plain(b"GEOB", b"\x00application/octet-stream\x00\x00Serato Markers_\x00" + markers)
        + frame_plain(b"GEOB", b"\x00application/octet-stream\x00\x00Serato BeatGrid\x00\x01\x00" + bytes(range(1, 60)))
        + frame_plain(b"TIT2", b"\x00Title")
    )
    tag = b"ID3\x04\x00\x00" + encode_syncsafe(len(frames) + 512) + frames + b"\x00" * 512
    path = lib["music"] / "itunes.mp3"
    path.write_bytes(tag + base_audio(lib, "mp3").read_bytes())
    geob_before = sorted((g.desc, g.data) for g in ID3(path).getall("GEOB"))
    do_import(lib)
    set_genre(lib, "itunes.mp3")
    run = apply_all(lib)
    status = run.outcomes[0].status
    geob_after = sorted((g.desc, g.data) for g in ID3(path).getall("GEOB"))
    # Either refuse the file, or keep every GEOB byte-identical. Today: "written" and GEOB data destroyed.
    assert status != "written" or geob_after == geob_before, (status, [(d, len(x)) for d, x in geob_after])


# -- B. M4A verification ignores everything outside ilst items and top-level mdat ---------------------


def test_B_mp4_verify_must_detect_broken_chunk_offsets(lib):
    src = tagged("m4a", {"m4a": base_audio(lib, "m4a")}, lib["tmp"], name="src")
    opts = TagOptions()
    before = read_managed(src, "m4a", opts).baseline()
    temp = lib["tmp"] / "temp.m4a"
    shutil.copy2(src, temp)
    write_managed(temp, "m4a", {"genre": "SHATTA"}, opts)
    data = bytearray(temp.read_bytes())
    stco = Atoms(io.BytesIO(bytes(data))).path(b"moov", b"trak", b"mdia", b"minf", b"stbl", b"stco")[-1]
    count = struct.unpack(">I", data[stco.offset + 12 : stco.offset + 16])[0]
    for i in range(count):  # simulate a structural write bug: every chunk offset shifted
        at = stco.offset + 16 + 4 * i
        data[at : at + 4] = struct.pack(">I", struct.unpack(">I", data[at : at + 4])[0] + 4096)
    temp.write_bytes(bytes(data))
    with pytest.raises(VerifyError):
        verify_copy(src, temp, "m4a", opts, Baseline("SHATTA", before.grouping, before.comment, before.rating))


# -- C. A failure in the middle of a run loses the cloud bookkeeping of files already written ---------


def test_C1_interrupt_mid_run_keeps_cloud_in_sync(lib, monkeypatch):
    for i in range(2):
        tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name=f"t{i}")
    do_import(lib)
    t0 = set_genre(lib, "t0.mp3")
    set_genre(lib, "t1.mp3")
    real, calls = fp.compute, []

    def compute(path, timeout=120):  # user presses Ctrl-C while fpcalc runs on the 2nd file
        calls.append(path)
        if len(calls) == 2:
            raise KeyboardInterrupt
        return real(path, timeout)

    monkeypatch.setattr(fp, "compute", compute)
    with pytest.raises(KeyboardInterrupt):
        apply_all(lib)
    assert read_managed(lib["music"] / "t0.mp3", "mp3", lib["settings"].tag_options).genre == "SHATTA"
    monkeypatch.setattr(fp, "compute", real)
    rerun = apply_all(lib)
    by_id = {o.track_id: o for o in rerun.outcomes}
    # t0 was written by djtag itself; re-running must not flag it as a Conflict.
    assert by_id[t0["id"]].status != "conflict", by_id[t0["id"]].message


def test_C2_wav_with_odd_last_chunk_must_not_abort_the_run(lib):
    tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name="a")
    wav = base_audio(lib, "wav").read_bytes()
    info = b"INFO" + b"ISFT" + struct.pack("<I", 5) + b"Lavf\x00"  # odd LIST chunk, pad byte missing
    body = wav[12:] + b"LIST" + struct.pack("<I", len(info)) + info
    (lib["music"] / "b.wav").write_bytes(b"RIFF" + struct.pack("<I", 4 + len(body)) + b"WAVE" + body)
    do_import(lib)
    a = set_genre(lib, "a.mp3")
    set_genre(lib, "b.wav")
    run = apply_all(lib)  # today: ContainerError escapes run_apply (verify_copy on a misaligned chunk)
    assert {o.track_id: o.status for o in run.outcomes}[a["id"]] == "written"


def test_C3_rollback_must_restore_file_replaced_before_manifest_update(lib, monkeypatch):
    path = tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name="t")
    original = path.read_bytes()
    do_import(lib)
    set_genre(lib, "t.mp3")
    real, seen = apply_mod.read_managed, []

    def read(p, fmt, opts):  # crash right after os.replace (final read-back), e.g. Ctrl-C / power loss
        if Path(p) == path:
            seen.append(p)
            if len(seen) == 2:
                raise KeyboardInterrupt
        return real(p, fmt, opts)

    monkeypatch.setattr(apply_mod, "read_managed", read)
    with pytest.raises(KeyboardInterrupt):
        apply_all(lib)
    monkeypatch.setattr(apply_mod, "read_managed", real)
    assert path.read_bytes() != original  # the library file WAS modified
    run_id = next(p.name for p in lib["settings"].backups_dir.iterdir() if (p / "manifest.json").exists())
    back = run_rollback(RollbackContext(lib["settings"], lib["api"], lib["state"], run_id))
    assert path.read_bytes() == original, f"rollback restored {back.count('written')} files"


# -- D. Serato is only checked once, before a run that can last an hour --------------------------------


def test_D_serato_opened_during_run_stops_writing(lib):
    for i in range(2):
        tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name=f"t{i}")
    do_import(lib)
    set_genre(lib, "t0.mp3")
    set_genre(lib, "t1.mp3")

    def progress(done, total):
        if done == 1:
            os.environ["DJTAG_SERATO_RUNNING"] = "1"  # the DJ launches Serato after the first file

    run = apply_all(lib, progress)
    assert [o.status for o in run.outcomes].count("written") <= 1, [o.status for o in run.outcomes]


# -- E. A symlinked track is replaced by a regular file ----------------------------------------------


def test_E_symlinked_track_stays_a_symlink(lib):
    outside = lib["tmp"] / "elsewhere"
    outside.mkdir()
    target = tagged("mp3", {"mp3": base_audio(lib, "mp3")}, outside, name="real")
    link = lib["music"] / "link.mp3"
    link.symlink_to(target)
    do_import(lib)
    set_genre(lib, "link.mp3")
    run = apply_all(lib)
    assert run.outcomes[0].status == "written"
    assert link.is_symlink(), "library symlink was replaced by a regular file (target left unchanged)"


# -- F. Rollback re-creates files (and folders) that are no longer there -----------------------------


def test_F_rollback_does_not_recreate_moved_files(lib):
    path = tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name="t")
    do_import(lib)
    set_genre(lib, "t.mp3")
    run = apply_all(lib)
    assert run.count("written") == 1
    moved = lib["music"].parent / "Renamed"
    lib["music"].rename(moved)  # the DJ renamed the folder after applying
    run_rollback(RollbackContext(lib["settings"], lib["api"], lib["state"], run.run_id))
    assert not lib["music"].exists(), "rollback re-created the old folder and a duplicate track in the library"
    assert (moved / "t.mp3").exists() and not path.exists()


# -- G. A second COMM with an empty description keeps the stale comment -------------------------------


def test_G_duplicate_empty_description_comm_is_not_left_stale(lib):
    path = tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name="t")
    tags = ID3(path)
    tags.add(COMM(encoding=0, lang="XXX", desc="", text="fr extend sexy"))  # e.g. written by another tagger
    tags.save(path, v2_version=3)
    do_import(lib)
    set_comment_type(lib, "t.mp3")
    run = apply_all(lib)
    assert run.count("written") == 1, run.outcomes
    texts = sorted(c.text[0] for c in ID3(path).getall("COMM") if c.desc == "")
    assert texts == ["FR REMIX SEXY"], texts


# -- H. Temp file leaked into the library when a restore copy fails ----------------------------------


def test_H_failed_restore_leaves_no_temp_file_in_library(lib, monkeypatch):
    path = tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name="t")
    do_import(lib)
    set_genre(lib, "t.mp3")
    run = apply_all(lib)
    assert run.count("written") == 1
    real = apply_mod.clone_or_copy

    def copy(src, dest):  # external drive full while copying the backup back
        if ".djtag-tmp" in dest.name:
            dest.write_bytes(Path(src).read_bytes()[:1000])
            raise OSError(errno.ENOSPC, "No space left on device")
        return real(src, dest)

    monkeypatch.setattr(apply_mod, "clone_or_copy", copy)
    with pytest.raises(OSError):
        run_rollback(RollbackContext(lib["settings"], lib["api"], lib["state"], run.run_id))
    leaked = [p.name for p in path.parent.iterdir() if ".djtag-tmp" in p.name]
    assert not leaked, leaked


# -- I. Clearing the rating deletes the whole POPM frame, play counter included -----------------------


def test_I_clearing_rating_keeps_popm_counter(lib):
    path = tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name="t")
    assert ID3(path).getall("POPM")[0].count == 3
    do_import(lib)
    track, cloud = track_named(lib, "t.mp3")
    fid = cloud.config.field_by_key["note"].id
    lib["api"].push(
        [
            {
                "id": str(uuid.uuid4()),
                "track_id": track["id"],
                "field_id": fid,
                "old_value": None,
                "new_value": {"option_ids": [], "rating": None, "text": None},  # "vidé volontairement"
                "source": "user",
                "created_at": "2026-10-08T12:00:00.000Z",
            }
        ]
    )
    run = apply_all(lib)
    assert run.count("written") == 1, run.outcomes
    popm = ID3(path).getall("POPM")
    assert popm and popm[0].count == 3, "POPM (and its unmanaged play counter) deleted"


def _ffprobe_ok(p: Path) -> bool:
    return subprocess.run(["ffprobe", "-v", "error", str(p)], capture_output=True).returncode == 0


# -- J. A POPM owned by other software blocks GENRE/COMMENT too (decision 0006 says skip the rating) --


def test_J_foreign_popm_only_skips_the_rating(lib):
    from mutagen.id3 import POPM

    path = tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name="t")
    tags = ID3(path)
    tags.delall("POPM")
    tags.add(POPM(email="Windows Media Player 9 Series", rating=196, count=0))
    tags.save(path, v2_version=3)
    do_import(lib)
    track = set_genre(lib, "t.mp3")
    _, cloud = track_named(lib, "t.mp3")
    fid = cloud.config.field_by_key["note"].id
    lib["api"].push(
        [
            {
                "id": str(uuid.uuid4()),
                "track_id": track["id"],
                "field_id": fid,
                "old_value": None,
                "new_value": {"option_ids": [], "rating": 5, "text": None},
                "source": "user",
                "created_at": "2026-10-08T12:00:00.000Z",
            }
        ]
    )
    run = apply_all(lib)
    assert read_managed(path, "mp3", lib["settings"].tag_options).genre == "SHATTA", run.outcomes[0].message


# -- C4. A file whose hidden temp name is too long aborts the whole run ---------------------------
# Linux: shutil.copy2 raises ENAMETOOLONG (caught), then `temp.exists()` in the finally re-raises it.
# macOS: any `cp` failure raises subprocess.CalledProcessError, which _apply_one never catches.


@pytest.mark.parametrize("system", ["Linux", "Darwin"])
def test_C4_temp_copy_failure_is_a_per_file_error_not_an_abort(lib, monkeypatch, system):
    import djtag.backup as backup_mod

    tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name="a")
    long_name = "b" * 236  # backup name (6 + 240) fits in NAME_MAX, the hidden temp name does not
    tagged("mp3", {"mp3": base_audio(lib, "mp3")}, lib["music"], name=long_name)
    do_import(lib)
    a = set_genre(lib, "a.mp3")
    set_genre(lib, long_name + ".mp3")
    monkeypatch.setattr(backup_mod.platform, "system", lambda: system)  # Darwin: GNU cp has no -c -> cp -p
    run = apply_all(lib)  # today: OSError / CalledProcessError escapes run_apply
    assert {o.track_id: o.status for o in run.outcomes}[a["id"]] == "written"
