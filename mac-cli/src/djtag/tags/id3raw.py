"""Raw ID3v2 reading and frame-level splicing (decision 0006).

Unmanaged frames are kept as the exact bytes found in the file, in their original
order. Only TCON, TIT1, COMM (empty description) and POPM (owner from the config)
are ever re-serialised.
"""

from __future__ import annotations

import re
import struct
from collections.abc import Mapping
from dataclasses import dataclass, field

from mutagen._constants import GENRES

HEADER_SIZE = 10
_FRAME_ID = re.compile(rb"^[A-Z0-9]{4}$")
_FRAME_ID_22 = re.compile(rb"^[A-Z0-9]{3}$")
_GENRE_REF = re.compile(r"^\((\d+)\)(.*)$")

# Format flags (second flag byte) that change how a frame payload must be decoded.
# ID3v2.3: compression 0x80, encryption 0x40, grouping 0x20.
# ID3v2.4: grouping 0x40, compression 0x08, encryption 0x04, unsynchronisation 0x02,
# data length indicator 0x01.
_UNSUPPORTED_FORMAT_FLAGS = {3: 0x80 | 0x40 | 0x20, 4: 0x40 | 0x08 | 0x04 | 0x02 | 0x01}


class ID3Error(Exception):
    """Malformed tag or a tag feature djtag refuses to rewrite."""


@dataclass(frozen=True)
class RawFrame:
    id: str
    flags: bytes
    data: bytes
    raw: bytes


@dataclass
class ID3Tag:
    major: int
    revision: int
    flags: int
    size: int  # bytes after the 10-byte header (frames + padding), as declared
    frames: list[RawFrame]
    frames_length: int  # bytes used by frames; the rest of `size` is padding
    issues: list[str] = field(default_factory=list)  # reasons the tag must not be rewritten

    @property
    def total_size(self) -> int:
        footer = HEADER_SIZE if self.major == 4 and self.flags & 0x10 else 0
        return HEADER_SIZE + self.size + footer

    @property
    def writable(self) -> bool:
        return not self.issues


# -- integers -------------------------------------------------------------------------------------


def decode_syncsafe(data: bytes) -> int:
    value = 0
    for b in data:
        value = (value << 7) | (b & 0x7F)
    return value


def encode_syncsafe(value: int) -> bytes:
    if value >= 1 << 28:
        raise ID3Error("tag too large")
    return bytes(((value >> shift) & 0x7F) for shift in (21, 14, 7, 0))


def _remove_unsync(data: bytes) -> bytes:
    return data.replace(b"\xff\x00", b"\xff")


# -- parsing -------------------------------------------------------------------------------------


def parse_tag(data: bytes) -> ID3Tag | None:
    """Parse an ID3v2 tag at the start of `data`, or return None if there is none."""
    if len(data) < HEADER_SIZE or data[:3] != b"ID3":
        return None
    major, revision, flags = data[3], data[4], data[5]
    size = decode_syncsafe(data[6:10])
    if major not in (2, 3, 4):
        raise ID3Error(f"unsupported ID3v2.{major}")
    if HEADER_SIZE + size > len(data):
        raise ID3Error("tag size exceeds the file")
    body = data[HEADER_SIZE : HEADER_SIZE + size]
    issues: list[str] = []
    if major == 2:
        issues.append("ID3v2.2 (lecture seule)")
    if flags & 0x80:
        issues.append("désynchronisation globale")
        body = _remove_unsync(body)
    start = 0
    if flags & 0x40 and major in (3, 4):
        issues.append("en-tête étendu")
        if major == 3:
            start = 4 + struct.unpack(">I", body[:4])[0]
        else:
            start = decode_syncsafe(body[:4])
    if major == 4 and flags & 0x10:
        issues.append("pied de tag ID3v2.4")

    if major == 2:
        frames, end = _parse_frames_22(body, start)
    else:
        frames, end, ok = _parse_frames(body, start, major, syncsafe=(major == 4))
        if not ok and major == 4:
            # Some writers (old iTunes) stored plain integers in v2.4 frame sizes.
            alt_frames, alt_end, alt_ok = _parse_frames(body, start, major, syncsafe=False)
            if alt_ok:
                frames, end = alt_frames, alt_end
                issues.append("tailles de cadres v2.4 non conformes")
            else:
                issues.append("cadres illisibles")
        elif not ok:
            issues.append("cadres illisibles")
    for frame in frames:
        if major in _UNSUPPORTED_FORMAT_FLAGS and len(frame.flags) == 2:
            if frame.flags[1] & _UNSUPPORTED_FORMAT_FLAGS[major] and _is_managed_id(frame.id):
                issues.append(f"cadre {frame.id} compressé, chiffré ou groupé")
    return ID3Tag(major, revision, flags, size, frames, end, issues)


