"""MP4 / M4A managed tags.

Reading uses mutagen. Writing keeps every unmanaged `ilst` item as the exact bytes
found in the file, in the original order, and lets mutagen only do the structural
work (parent atom sizes, chunk offsets, free padding).
"""

from __future__ import annotations

import hashlib
import io
from collections.abc import Mapping
from dataclasses import dataclass, field

from mutagen._constants import GENRES
from mutagen.mp4 import MP4, AtomDataType, MP4FreeForm, MP4Tags
from mutagen.mp4._atom import Atom, Atoms

from ..model.rating import parse_int

GENRE_KEY = "©gen"
GENRE_ID_KEY = "gnre"
GROUPING_KEY = "©grp"
COMMENT_KEY = "©cmt"


@dataclass
class MP4Managed:
    genre: str | None = None
    grouping: str | None = None
    comment: str | None = None
    rating_raw: int | None = None
    freeform_keys: list[str] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)


def _first_text(tags: Mapping[str, object], key: str, issues: list[str]) -> str | None:
    values = tags.get(key)
    if not values:
        return None
    if isinstance(values, list):
        if len(values) > 1:
            issues.append(f"plusieurs valeurs pour {key}")
        value = values[0]
    else:
        value = values
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)


def read_managed(path: str, rating_key: str) -> MP4Managed:
    out = MP4Managed()
    tags = MP4(path).tags
    if tags is None:
        return out
    out.genre = _first_text(tags, GENRE_KEY, out.issues)
    if out.genre is None and GENRE_ID_KEY in tags:
        ids = tags[GENRE_ID_KEY]
        if ids and 0 < int(ids[0]) <= len(GENRES):
            out.genre = GENRES[int(ids[0]) - 1]
    out.grouping = _first_text(tags, GROUPING_KEY, out.issues)
    out.comment = _first_text(tags, COMMENT_KEY, out.issues)
    raw = tags.get(rating_key)
    if raw:
        out.rating_raw = parse_int(bytes(raw[0]) if isinstance(raw[0], (bytes, MP4FreeForm)) else str(raw[0]))
    out.freeform_keys = sorted(k for k in tags if k.startswith("----:"))
    return out


# -- raw ilst access -----------------------------------------------------------------------------


@dataclass(frozen=True)
class IlstItem:
    key: str  # "©gen", or "----:mean:name" for freeform items
    raw: bytes


def _freeform_key(raw: bytes) -> str:
    """Build '----:mean:name' from the raw bytes of a '----' item."""
    pos = 8
    mean = name = ""
    while pos + 8 <= len(raw):
        size = int.from_bytes(raw[pos : pos + 4], "big")
        kind = raw[pos + 4 : pos + 8]
        if size < 8:
            break
        payload = raw[pos + 12 : pos + size]  # skip version/flags
        if kind == b"mean":
            mean = payload.decode("utf-8", "replace")
        elif kind == b"name":
            name = payload.decode("utf-8", "replace")
        pos += size
    return f"----:{mean}:{name}"


def read_ilst(fileobj: io.BufferedIOBase) -> tuple[Atoms, list[Atom] | None, list[IlstItem]]:
    fileobj.seek(0)
    atoms = Atoms(fileobj)
    try:
        path = atoms.path(b"moov", b"udta", b"meta", b"ilst")
    except KeyError:
        return atoms, None, []
    ilst = path[-1]
    items: list[IlstItem] = []
    for child in ilst.children or []:
        fileobj.seek(child.offset)
        raw = fileobj.read(child.length)
        name = child.name
        key = _freeform_key(raw) if name == b"----" else name.decode("latin-1")
        items.append(IlstItem(key, raw))
    return atoms, path, items


def mdat_digest(fileobj: io.BufferedIOBase, atoms: Atoms) -> str:
    digest = hashlib.sha256()
    for atom in atoms.atoms:
        if atom.name == b"mdat":
            fileobj.seek(atom.offset)
            remaining = atom.length
            while remaining > 0:
                chunk = fileobj.read(min(remaining, 1 << 20))
                if not chunk:
                    break
                digest.update(chunk)
                remaining -= len(chunk)
    return digest.hexdigest()


def write_managed(path: str, changes: Mapping[str, str | int | None], rating_key: str) -> None:
    """Rewrite only the managed items of `path` in place (call it on a temporary copy)."""
    keys = {"genre": GENRE_KEY, "grouping": GROUPING_KEY, "comment": COMMENT_KEY, "rating": rating_key}
    renderer = MP4Tags()
    with open(path, "r+b") as fileobj:
        atoms, _path, items = read_ilst(fileobj)
        replaced: dict[str, bytes | None] = {}
        for role, value in changes.items():
            key = keys[role]
            replaced[key] = None if value is None else _render(renderer, key, value)
        drop = {GENRE_ID_KEY} if "genre" in changes else set()
        out: list[bytes] = []
        done: set[str] = set()
        for item in items:
            if item.key in drop:
                continue
            if item.key in replaced:
                if item.key in done:
                    continue  # duplicates of a managed item collapse into one
                done.add(item.key)
                new = replaced[item.key]
                if new is not None:
                    out.append(new)
                continue
            out.append(item.raw)
        for key, new in replaced.items():
            if key not in done and new is not None:
                out.append(new)
        ilst = Atom.render(b"ilst", b"".join(out))
        fileobj.seek(0)
        atoms = Atoms(fileobj)
        renderer._MP4Tags__save(fileobj, atoms, ilst, None)  # type: ignore[attr-defined]


def _render(renderer: MP4Tags, key: str, value: str | int) -> bytes:
    if key.startswith("----:"):
        data = MP4FreeForm(str(value).encode("utf-8"), dataformat=AtomDataType.UTF8)
        return renderer._render(key, [data])  # type: ignore[attr-defined]
    return renderer._render(key, [str(value)])  # type: ignore[attr-defined]
