"""Where the ID3v2 tag lives in MP3, WAV (RIFF) and AIFF (FORM) files, and how to replace it."""

from __future__ import annotations

import hashlib
import struct
from dataclasses import dataclass

from . import id3raw

ID3_FORMATS = ("mp3", "wav", "aiff")
NEW_TAG_PADDING = 1024


class ContainerError(Exception):
    pass


@dataclass(frozen=True)
class IFFChunk:
    id: bytes
    offset: int  # start of the 8-byte chunk header
    size: int  # declared data size
    big_endian: bool

    @property
    def data_offset(self) -> int:
        return self.offset + 8

    @property
    def end(self) -> int:
        """End including the pad byte for odd sizes."""
        return self.data_offset + self.size + (self.size & 1)

    @property
    def is_id3(self) -> bool:
        return self.id.lower() == b"id3 "


@dataclass(frozen=True)
class IFFFile:
    big_endian: bool
    form_type: bytes
    declared_size: int
    chunks: list[IFFChunk]


def parse_iff(data: bytes, fmt: str) -> IFFFile:
    if fmt == "wav":
        if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
            raise ContainerError(
                "not a RIFF/WAVE file" + (" (ID3 en tête de WAV)" if data[:3] == b"ID3" else "")
            )
        big = False
    elif fmt == "aiff":
        if data[:4] != b"FORM" or data[8:12] not in (b"AIFF", b"AIFC"):
            raise ContainerError("not a FORM/AIFF file")
        big = True
    else:
        raise ContainerError(f"{fmt} is not an IFF format")
    declared = struct.unpack(">I" if big else "<I", data[4:8])[0]
    limit = min(len(data), 8 + declared)
    chunks: list[IFFChunk] = []
    pos = 12
    while pos + 8 <= limit:
        cid = data[pos : pos + 4]
        size = struct.unpack(">I" if big else "<I", data[pos + 4 : pos + 8])[0]
        chunk = IFFChunk(cid, pos, size, big)
        if chunk.data_offset + size > len(data):
            raise ContainerError(f"chunk {cid!r} runs past the end of the file")
        chunks.append(chunk)
        pos = chunk.end
    return IFFFile(big, data[8:12], declared, chunks)


@dataclass(frozen=True)
class ID3Location:
    fmt: str
    start: int  # offset of the tag (or of the chunk data holding it)
    end: int  # end of the tag bytes
    tag: id3raw.ID3Tag | None
    chunk: IFFChunk | None = None
    iff: IFFFile | None = None


def locate(data: bytes, fmt: str) -> ID3Location:
    if fmt == "mp3":
        tag = id3raw.parse_tag(data)
        return ID3Location(fmt, 0, tag.total_size if tag else 0, tag)
    iff = parse_iff(data, fmt)
    id3_chunks = [c for c in iff.chunks if c.is_id3]
    if len(id3_chunks) > 1:
        raise ContainerError("plusieurs chunks ID3")
    if not id3_chunks:
        return ID3Location(fmt, 0, 0, None, None, iff)
    chunk = id3_chunks[0]
    chunk_data = data[chunk.data_offset : chunk.data_offset + chunk.size]
    tag = id3raw.parse_tag(chunk_data)
    end = chunk.data_offset + (tag.total_size if tag else 0)
    return ID3Location(fmt, chunk.data_offset, end, tag, chunk, iff)


def new_tag_bytes(loc: ID3Location, major: int, frames: bytes) -> bytes:
    """Serialise the tag, reusing the existing size (padding) when the frames fit."""
    tag = loc.tag
    if tag is not None and len(frames) <= tag.size:
        return id3raw.build_tag(tag.major, tag.revision, tag.flags, frames, tag.size)
    revision = tag.revision if tag else 0
    flags = tag.flags if tag else 0
    return id3raw.build_tag(major, revision, flags, frames, len(frames) + NEW_TAG_PADDING)


def replace_tag(data: bytes, loc: ID3Location, tag_bytes: bytes, wav_chunk_id: bytes = b"id3 ") -> bytes:
    """Return the whole file with the ID3 tag replaced (or added)."""
    if loc.fmt == "mp3":
        return tag_bytes + data[loc.end :]
    assert loc.iff is not None
    iff = loc.iff
    pack = ">I" if iff.big_endian else "<I"
    if loc.chunk is not None:
        chunk = loc.chunk
        trailing = data[loc.end : chunk.data_offset + chunk.size]
        new_data = tag_bytes + trailing
        if len(new_data) == chunk.size:
            return data[: chunk.data_offset] + new_data + data[chunk.data_offset + chunk.size :]
        new_chunk = (
            chunk.id + struct.pack(pack, len(new_data)) + new_data + (b"\x00" if len(new_data) & 1 else b"")
        )
        body = data[: chunk.offset] + new_chunk + data[chunk.end :]
    else:
        cid = wav_chunk_id if loc.fmt == "wav" else b"ID3 "
        insert_at = min(len(data), 8 + iff.declared_size + (iff.declared_size & 1))
        new_chunk = (
            cid + struct.pack(pack, len(tag_bytes)) + tag_bytes + (b"\x00" if len(tag_bytes) & 1 else b"")
        )
        if insert_at & 1:
            # The last chunk is odd-sized and its pad byte is missing: add it, chunks start on even offsets.
            new_chunk = b"\x00" + new_chunk
        body = data[:insert_at] + new_chunk + data[insert_at:]
        # The new chunk is the last one: the container now ends right after it.
        form_size = insert_at + len(new_chunk) - 8
        return body[:4] + struct.pack(pack, form_size) + body[8:]
    # The container grows or shrinks by exactly the bytes we changed inside it.
    form_size = iff.declared_size + (len(body) - len(data))
    return body[:4] + struct.pack(pack, form_size) + body[8:]


def audio_digest(data: bytes, loc: ID3Location) -> list[tuple[str, str]]:
    """Hashes of everything outside the ID3 tag, used to prove the audio is untouched."""
    if loc.fmt == "mp3":
        return [("mp3.after_tag", hashlib.sha256(data[loc.end :]).hexdigest())]
    assert loc.iff is not None
    out = [("iff.form_type", loc.iff.form_type.hex())]
    for chunk in loc.iff.chunks:
        if chunk.is_id3:
            continue
        raw = data[chunk.offset : chunk.data_offset + chunk.size]
        out.append((f"chunk.{chunk.id.decode('latin-1')}", hashlib.sha256(raw).hexdigest()))
    return out