def _parse_frames(body: bytes, start: int, major: int, syncsafe: bool) -> tuple[list[RawFrame], int, bool]:
    frames: list[RawFrame] = []
    pos = start
    while pos + HEADER_SIZE <= len(body):
        fid = body[pos : pos + 4]
        if fid[0] == 0:
            return frames, pos, _only_padding(body, pos)
        if not _FRAME_ID.match(fid):
            return frames, pos, False
        raw_size = body[pos + 4 : pos + 8]
        size = decode_syncsafe(raw_size) if syncsafe else struct.unpack(">I", raw_size)[0]
        end = pos + HEADER_SIZE + size
        if end > len(body):
            return frames, pos, False
        frames.append(RawFrame(fid.decode("ascii"), body[pos + 8 : pos + 10], body[pos + 10 : end], body[pos:end]))
        pos = end
    return frames, pos, _only_padding(body, pos)


def _parse_frames_22(body: bytes, start: int) -> tuple[list[RawFrame], int]:
    frames: list[RawFrame] = []
    pos = start
    while pos + 6 <= len(body):
        fid = body[pos : pos + 3]
        if fid[0] == 0 or not _FRAME_ID_22.match(fid):
            break
        size = int.from_bytes(body[pos + 3 : pos + 6], "big")
        end = pos + 6 + size
        if end > len(body):
            break
        frames.append(RawFrame(fid.decode("ascii"), b"", body[pos + 6 : end], body[pos:end]))
        pos = end
    return frames, pos


def _only_padding(body: bytes, pos: int) -> bool:
    # Tolerate junk after the frames only if it starts with a zero byte (common padding).
    return pos >= len(body) or body[pos] == 0


# -- text decoding -------------------------------------------------------------------------------

_ENCODINGS = {0: "latin-1", 1: "utf-16", 2: "utf-16-be", 3: "utf-8"}


def _decode(payload: bytes, encoding: int) -> str:
    codec = _ENCODINGS.get(encoding)
    if codec is None:
        raise ID3Error(f"unknown text encoding {encoding}")
    return payload.decode(codec, errors="replace")


def _split_terminated(payload: bytes, encoding: int) -> tuple[bytes, bytes]:
    """Split at the first string terminator: (string, rest after terminator)."""
    if encoding in (1, 2):
        i = 0
        while i + 1 < len(payload):
            if payload[i] == 0 and payload[i + 1] == 0:
                return payload[:i], payload[i + 2 :]
            i += 2
        return payload, b""
    i = payload.find(b"\x00")
    return (payload, b"") if i == -1 else (payload[:i], payload[i + 1 :])


def decode_text_frame(data: bytes) -> str:
    if not data:
        return ""
    text = _decode(data[1:], data[0])
    values = [v for v in text.split("\x00") if v != ""]
    return "/".join(values)


def resolve_genre(text: str) -> str:
    """Translate ID3v1 numeric genre references like "(17)" or "17" into names."""
    match = _GENRE_REF.match(text)
    if match:
        rest = match.group(2)
        if rest:
            return rest
        index = int(match.group(1))
        return GENRES[index] if index < len(GENRES) else text
    if text.isdigit() and int(text) < len(GENRES):
        return GENRES[int(text)]
    return text


@dataclass(frozen=True)
class CommentFrame:
    encoding: int
    language: bytes
    description: str
    text: str


def decode_comm(data: bytes) -> CommentFrame:
    if len(data) < 4:
        raise ID3Error("COMM frame too short")
    encoding = data[0]
    language = data[1:4]
    desc, rest = _split_terminated(data[4:], encoding)
    text = _decode(rest, encoding).rstrip("\x00")
    return CommentFrame(encoding, language, _decode(desc, encoding), text)


@dataclass(frozen=True)
class PopmFrame:
    email: str
    rating: int
    counter: bytes


def decode_popm(data: bytes) -> PopmFrame:
    i = data.find(b"\x00")
    if i == -1 or i + 1 >= len(data):
        raise ID3Error("POPM frame malformed")
    return PopmFrame(data[:i].decode("latin-1"), data[i + 1], data[i + 2 :])


