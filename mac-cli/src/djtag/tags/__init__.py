"""Read, write and fingerprint the managed tags of every supported format.

Roles: 'genre' (GENRE), 'grouping' (GROUPING), 'comment' (COMMENT), 'rating' (stars 1-5).
"""

from __future__ import annotations

import hashlib
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path

from ..model.rating import popm_from_stars, stars_from_generic, stars_from_popm
from ..model.values_types import Baseline
from . import containers, flac, id3raw, mp4

FORMAT_BY_EXTENSION = {
    ".mp3": "mp3",
    ".m4a": "m4a",
    ".mp4": "m4a",
    ".wav": "wav",
    ".aif": "aiff",
    ".aiff": "aiff",
    ".flac": "flac",
}
ROLES = ("genre", "grouping", "comment", "rating")


class TagWriteError(Exception):
    """The file cannot be written safely; nothing was changed."""


def detect_format(path: str | Path) -> str | None:
    return FORMAT_BY_EXTENSION.get(Path(path).suffix.lower())


@dataclass(frozen=True)
class TagOptions:
    popm_email: str | None = None
    comm_language: str = "eng"
    wav_id3_chunk: str = "id3 "
    mp4_rating_key: str = "----:com.apple.iTunes:RATE"
    generic_rating_scale: int = 100  # how M4A / FLAC ratings are written: 5, 100 or 255
    flac_keys: flac.FlacKeys = field(default_factory=flac.FlacKeys)

    @property
    def id3_write(self) -> id3raw.WriteOptions:
        return id3raw.WriteOptions(self.popm_email, self.comm_language.encode("latin-1")[:3].ljust(3, b" "))


@dataclass
class ManagedTags:
    genre: str | None = None
    grouping: str | None = None
    comment: str | None = None
    rating: int | None = None  # stars
    rating_raw: int | None = None
    issues: list[str] = field(default_factory=list)
    details: dict[str, object] = field(default_factory=dict)  # format specifics for the audit
    rating_block: str | None = None  # why the rating cannot be written in this file

    def baseline(self) -> Baseline:
        return Baseline(self.genre, self.grouping, self.comment, self.rating)


def read_managed(path: str | Path, fmt: str, opts: TagOptions) -> ManagedTags:
    path = str(path)
    if fmt in containers.ID3_FORMATS:
        data = Path(path).read_bytes()
        loc = containers.locate(data, fmt)
        managed = id3raw.read_managed(loc.tag, opts.popm_email)
        return ManagedTags(
            genre=managed.genre,
            grouping=managed.grouping,
            comment=managed.comment,
            rating=stars_from_popm(managed.rating_raw),
            rating_raw=managed.rating_raw,
            issues=managed.issues,
            details={
                "id3_version": f"2.{loc.tag.major}" if loc.tag else None,
                "frames": [f.id for f in loc.tag.frames] if loc.tag else [],
                "geob": _geob_descriptions(loc.tag),
                "popm_emails": managed.popm_emails,
                "rating_email": managed.rating_email,
                "comm": _comm_summary(loc.tag),
                "has_id3v1": data[-128:-125] == b"TAG",
            },
            rating_block=id3raw.rating_blocked(loc.tag, opts.popm_email),
        )
    if fmt == "m4a":
        m = mp4.read_managed(path, opts.mp4_rating_key)
        return ManagedTags(
            m.genre,
            m.grouping,
            m.comment,
            stars_from_generic(m.rating_raw),
            m.rating_raw,
            m.issues,
            {"freeform_keys": m.freeform_keys},
        )
    if fmt == "flac":
        f = flac.read_managed(Path(path).read_bytes(), opts.flac_keys)
        return ManagedTags(
            f.genre,
            f.grouping,
            f.comment,
            stars_from_generic(f.rating_raw),
            f.rating_raw,
            f.issues,
            {"vorbis_keys": f.keys},
        )
    raise TagWriteError(f"format non pris en charge : {fmt}")


def _geob_descriptions(tag: id3raw.ID3Tag | None) -> list[str]:
    out: list[str] = []
    for frame in tag.frames if tag else []:
        if frame.id != "GEOB" or not frame.data:
            continue
        enc = frame.data[0]
        rest = frame.data[1:]
        # GEOB: encoding, MIME (latin-1, NUL), filename (encoded, NUL), description (encoded, NUL), data
        mime_end = rest.find(b"\x00")
        if mime_end == -1:
            continue
        rest = rest[mime_end + 1 :]
        try:
            _filename, rest = id3raw._split_terminated(rest, enc)
            desc, _ = id3raw._split_terminated(rest, enc)
            out.append(id3raw._decode(desc, enc))
        except id3raw.ID3Error:
            continue
    return out


