"""Reading and byte-exact writing of managed tags in every format."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st
from mutagen import File as MutagenFile
from mutagen.id3 import ID3

from djtag.tags import (
    TagOptions,
    TagWriteError,
    containers,
    id3raw,
    preserved_digest,
    read_managed,
    write_managed,
)

from .fixtures import SERATO_EMAIL, SERATO_MARKERS2, tagged, tagged_mp3

FORMATS = ["mp3", "wav", "aiff", "m4a", "flac"]
OPTS = TagOptions(popm_email=SERATO_EMAIL)


def decodes(path: Path) -> bool:
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "null", "-"], capture_output=True, text=True
    )
    return result.returncode == 0 and result.stderr.strip() == ""


@pytest.mark.parametrize("fmt", FORMATS)
def test_read_managed(fmt, base_audio, tmp_path):
    path = tagged(fmt, base_audio, tmp_path)
    tags = read_managed(path, fmt, OPTS)
    assert tags.genre == "Rap Fr"
    assert tags.grouping == "VERT"
    assert tags.comment == "fr extend sexy"
    if fmt in ("mp3", "wav", "aiff"):
        assert tags.rating == 3 and tags.rating_raw == 128
        assert "Serato Markers2" in tags.details["geob"]
    assert tags.issues == []


@pytest.mark.parametrize("fmt", FORMATS)
def test_write_changes_only_managed_tags(fmt, base_audio, tmp_path):
    path = tagged(fmt, base_audio, tmp_path)
    before = preserved_digest(path, fmt, OPTS)
    changes = {"genre": "RAP FR", "grouping": "ROUGE", "comment": "FR EXTEND SEXY", "rating": 5}
    write_managed(path, fmt, changes, OPTS)
    after = read_managed(path, fmt, OPTS)
    assert (after.genre, after.grouping, after.comment) == ("RAP FR", "ROUGE", "FR EXTEND SEXY")
    assert after.rating == 5
    assert preserved_digest(path, fmt, OPTS) == before
    assert decodes(path)
    assert MutagenFile(path) is not None


@pytest.mark.parametrize("fmt", FORMATS)
def test_write_is_idempotent_and_minimal(fmt, base_audio, tmp_path):
    path = tagged(fmt, base_audio, tmp_path)
    write_managed(path, fmt, {"genre": "SHATTA"}, OPTS)
    first = path.read_bytes()
    write_managed(path, fmt, {"genre": "SHATTA"}, OPTS)
    assert path.read_bytes() == first
    tags = read_managed(path, fmt, OPTS)
    assert (tags.grouping, tags.comment) == ("VERT", "fr extend sexy")


@pytest.mark.parametrize("fmt", FORMATS)
def test_remove_value(fmt, base_audio, tmp_path):
    path = tagged(fmt, base_audio, tmp_path)
    before = preserved_digest(path, fmt, OPTS)
    write_managed(path, fmt, {"grouping": None}, OPTS)
    tags = read_managed(path, fmt, OPTS)
    assert tags.grouping is None and tags.genre == "Rap Fr"
    assert preserved_digest(path, fmt, OPTS) == before


@pytest.mark.parametrize("version", [3, 4])
def test_id3_version_and_v1_preserved(version, base_audio, tmp_path):
    path = tagged_mp3(base_audio["mp3"], tmp_path / "t.mp3", version=version, v1=True)
    v1 = path.read_bytes()[-128:]
    write_managed(path, "mp3", {"comment": "US REMIX ()", "genre": "BOUYON"}, OPTS)
    data = path.read_bytes()
    assert data[3] == version
    assert data[-128:] == v1
    frames = ID3(path)
    assert frames.version[1] == version
    serato = [f for f in frames.getall("GEOB") if f.desc == "Serato Markers2"]
    assert serato and serato[0].data == SERATO_MARKERS2


def test_fits_in_padding_keeps_file_size(base_audio, tmp_path):
    path = tagged_mp3(base_audio["mp3"], tmp_path / "t.mp3", padding=2048)
    size = path.stat().st_size
    write_managed(path, "mp3", {"genre": "ZOUKOMPA", "comment": "UK EDIT NICHE"}, OPTS)
    assert path.stat().st_size == size


def test_growth_beyond_padding(base_audio, tmp_path):
    path = tagged_mp3(base_audio["mp3"], tmp_path / "t.mp3", padding=0)
    before = preserved_digest(path, "mp3", OPTS)
    write_managed(path, "mp3", {"comment": "X" * 5000}, OPTS)
    assert read_managed(path, "mp3", OPTS).comment == "X" * 5000
    assert preserved_digest(path, "mp3", OPTS) == before
    assert decodes(path)


def test_new_tag_on_untagged_mp3(base_audio, tmp_path):
    path = tmp_path / "plain.mp3"
    shutil.copyfile(base_audio["mp3"], path)
    before = preserved_digest(path, "mp3", OPTS)
    write_managed(path, "mp3", {"genre": "POP", "rating": 4}, OPTS)
    tags = read_managed(path, "mp3", OPTS)
    assert tags.genre == "POP" and tags.rating == 4
    after = [d for d in preserved_digest(path, "mp3", OPTS) if d[0] != "id3.header"]
    assert after == before
    assert decodes(path)


def test_new_chunk_on_untagged_wav(base_audio, tmp_path):
    path = tmp_path / "plain.wav"
    shutil.copyfile(base_audio["wav"], path)
    before = preserved_digest(path, "wav", OPTS)
    write_managed(path, "wav", {"genre": "POP", "comment": "FR () ()"}, OPTS)
    tags = read_managed(path, "wav", OPTS)
    assert (tags.genre, tags.comment) == ("POP", "FR () ()")
    assert [d for d in preserved_digest(path, "wav", OPTS) if d[0] != "id3.header"] == before
    data = path.read_bytes()
    assert int.from_bytes(data[4:8], "little") == len(data) - 8
    assert decodes(path)


def test_unsynchronised_tag_is_refused(base_audio, tmp_path):
    path = tagged_mp3(base_audio["mp3"], tmp_path / "t.mp3")
    data = bytearray(path.read_bytes())
    data[5] |= 0x80  # mark the tag as unsynchronised
    path.write_bytes(bytes(data))
    with pytest.raises(TagWriteError):
        write_managed(path, "mp3", {"genre": "POP"}, OPTS)


def test_rating_requires_known_popm_owner(base_audio, tmp_path):
    path = tagged_mp3(base_audio["mp3"], tmp_path / "t.mp3")
    with pytest.raises(TagWriteError):
        write_managed(path, "mp3", {"rating": 4}, TagOptions(popm_email=None))


def test_never_adds_a_second_popm(base_audio, tmp_path):
    path = tagged_mp3(base_audio["mp3"], tmp_path / "t.mp3")
    other = TagOptions(popm_email="someone@else")
    tag = containers.locate(path.read_bytes(), "mp3").tag
    assert "autre logiciel" in (id3raw.rating_blocked(tag, "someone@else") or "")
    assert id3raw.rating_blocked(tag, SERATO_EMAIL) is None
    with pytest.raises(TagWriteError):
        write_managed(path, "mp3", {"rating": 2}, other)
    assert [(f.email, f.rating) for f in ID3(path).getall("POPM")] == [(SERATO_EMAIL, 128)]


def test_flac_without_padding_grows_safely(base_audio, tmp_path):
    path = tagged("flac", base_audio, tmp_path, padding=0)
    before = preserved_digest(path, "flac", OPTS)
    write_managed(path, "flac", {"comment": "UK REMIX AFRO" * 50}, OPTS)
    assert preserved_digest(path, "flac", OPTS) == before
    assert decodes(path)


def test_m4a_unmanaged_item_order_kept(base_audio, tmp_path):
    import io

    from djtag.tags import mp4

    path = tagged("m4a", base_audio, tmp_path)
    keys_before = [i.key for i in mp4.read_ilst(io.BytesIO(path.read_bytes()))[2]]
    write_managed(path, "m4a", {"genre": "POP", "comment": "US EDIT ()"}, OPTS)
    keys_after = [i.key for i in mp4.read_ilst(io.BytesIO(path.read_bytes()))[2]]
    assert [k for k in keys_after if k not in ("©gen", "©cmt")] == [
        k for k in keys_before if k not in ("©gen", "©cmt")
    ]
    assert decodes(path)


def test_id3_frame_level_roundtrip_keeps_raw_bytes(base_audio, tmp_path):
    path = tagged_mp3(base_audio["mp3"], tmp_path / "t.mp3")
    tag = containers.locate(path.read_bytes(), "mp3").tag
    assert tag is not None
    major, frames = id3raw.splice_frames(tag, {}, OPTS.id3_write)
    assert frames == b"".join(f.raw for f in tag.frames)


text = st.text(st.characters(blacklist_categories=("Cs", "Cc")), min_size=1, max_size=40).filter(
    lambda s: s.strip() == s and s
)


@settings(max_examples=40, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture])
@given(genre=text, comment=text, version=st.sampled_from([3, 4]))
def test_unicode_roundtrip(genre, comment, version, base_audio, tmp_path):
    path = tagged_mp3(base_audio["mp3"], tmp_path / f"h{version}.mp3", version=version)
    write_managed(path, "mp3", {"genre": genre, "comment": comment}, OPTS)
    tags = read_managed(path, "mp3", OPTS)
    assert tags.comment == comment
    assert tags.genre == id3raw.resolve_genre(genre)