# -- managed frames ------------------------------------------------------------------------------

MANAGED_IDS = ("TCON", "TIT1", "COMM", "POPM")
_MANAGED_IDS_22 = {"TCO": "TCON", "TT1": "TIT1", "COM": "COMM", "POP": "POPM"}


def _is_managed_id(fid: str) -> bool:
    return fid in MANAGED_IDS or fid in _MANAGED_IDS_22


def frame_role(frame: RawFrame, popm_email: str | None) -> str | None:
    """'genre', 'grouping', 'comment' or 'rating' when djtag manages this frame, else None."""
    fid = _MANAGED_IDS_22.get(frame.id, frame.id)
    if fid == "TCON":
        return "genre"
    if fid == "TIT1":
        return "grouping"
    if fid == "COMM":
        try:
            return "comment" if decode_comm(frame.data).description == "" else None
        except (ID3Error, UnicodeError):
            return None
    if fid == "POPM":
        if popm_email is None:
            return None
        try:
            return "rating" if decode_popm(frame.data).email == popm_email else None
        except ID3Error:
            return None
    return None


@dataclass
class ID3Managed:
    genre: str | None = None
    grouping: str | None = None
    comment: str | None = None
    rating_raw: int | None = None
    rating_email: str | None = None
    popm_emails: list[str] = field(default_factory=list)
    issues: list[str] = field(default_factory=list)


def read_managed(tag: ID3Tag | None, popm_email: str | None) -> ID3Managed:
    out = ID3Managed()
    if tag is None:
        return out
    seen: dict[str, int] = {}
    for frame in tag.frames:
        fid = _MANAGED_IDS_22.get(frame.id, frame.id)
        try:
            if fid == "POPM":
                popm = decode_popm(frame.data) if frame.id == "POPM" else _decode_pop22(frame.data)
                out.popm_emails.append(popm.email)
                if popm_email is None or popm.email == popm_email:
                    if out.rating_raw is None:
                        out.rating_raw, out.rating_email = popm.rating, popm.email
                    seen["rating"] = seen.get("rating", 0) + (1 if popm_email else 0)
                continue
            role = frame_role(frame, popm_email)
            if role == "genre":
                if out.genre is None:
                    out.genre = resolve_genre(decode_text_frame(frame.data))
            elif role == "grouping":
                if out.grouping is None:
                    out.grouping = decode_text_frame(frame.data)
            elif role == "comment":
                if out.comment is None:
                    out.comment = decode_comm(frame.data).text
            else:
                continue
            seen[role] = seen.get(role, 0) + 1
        except (ID3Error, UnicodeError) as exc:
            out.issues.append(f"cadre {frame.id} illisible ({exc})")
    for role, count in seen.items():
        if count > 1:
            out.issues.append(f"plusieurs cadres pour {role}")
    out.issues.extend(tag.issues)
    return out


def _decode_pop22(data: bytes) -> PopmFrame:
    return decode_popm(data)


# -- serialisation -------------------------------------------------------------------------------


def _can_latin1(text: str) -> bool:
    try:
        text.encode("latin-1")
    except UnicodeEncodeError:
        return False
    return True


def choose_encoding(text: str, major: int, preferred: int | None) -> int:
    if preferred is not None:
        valid = preferred in (0, 1) or (major == 4 and preferred in (2, 3))
        if valid and (preferred != 0 or _can_latin1(text)):
            return preferred
    if _can_latin1(text):
        return 0
    return 3 if major == 4 else 1


def encode_text(text: str, encoding: int) -> bytes:
    if encoding == 0:
        return text.encode("latin-1")
    if encoding == 1:
        return b"\xff\xfe" + text.encode("utf-16-le")
    if encoding == 2:
        return text.encode("utf-16-be")
    if encoding == 3:
        return text.encode("utf-8")
    raise ID3Error(f"unknown text encoding {encoding}")


def _terminator(encoding: int) -> bytes:
    return b"\x00\x00" if encoding in (1, 2) else b"\x00"


def build_frame(fid: str, payload: bytes, major: int, flags: bytes = b"\x00\x00") -> bytes:
    if major == 4:
        size = encode_syncsafe(len(payload))
    elif major == 3:
        size = struct.pack(">I", len(payload))
    else:
        raise ID3Error("only ID3v2.3 and ID3v2.4 can be written")
    return fid.encode("ascii") + size + flags + payload