def _comm_summary(tag: id3raw.ID3Tag | None) -> list[str]:
    out: list[str] = []
    for frame in tag.frames if tag else []:
        if frame.id == "COMM":
            try:
                c = id3raw.decode_comm(frame.data)
                out.append(f"{c.language.decode('latin-1', 'replace')}:{c.description}")
            except id3raw.ID3Error:
                out.append("illisible")
    return out


# -- writing --------------------------------------------------------------------------------------


def _raw_rating(fmt: str, stars: int, opts: TagOptions) -> int:
    if fmt in containers.ID3_FORMATS:
        return popm_from_stars(stars)
    if opts.generic_rating_scale == 5:
        return stars
    if opts.generic_rating_scale == 255:
        return popm_from_stars(stars)
    return stars * 20


def _raw_changes(
    fmt: str, changes: Mapping[str, str | int | None], opts: TagOptions
) -> dict[str, str | int | None]:
    out: dict[str, str | int | None] = {}
    for role, value in changes.items():
        if role not in ROLES:
            raise TagWriteError(f"rôle inconnu : {role}")
        if role == "rating" and value is not None:
            out[role] = _raw_rating(fmt, int(value), opts)
        else:
            out[role] = value
    return out


def write_managed(
    path: str | Path, fmt: str, changes: Mapping[str, str | int | None], opts: TagOptions
) -> None:
    """Write `changes` into `path` in place. Call this on a temporary copy, then verify it."""
    raw = _raw_changes(fmt, changes, opts)
    try:
        if fmt in containers.ID3_FORMATS:
            data = Path(path).read_bytes()
            loc = containers.locate(data, fmt)
            major, frames = id3raw.splice_frames(loc.tag, raw, opts.id3_write)
            tag_bytes = containers.new_tag_bytes(loc, major, frames)
            new = containers.replace_tag(data, loc, tag_bytes, opts.wav_id3_chunk.encode("latin-1"))
            _overwrite(path, new)
        elif fmt == "flac":
            data = Path(path).read_bytes()
            _overwrite(path, flac.rewrite(data, raw, opts.flac_keys))
        elif fmt == "m4a":
            mp4.write_managed(str(path), raw, opts.mp4_rating_key)
        else:
            raise TagWriteError(f"format non pris en charge : {fmt}")
    except (id3raw.ID3Error, containers.ContainerError, flac.FlacError) as exc:
        raise TagWriteError(str(exc)) from exc


def _overwrite(path: str | Path, data: bytes) -> None:
    import os

    with open(path, "r+b") as fh:
        fh.write(data)
        fh.truncate()
        fh.flush()
        os.fsync(fh.fileno())


# -- digest of untouched data ---------------------------------------------------------------------


def preserved_digest(path: str | Path, fmt: str, opts: TagOptions) -> list[tuple[str, str]]:
    """Ordered hashes of everything djtag must never change (non-managed tags and audio)."""
    data = Path(path).read_bytes()
    if fmt in containers.ID3_FORMATS:
        loc = containers.locate(data, fmt)
        out: list[tuple[str, str]] = []
        if loc.tag is not None:
            out.append(("id3.header", f"{loc.tag.major}.{loc.tag.revision}.{loc.tag.flags}"))
            for frame in loc.tag.frames:
                if id3raw.frame_role(frame, opts.popm_email) is None:
                    out.append((f"id3.{frame.id}", hashlib.sha256(frame.raw).hexdigest()))
        out.extend(containers.audio_digest(data, loc))
        return out
    if fmt == "flac":
        return flac.digest(data, opts.flac_keys, ROLES)
    if fmt == "m4a":
        import io

        managed = {mp4.GENRE_KEY, mp4.GENRE_ID_KEY, mp4.GROUPING_KEY, mp4.COMMENT_KEY, opts.mp4_rating_key}
        fileobj = io.BytesIO(data)
        atoms, _path, items = mp4.read_ilst(fileobj)
        out = [(f"ilst.{i.key}", hashlib.sha256(i.raw).hexdigest()) for i in items if i.key not in managed]
        out.extend(mp4.structure_digest(fileobj, atoms))
        return out
    raise TagWriteError(f"format non pris en charge : {fmt}")
