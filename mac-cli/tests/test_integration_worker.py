"""Full workflow against a real Worker (`wrangler dev`). Skipped unless MYTAGS_IT_URL is set.

cd backend && npm run migrate:local && npx wrangler dev   # .dev.vars: ADMIN_TOKEN=...
MYTAGS_IT_URL=http://127.0.0.1:8787 MYTAGS_IT_TOKEN=... uv run pytest tests/test_integration_worker.py
"""

from __future__ import annotations

import os
import shutil
import uuid
from pathlib import Path

import httpx
import pytest

from djtag.api import Api
from djtag.apply import ApplyContext, RollbackContext, run_apply, run_rollback
from djtag.cloud import CloudState
from djtag.importer import ImportContext, run_import
from djtag.model.config import load_default_config_json
from djtag.plan import build_plan
from djtag.settings import Settings
from djtag.state import ImportState
from djtag.tags import preserved_digest, read_managed

from .fixtures import SERATO_EMAIL, make_base_audio, tagged

URL = os.environ.get("MYTAGS_IT_URL")
TOKEN = os.environ.get("MYTAGS_IT_TOKEN", "")
pytestmark = pytest.mark.skipif(not URL, reason="MYTAGS_IT_URL not set")


def test_full_cycle_against_worker(tmp_path, monkeypatch):
    monkeypatch.setenv("DJTAG_HOME", str(tmp_path / "home"))
    monkeypatch.setenv("DJTAG_SERATO_RUNNING", "0")
    assert URL
    api = Api(URL, TOKEN)
    if not [f for f in api.pull_all(("fields",))["fields"] if not f.get("deleted_at")]:
        api.reset_config(load_default_config_json())
    music = tmp_path / "music"
    music.mkdir()
    originals = {}
    for i, fmt in enumerate(["mp3", "flac", "m4a"]):
        base = make_base_audio(
            tmp_path / f"b{i}",
            frequency=200 + 37 * i + (uuid.uuid4().int % 300),
            duration=6,
            noise_seed=uuid.uuid4().int % 10_000,
        )
        p = tagged(fmt, base, music, name=f"it{i}")
        originals[p.name] = p.read_bytes()
    settings = Settings(music_folders=[music], popm_email=SERATO_EMAIL, api_url=URL)
    state = ImportState(tmp_path / "state.sqlite")
    report = run_import(ImportContext(settings, api, CloudState.load(api), state, workers=1))
    assert report.new == 3 and not report.errors, report

    cloud = CloudState.load(api)
    mine = [t for t in cloud.live_tracks() if Path(t["file_path"]).parent == music]
    assert len(mine) == 3
    mp3 = next(t for t in mine if t["file_format"] == "mp3")

    # The phone's view: a device token can read the catalogue and stream the audio.
    device = api.create_device("it-phone")
    phone = httpx.Client(base_url=URL, headers={"Authorization": f"Bearer {device['token']}"})
    audio = phone.get(f"/v1/blobs/{mp3['audio_key']}", headers={"Range": "bytes=0-99"})
    assert audio.status_code == 206 and len(audio.content) == 100
    assert phone.post("/v1/admin/tracks", json={"tracks": []}).status_code == 403

    genre = cloud.config.field_by_key["genre"]
    shatta = next(o for o in cloud.config.options(genre.id) if o.value == "SHATTA")
    note = cloud.config.field_by_key["note"]
    pushed = phone.post(
        "/v1/sync/push",
        json={
            "changes": [
                {
                    "id": str(uuid.uuid4()),
                    "track_id": mp3["id"],
                    "field_id": genre.id,
                    "old_value": None,
                    "new_value": {"option_ids": [shatta.id]},
                    "source": "user",
                    "created_at": "2026-10-08T10:00:00.000Z",
                },
                {
                    "id": str(uuid.uuid4()),
                    "track_id": mp3["id"],
                    "field_id": note.id,
                    "old_value": None,
                    "new_value": {"option_ids": [], "rating": 4},
                    "source": "user",
                    "created_at": "2026-10-08T10:00:01.000Z",
                },
            ]
        },
    )
    assert pushed.status_code == 200, pushed.text

    cloud = CloudState.load(api)
    plan = build_plan(cloud, settings, track_ids=[mp3["id"]])
    assert {c.tag: c.new for c in plan.items[0].changes} == {"genre": "SHATTA", "rating": 4}
    path = Path(mp3["file_path"])
    digest = preserved_digest(path, "mp3", settings.tag_options)
    run = run_apply(ApplyContext(settings, api, cloud, state, plan))
    assert run.count("written") == 1, run.outcomes
    tags = read_managed(path, "mp3", settings.tag_options)
    assert (tags.genre, tags.rating) == ("SHATTA", 4)
    assert preserved_digest(path, "mp3", settings.tag_options) == digest
    cloud = CloudState.load(api)
    assert cloud.tracks[mp3["id"]]["apply_status"] == "applique"
    assert build_plan(cloud, settings, track_ids=[mp3["id"]]).items == []

    back = run_rollback(RollbackContext(settings, api, state, run.run_id))
    assert back.count("written") == 1
    assert path.read_bytes() == originals[path.name]
    api.revoke_device(device["device_id"])
    state.close()
    shutil.rmtree(music)