def text_frame(fid: str, text: str, major: int, preferred_encoding: int | None, flags: bytes) -> bytes:
    enc = choose_encoding(text, major, preferred_encoding)
    return build_frame(fid, bytes([enc]) + encode_text(text, enc), major, flags)


def comm_frame(text: str, major: int, old: CommentFrame | None, language: bytes, flags: bytes) -> bytes:
    enc = choose_encoding(text, major, old.encoding if old else None)
    lang = old.language if old else language
    payload = bytes([enc]) + lang + encode_text("", enc) + _terminator(enc) + encode_text(text, enc)
    return build_frame("COMM", payload, major, flags)


def popm_frame(email: str, rating: int, counter: bytes, major: int, flags: bytes) -> bytes:
    payload = email.encode("latin-1") + b"\x00" + bytes([rating]) + counter
    return build_frame("POPM", payload, major, flags)


def _status_flags(frame: RawFrame) -> bytes:
    # Keep status flags (first byte), drop format flags we never produce.
    return bytes([frame.flags[0], 0]) if len(frame.flags) == 2 else b"\x00\x00"


@dataclass(frozen=True)
class WriteOptions:
    popm_email: str | None
    comm_language: bytes = b"eng"


def splice_frames(tag: ID3Tag | None, changes: Mapping[str, str | int | None], opts: WriteOptions) -> tuple[int, bytes]:
    """Return (major version, frame bytes) with only the changed managed frames rewritten.

    `changes` maps 'genre' / 'grouping' / 'comment' / 'rating' (stars already converted to
    the POPM byte by the caller) to the new value, None meaning "remove the frame".
    """
    if tag is not None and not tag.writable:
        raise ID3Error("tag non réinscriptible : " + ", ".join(tag.issues))
    major = tag.major if tag is not None else 3
    if "rating" in changes and opts.popm_email is None:
        raise ID3Error("propriétaire POPM inconnu (réglage rating.popm_email)")
    if "rating" in changes:
        blocked = rating_blocked(tag, opts.popm_email)
        if blocked:
            raise ID3Error(blocked)
    pending = dict(changes)
    out: list[bytes] = []
    frames = tag.frames if tag is not None else []
    for frame in frames:
        role = frame_role(frame, opts.popm_email)
        if role is None or role not in pending:
            out.append(frame.raw)
            continue
        value = pending.pop(role)
        if value is None:
            continue
        out.append(_serialise(role, value, major, frame, opts))
    for role, value in pending.items():
        if value is not None:
            out.append(_serialise(role, value, major, None, opts))
    return major, b"".join(out)


def rating_blocked(tag: ID3Tag | None, popm_email: str | None) -> str | None:
    """Why the rating cannot be written in this tag, or None if it can.

    djtag never adds a second POPM frame: when the file only has POPM frames owned by
    other software, the rating is left alone (decision 0006).
    """
    if popm_email is None:
        return "propriétaire POPM inconnu (réglage rating.popm_email)"
    if tag is None:
        return None
    owners = []
    for frame in tag.frames:
        if frame.id == "POPM":
            try:
                owners.append(decode_popm(frame.data).email)
            except ID3Error:
                return "cadre POPM illisible"
    if owners and popm_email not in owners:
        return "POPM d'un autre logiciel (" + ", ".join(owners) + ") : note non écrite"
    if owners.count(popm_email) > 1:
        return "plusieurs cadres POPM pour " + popm_email
    return None


def _serialise(role: str, value: str | int, major: int, old: RawFrame | None, opts: WriteOptions) -> bytes:
    flags = _status_flags(old) if old else b"\x00\x00"
    if role in ("genre", "grouping"):
        fid = "TCON" if role == "genre" else "TIT1"
        preferred = old.data[0] if old and old.data else None
        return text_frame(fid, str(value), major, preferred, flags)
    if role == "comment":
        old_comm = decode_comm(old.data) if old else None
        return comm_frame(str(value), major, old_comm, opts.comm_language, flags)
    if role == "rating":
        assert opts.popm_email is not None
        counter = decode_popm(old.data).counter if old else b""
        return popm_frame(opts.popm_email, int(value), counter, major, flags)
    raise ID3Error(f"unknown role {role}")


def build_tag(major: int, revision: int, flags: int, frames: bytes, size: int) -> bytes:
    """Header + frames + zero padding up to `size` bytes after the header."""
    if len(frames) > size:
        raise ID3Error("frames larger than the tag size")
    return b"ID3" + bytes([major, revision, flags]) + encode_syncsafe(size) + frames + b"\x00" * (size - len(frames))
