"""FLAC managed tags with a raw metadata-block rewriter.

Unmanaged metadata blocks and Vorbis comment entries are kept byte for byte and in
order; the audio frames are never moved when the new metadata fits in the padding.
"""

from __future__ import annotations

import hashlib
import struct
from collections.abc import Mapping
from dataclasses import dataclass, field

from . import id3raw

STREAMINFO, PADDING, VORBIS_COMMENT = 0, 1, 4
NEW_PADDING = 4096


class FlacError(Exception):
    pass


@dataclass(frozen=True)
class Block:
    type: int
    data: bytes


@dataclass
class FlacFile:
    prefix: bytes  # bytes before "fLaC" (an ID3v2 tag some tools add)
    blocks: list[Block]
    audio_offset: int

    def vorbis(self) -> Block | None:
        found = [b for b in self.blocks if b.type == VORBIS_COMMENT]
        if len(found) > 1:
            raise FlacError("plusieurs blocs VORBIS_COMMENT")
        return found[0] if found else None


def parse(data: bytes) -> FlacFile:
    start = 0
    tag = id3raw.parse_tag(data) if data[:3] == b"ID3" else None
    if tag is not None:
        start = tag.total_size
    if data[start : start + 4] != b"fLaC":
        raise FlacError("signature fLaC absente")
    pos = start + 4
    blocks: list[Block] = []
    while True:
        if pos + 4 > len(data):
            raise FlacError("métadonnées tronquées")
        header = data[pos]
        last = bool(header & 0x80)
        btype = header & 0x7F
        length = int.from_bytes(data[pos + 1 : pos + 4], "big")
        if pos + 4 + length > len(data):
            raise FlacError("bloc de métadonnées tronqué")
        blocks.append(Block(btype, data[pos + 4 : pos + 4 + length]))
        pos += 4 + length
        if last:
            break
    return FlacFile(data[:start], blocks, pos)


@dataclass(frozen=True)
class Comment:
    key: str
    value: str
    raw: bytes  # "KEY=value" as stored (UTF-8)


@dataclass
class VorbisComments:
    vendor: bytes
    comments: list[Comment]

    @classmethod
    def parse(cls, data: bytes) -> VorbisComments:
        pos = 0
        (vlen,) = struct.unpack_from("<I", data, pos)
        vendor = data[4 : 4 + vlen]
        pos = 4 + vlen
        (count,) = struct.unpack_from("<I", data, pos)
        pos += 4
        comments: list[Comment] = []
        for _ in range(count):
            (clen,) = struct.unpack_from("<I", data, pos)
            raw = data[pos + 4 : pos + 4 + clen]
            if len(raw) != clen:
                raise FlacError("commentaire Vorbis tronqué")
            text = raw.decode("utf-8", "replace")
            key, _, value = text.partition("=")
            comments.append(Comment(key, value, raw))
            pos += 4 + clen
        return cls(vendor, comments)

    def render(self) -> bytes:
        out = [struct.pack("<I", len(self.vendor)), self.vendor, struct.pack("<I", len(self.comments))]
        for c in self.comments:
            out.append(struct.pack("<I", len(c.raw)))
            out.append(c.raw)
        return b"".join(out)

    def first(self, key: str) -> tuple[str | None, int]:
        values = [c.value for c in self.comments if c.key.upper() == key.upper()]
        return (values[0] if values else None), len(values)


@dataclass
class FlacManaged:
    genre: str | None = None
    grouping: str | None = None
    comment: str | None = None
    rating_raw: int | None = None
    keys: list[str] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class FlacKeys:
    genre: str = "GENRE"
    grouping: str = "GROUPING"
    comment: str = "COMMENT"
    rating: str = "RATING"

    def for_role(self, role: str) -> str:
        return getattr(self, role)


