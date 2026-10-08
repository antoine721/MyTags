"""End to end on synthetic files: import → tag (as the phone would) → diff → apply → rollback."""

from __future__ import annotations

import shutil
import uuid
from pathlib import Path

import pytest
from mutagen.id3 import ID3, TCON

from djtag.apply import ApplyContext, ApplyRefused, RollbackContext, run_apply, run_rollback, run_trial
from djtag.cloud import CloudState
from djtag.importer import ImportContext, ImportRefused, run_import
from djtag.model.config import load_default_config_json
from djtag.plan import build_plan
from djtag.resolve import resolve
from djtag.settings import Settings
from djtag.state import ImportState
from djtag.tags import preserved_digest, read_managed

from .fake_api import FakeWorker, make_api
from .fixtures import SERATO_EMAIL, make_base_audio, tagged

FORMATS = ["mp3", "m4a", "flac", "wav", "aiff"]


@pytest.fixture
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("DJTAG_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("DJTAG_SERATO_RUNNING", "0")
    music = tmp_path / "music"
    (music / "Shatta").mkdir(parents=True)
    originals = tmp_path / "originals"
    originals.mkdir()
    for i, fmt in enumerate(FORMATS):
        base = make_base_audio(tmp_path / f"base{i}", frequency=300 + 70 * i, duration=6, noise_seed=i + 1)
        path = tagged(fmt, base, music / "Shatta", name=f"track{i}")
        shutil.copy2(path, originals / path.name)
    worker = FakeWorker()
    api = make_api(worker)
    api.reset_config(load_default_config_json())
    settings = Settings(music_folders=[music], popm_email=SERATO_EMAIL, api_url="https://fake.local")
    state = ImportState(tmp_path / "home" / "state.sqlite")
    yield {
        "music": music,
        "originals": originals,
        "worker": worker,
        "api": api,
        "settings": settings,
        "state": state,
    }
    state.close()


def do_import(env, **kw):
    cloud = CloudState.load(env["api"])
    return run_import(ImportContext(env["settings"], env["api"], cloud, env["state"], workers=1, **kw))


def track_by_name(env, name):
    cloud = CloudState.load(env["api"])
    return next(t for t in cloud.tracks.values() if Path(t["file_path"]).name == name), cloud


def option(cloud, field_key, value):
    f = cloud.config.field_by_key[field_key]
    return f.id, next(o.id for o in cloud.config.options(f.id) if o.value == value)


def phone_change(cloud, track_id, field_key, value=None, rating=None):
    if field_key == "note":
        fid = cloud.config.field_by_key["note"].id
        new = {"option_ids": [], "rating": rating, "text": None}
    else:
        fid, oid = option(cloud, field_key, value)
        new = {"option_ids": [oid], "rating": None, "text": None}
    return {
        "id": str(uuid.uuid4()),
        "track_id": track_id,
        "field_id": fid,
        "old_value": None,
        "new_value": new,
        "source": "user",
        "created_at": "2026-10-08T12:00:00.000Z",
    }


def test_import_then_nothing_to_do(env):
    report = do_import(env)
    assert report.new == len(FORMATS) and not report.errors
    worker = env["worker"]
    assert len([k for k in worker.blobs if k.startswith("audio/")]) == len(FORMATS)
    track, cloud = track_by_name(env, "track0.mp3")
    assert track["baseline"] == {
        "genre": "Rap Fr",
        "grouping": "VERT",
        "comment": "fr extend sexy",
        "rating": 3,
    }
    assert track["comment_status"] == "conforme"
    assert len(track["waveform"]) == 800 and isinstance(track["start_ms"], int)
    assert track["title"] == "Test Title (Extended Mix)" and track["cover_key"]
    puts_before = sum(1 for m, _ in worker.requests if m == "PUT")
    again = do_import(env)
    assert again.unchanged == len(FORMATS) and again.new == 0
    assert sum(1 for m, _ in worker.requests if m == "PUT") == puts_before


def test_apply_then_rollback(env):
    do_import(env)
    track, cloud = track_by_name(env, "track0.mp3")
    env["api"].push(
        [
            phone_change(cloud, track["id"], "genre", "SHATTA"),
            phone_change(cloud, track["id"], "couleur", "ROUGE"),
            phone_change(cloud, track["id"], "pays", "FR"),
            phone_change(cloud, track["id"], "note", rating=5),
        ]
    )
    cloud = CloudState.load(env["api"])
    plan = build_plan(cloud, env["settings"])
    assert [i.track_id for i in plan.items] == [track["id"]]
    assert {c.tag: c.new for c in plan.items[0].changes} == {
        "genre": "SHATTA",
        "grouping": "ROUGE",
        "comment": "FR EXTEND SEXY",
        "rating": 5,
    }

    path = Path(track["file_path"])
    digest_before = preserved_digest(path, "mp3", env["settings"].tag_options)
    run = run_apply(ApplyContext(env["settings"], env["api"], cloud, env["state"], plan))
    assert run.count("written") == 1, run.outcomes
    tags = read_managed(path, "mp3", env["settings"].tag_options)
    assert (tags.genre, tags.grouping, tags.comment, tags.rating) == ("SHATTA", "ROUGE", "FR EXTEND SEXY", 5)
    assert preserved_digest(path, "mp3", env["settings"].tag_options) == digest_before
    assert not list(path.parent.glob(".*djtag-tmp*"))

    cloud = CloudState.load(env["api"])
    assert cloud.tracks[track["id"]]["apply_status"] == "applique"
    assert {c["status"] for c in cloud.changes if c["track_id"] == track["id"]} == {"applied"}
    assert build_plan(cloud, env["settings"]).items == []  # apply again → nothing to write

    again = do_import(env)
    assert again.unchanged == len(FORMATS)  # the import state follows the files written by apply

    back = run_rollback(RollbackContext(env["settings"], env["api"], env["state"], run.run_id))
    assert back.count("written") == 1
    assert path.read_bytes() == (env["originals"] / "track0.mp3").read_bytes()
    cloud = CloudState.load(env["api"])
    assert cloud.tracks[track["id"]]["baseline"]["genre"] == "Rap Fr"
    assert {c["status"] for c in cloud.changes if c["track_id"] == track["id"]} == {"sent"}
    assert len(build_plan(cloud, env["settings"]).items) == 1


@pytest.mark.parametrize("fmt", FORMATS)
def test_apply_every_format_keeps_serato_data(env, fmt):
    do_import(env)
    i = FORMATS.index(fmt)
    track, cloud = track_by_name(env, f"track{i}.{fmt}")
    env["api"].push(
        [
            phone_change(cloud, track["id"], "genre", "BOUYON"),
            phone_change(cloud, track["id"], "type", "REMIX"),
        ]
    )
    cloud = CloudState.load(env["api"])
    path = Path(track["file_path"])
    before = preserved_digest(path, fmt, env["settings"].tag_options)
    run = run_apply(
        ApplyContext(env["settings"], env["api"], cloud, env["state"], build_plan(cloud, env["settings"]))
    )
    assert run.count("written") == 1, run.outcomes
    assert preserved_digest(path, fmt, env["settings"].tag_options) == before
    tags = read_managed(path, fmt, env["settings"].tag_options)
    assert (tags.genre, tags.comment) == ("BOUYON", "FR REMIX SEXY")


def test_trial_writes_verified_copies_and_changes_nothing_else(env, tmp_path):
    do_import(env)
    cloud = CloudState.load(env["api"])
    changes = []
    for i, fmt in enumerate(FORMATS):
        track, _ = track_by_name(env, f"track{i}.{fmt}")
        changes += [
            phone_change(cloud, track["id"], "genre", "BOUYON"),
            phone_change(cloud, track["id"], "type", "REMIX"),
        ]
    env["api"].push(changes)
    cloud = CloudState.load(env["api"])
    plan = build_plan(cloud, env["settings"])
    assert len(plan.items) == len(FORMATS)
    library = {p: p.read_bytes() for p in env["music"].rglob("*") if p.is_file()}
    dest = tmp_path / "essai"
    run = run_trial(ApplyContext(env["settings"], env["api"], cloud, env["state"], plan), dest)
    assert run.count("written") == len(FORMATS), run.outcomes
    assert {p: p.read_bytes() for p in env["music"].rglob("*") if p.is_file()} == library
    for i, fmt in enumerate(FORMATS):
        copy = dest / f"track{i}.{fmt}"
        original = env["music"] / "Shatta" / copy.name
        opts = env["settings"].tag_options
        assert preserved_digest(copy, fmt, opts) == preserved_digest(original, fmt, opts)
        tags = read_managed(copy, fmt, opts)
        assert (tags.genre, tags.comment) == ("BOUYON", "FR REMIX SEXY")
    after = CloudState.load(env["api"])
    assert {t["id"]: t["apply_status"] for t in after.tracks.values()} == {
        t["id"]: t["apply_status"] for t in cloud.tracks.values()
    }
    assert len(build_plan(after, env["settings"]).items) == len(FORMATS)  # still to apply for real
    again = run_trial(ApplyContext(env["settings"], env["api"], after, env["state"], plan), dest)
    assert (dest / "track0 (2).mp3").exists() and again.count("written") == len(FORMATS)


def test_trial_refuses_a_folder_inside_the_library(env):
    do_import(env)
    track, cloud = track_by_name(env, "track0.mp3")
    env["api"].push([phone_change(cloud, track["id"], "genre", "POP")])
    cloud = CloudState.load(env["api"])
    plan = build_plan(cloud, env["settings"])
    with pytest.raises(ApplyRefused):
        run_trial(
            ApplyContext(env["settings"], env["api"], cloud, env["state"], plan), env["music"] / "essai"
        )
    assert not (env["music"] / "essai").exists()


def test_refuses_when_serato_is_open(env, monkeypatch):
    do_import(env)
    track, cloud = track_by_name(env, "track0.mp3")
    env["api"].push([phone_change(cloud, track["id"], "genre", "POP")])
    cloud = CloudState.load(env["api"])
    monkeypatch.setenv("DJTAG_SERATO_RUNNING", "1")
    original = Path(track["file_path"]).read_bytes()
    with pytest.raises(ApplyRefused):
        run_apply(
            ApplyContext(env["settings"], env["api"], cloud, env["state"], build_plan(cloud, env["settings"]))
        )
    assert Path(track["file_path"]).read_bytes() == original


def test_conflict_when_file_changed_outside_app(env):
    do_import(env)
    track, cloud = track_by_name(env, "track0.mp3")
    env["api"].push([phone_change(cloud, track["id"], "genre", "POP")])
    path = Path(track["file_path"])
    tags = ID3(path)
    tags.setall("TCON", [TCON(encoding=0, text="Edited In Serato")])
    tags.save(path, v2_version=3)
    cloud = CloudState.load(env["api"])
    run = run_apply(
        ApplyContext(env["settings"], env["api"], cloud, env["state"], build_plan(cloud, env["settings"]))
    )
    assert run.count("conflict") == 1 and run.count("written") == 0
    cloud = CloudState.load(env["api"])
    assert cloud.tracks[track["id"]]["apply_status"] == "conflit"
    assert build_plan(cloud, env["settings"]).items == []

    resolve(env["settings"], env["api"], cloud, [track["id"]], "app")
    cloud = CloudState.load(env["api"])
    plan = build_plan(cloud, env["settings"])
    assert [c.new for c in plan.items[0].changes] == ["POP"]
    run = run_apply(ApplyContext(env["settings"], env["api"], cloud, env["state"], plan))
    assert run.count("written") == 1
    assert read_managed(path, "mp3", env["settings"].tag_options).genre == "POP"


def test_import_takes_file_value_when_nothing_pending(env):
    do_import(env)
    track, cloud = track_by_name(env, "track0.mp3")
    path = Path(track["file_path"])
    tags = ID3(path)
    tags.setall("TCON", [TCON(encoding=0, text="SHATTA")])
    tags.save(path, v2_version=3)
    report = do_import(env)
    assert report.updated == 1 and not report.conflicts
    cloud = CloudState.load(env["api"])
    assert cloud.tracks[track["id"]]["baseline"]["genre"] == "SHATTA"


def test_import_conflict_when_change_pending(env):
    do_import(env)
    track, cloud = track_by_name(env, "track0.mp3")
    env["api"].push([phone_change(cloud, track["id"], "genre", "POP")])
    path = Path(track["file_path"])
    tags = ID3(path)
    tags.setall("TCON", [TCON(encoding=0, text="SHATTA")])
    tags.save(path, v2_version=3)
    report = do_import(env)
    assert report.conflicts and report.conflicts[0]["tags"] == "GENRE"


def test_moved_file_keeps_its_id(env):
    do_import(env)
    track, _ = track_by_name(env, "track0.mp3")
    old = Path(track["file_path"])
    new = old.parent.parent / "renamed.mp3"
    old.rename(new)
    report = do_import(env)
    assert report.moved == 1 and report.new == 0 and report.deleted == 0
    cloud = CloudState.load(env["api"])
    assert cloud.tracks[track["id"]]["file_path"] == str(new)


def test_deleted_file_is_soft_deleted(env):
    do_import(env)
    track, _ = track_by_name(env, "track1.m4a")
    Path(track["file_path"]).unlink()
    report = do_import(env)
    assert report.deleted == 1
    cloud = CloudState.load(env["api"])
    assert cloud.tracks[track["id"]]["deleted_at"]


def test_missing_music_folder_never_deletes(env, tmp_path):
    do_import(env)
    moved = tmp_path / "unplugged"
    env["music"].rename(moved)
    report = do_import(env)
    assert report.deleted == 0 and report.skipped_missing_folders


def test_mass_delete_needs_confirmation(env, tmp_path):
    do_import(env)
    for p in list(env["music"].rglob("track*")):
        p.unlink()
    (env["music"] / "keep.txt").write_text("folder still mounted")
    with pytest.raises(ImportRefused):
        do_import(env)
    report = do_import(env, allow_mass_delete=True)
    assert report.deleted == len(FORMATS)