def read_managed(data: bytes, keys: FlacKeys) -> FlacManaged:
    from ..model.rating import parse_int

    out = FlacManaged()
    flac = parse(data)
    block = flac.vorbis()
    if block is None:
        return out
    vc = VorbisComments.parse(block.data)
    out.keys = sorted({c.key.upper() for c in vc.comments})
    for role in ("genre", "grouping", "comment"):
        value, count = vc.first(keys.for_role(role))
        if count > 1:
            out.issues.append(f"plusieurs valeurs pour {keys.for_role(role)}")
        setattr(out, role, value)
    rating, _ = vc.first(keys.rating)
    out.rating_raw = parse_int(rating)
    return out


def rewrite(data: bytes, changes: Mapping[str, str | int | None], keys: FlacKeys) -> bytes:
    """Return the file with only the managed Vorbis comments changed."""
    flac = parse(data)
    block = flac.vorbis()
    vc = VorbisComments.parse(block.data) if block else VorbisComments(b"djtag", [])
    wanted = {keys.for_role(role).upper(): (keys.for_role(role), value) for role, value in changes.items()}
    comments: list[Comment] = []
    written: set[str] = set()
    for c in vc.comments:
        upper = c.key.upper()
        if upper not in wanted:
            comments.append(c)
            continue
        if upper in written:
            continue  # extra values of a managed key collapse into one
        written.add(upper)
        _key, value = wanted[upper]
        if value is not None:
            comments.append(_comment(c.key, str(value)))
    for upper, (key, value) in wanted.items():
        if upper not in written and value is not None:
            comments.append(_comment(key, str(value)))
    new_vc = VorbisComments(vc.vendor, comments).render()

    others = [b for b in flac.blocks if b.type not in (VORBIS_COMMENT, PADDING)]
    insert_at = next((i for i, b in enumerate(flac.blocks) if b.type == VORBIS_COMMENT), None)
    new_blocks: list[Block] = []
    if insert_at is None:
        new_blocks = [*others[:1], Block(VORBIS_COMMENT, new_vc), *others[1:]]
    else:
        for b in flac.blocks:
            if b.type == VORBIS_COMMENT:
                new_blocks.append(Block(VORBIS_COMMENT, new_vc))
            elif b.type != PADDING:
                new_blocks.append(b)

    old_meta = flac.audio_offset - len(flac.prefix) - 4
    used = sum(4 + len(b.data) for b in new_blocks)
    room = old_meta - used
    if room >= 4:
        padding = room - 4  # same metadata size: audio offset unchanged
    elif room == 0:
        padding = -1  # exact fit, no padding block
    else:
        padding = NEW_PADDING
    if padding >= 0:
        new_blocks.append(Block(PADDING, b"\x00" * padding))
    out = [flac.prefix, b"fLaC"]
    for i, b in enumerate(new_blocks):
        last = 0x80 if i == len(new_blocks) - 1 else 0
        if len(b.data) >= 1 << 24:
            raise FlacError("bloc de métadonnées trop grand")
        out.append(bytes([last | b.type]) + len(b.data).to_bytes(3, "big") + b.data)
    out.append(data[flac.audio_offset :])
    return b"".join(out)


def _comment(key: str, value: str) -> Comment:
    return Comment(key, value, f"{key}={value}".encode())


def digest(data: bytes, keys: FlacKeys, managed_roles: tuple[str, ...]) -> list[tuple[str, str]]:
    """Hashes of everything djtag must leave untouched."""
    flac = parse(data)
    managed = {keys.for_role(r).upper() for r in managed_roles}
    out: list[tuple[str, str]] = [("flac.prefix", hashlib.sha256(flac.prefix).hexdigest())]
    for b in flac.blocks:
        if b.type == PADDING:
            continue
        if b.type == VORBIS_COMMENT:
            vc = VorbisComments.parse(b.data)
            out.append(("vorbis.vendor", hashlib.sha256(vc.vendor).hexdigest()))
            for c in vc.comments:
                if c.key.upper() not in managed:
                    out.append((f"vorbis.{c.key}", hashlib.sha256(c.raw).hexdigest()))
            continue
        out.append((f"block.{b.type}", hashlib.sha256(b.data).hexdigest()))
    out.append(("flac.audio", hashlib.sha256(data[flac.audio_offset :]).hexdigest()))
    return out
