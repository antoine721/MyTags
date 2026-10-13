"""Composed COMMENT: strict reading and composition (docs/modele-tags.md, sections 4 and 5)."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field

from .config import Field, TagConfig
from .normalize import compact, norm
from .values_types import FieldValue

CONFORME = "conforme"
INCOMPLET = "incomplet"
NON_CONFORME = "non_conforme"


@dataclass(frozen=True)
class CommentParse:
    status: str
    values: dict[str, FieldValue] = field(default_factory=dict)  # field id -> value
    explicit_empty: frozenset[str] = frozenset()  # field ids read as the empty token
    rest: str | None = None  # the COMMENT without its keywords (section 4 bis)

    @property
    def is_readable(self) -> bool:
        return self.status != NON_CONFORME


@dataclass(frozen=True)
class _SlotRead:
    option_ids: tuple[str, ...]
    explicit_empty: bool
    length: int  # matched text length, for the tie-break


def split_keywords(comment: str | None, config: TagConfig) -> tuple[str | None, dict[str, FieldValue]]:
    """Remove the keyword fields' words from the COMMENT (section 4 bis): (rest, values by field id)."""
    fields = config.keyword_fields()
    if comment is None or not fields:
        return comment, {}
    candidates = [
        (f.id, tuple(norm(text).split()), opt.id)
        for f in fields
        for opt in config.options(f.id)
        for text in opt.candidates
        if norm(text)
    ]
    words = comment.split()
    upper = [norm(w) for w in words]
    found: dict[str, FieldValue] = {}
    kept: list[str] = []
    i = 0
    while i < len(words):
        hit = next(
            (
                (fid, len(c), oid)
                for fid, c, oid in candidates
                if fid not in found and tuple(upper[i : i + len(c)]) == c
            ),
            None,
        )
        if hit is None:
            kept.append(words[i])
            i += 1
            continue
        field_id, length, option_id = hit
        found[field_id] = FieldValue(option_ids=(option_id,))
        i += length
    return (" ".join(kept) if found else comment), found


def parse_comment(comment: str | None, config: TagConfig) -> CommentParse:
    rest, keywords = split_keywords(comment, config)
    parsed = _parse_slots(rest, config)
    values = {**parsed.values, **keywords}
    return CommentParse(parsed.status, values, parsed.explicit_empty, rest)


def _parse_slots(comment: str | None, config: TagConfig) -> CommentParse:
    slots = config.comment_fields()
    text = norm(comment)
    if not text:
        return CommentParse(INCOMPLET)

    sep = compact(config.separator).upper()
    multi_sep = compact(config.multi_separator).upper()
    empty = norm(config.empty_token)
    candidates = [_candidates(f, config) for f in slots]
    empty_is_option = [any(c == empty for c, _ in cands) for cands in candidates]

    def boundary(end: int) -> int | None:
        """Position after a slot ending at `end`, or None if no separator follows."""
        if end == len(text):
            return end
        if sep and text.startswith(sep, end) and end + len(sep) < len(text):
            return end + len(sep)
        return None

    def reads(slot_index: int, pos: int) -> list[tuple[int, _SlotRead]]:
        """Every way to read slot `slot_index` at `pos`: (next position, read)."""
        f = slots[slot_index]
        cands = candidates[slot_index]
        out: list[tuple[int, _SlotRead]] = []
        if pos >= len(text):
            return out
        if f.kind == "multi":
            for end, ids in _multi_reads(text, pos, cands, multi_sep):
                nxt = boundary(end)
                if nxt is not None:
                    out.append((nxt, _SlotRead(ids, False, end - pos)))
        else:
            for cand, option_id in cands:
                if text.startswith(cand, pos):
                    nxt = boundary(pos + len(cand))
                    if nxt is not None:
                        out.append((nxt, _SlotRead((option_id,), False, len(cand))))
        if empty and not empty_is_option[slot_index] and text.startswith(empty, pos):
            nxt = boundary(pos + len(empty))
            if nxt is not None:
                out.append((nxt, _SlotRead((), True, len(empty))))
        return out

    best: tuple[tuple[object, ...], list[_SlotRead | None]] | None = None

    def visit(slot_index: int, pos: int, path: list[_SlotRead | None]) -> None:
        nonlocal best
        if slot_index == len(slots):
            if pos == len(text):
                key = _score(path)
                if best is None or key > best[0]:
                    best = (key, list(path))
            return
        for nxt, read in reads(slot_index, pos):
            path.append(read)
            visit(slot_index + 1, nxt, path)
            path.pop()
        path.append(None)
        visit(slot_index + 1, pos, path)
        path.pop()

    visit(0, 0, [])
    if best is None:
        return CommentParse(NON_CONFORME)

    values: dict[str, FieldValue] = {}
    explicit: set[str] = set()
    for f, read in zip(slots, best[1], strict=True):
        if read is None:
            continue
        if read.option_ids:
            ordered = sorted(set(read.option_ids), key=config.option_sort_key)
            values[f.id] = FieldValue(option_ids=tuple(ordered))
        elif read.explicit_empty:
            explicit.add(f.id)
    status = CONFORME if all(r is not None for r in best[1]) else INCOMPLET
    return CommentParse(status, values, frozenset(explicit))


def compose_comment(values: Mapping[str, FieldValue | None], config: TagConfig) -> str:
    """Join slot texts with the separator; empty slots become the empty token."""
    slots = config.comment_fields()
    if not slots:
        return ""
    by_slot = {f.target_slot: f for f in slots}
    max_slot = max(f.target_slot or 0 for f in slots)
    parts: list[str] = []
    for slot in range(1, max_slot + 1):
        f = by_slot.get(slot)
        value = values.get(f.id) if f else None
        parts.append(slot_text(f, value, config) if f and value else config.empty_token)
    return config.separator.join(parts)


def slot_text(f: Field, value: FieldValue, config: TagConfig) -> str:
    texts = option_texts(value, config)
    if not texts:
        return config.empty_token
    if f.kind == "multi":
        return config.multi_separator.join(texts)
    return texts[0]


def option_texts(value: FieldValue, config: TagConfig) -> list[str]:
    """Written texts of the value's options, in option display order."""
    ids = sorted(set(value.option_ids), key=config.option_sort_key)
    return [config.option_by_id[i].value for i in ids if i in config.option_by_id]


def _candidates(f: Field, config: TagConfig) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for opt in config.options(f.id):
        for text in opt.candidates:
            n = norm(text)
            if n:
                out.append((n, opt.id))
    return out


def _multi_reads(
    text: str, pos: int, cands: list[tuple[str, str]], multi_sep: str
) -> list[tuple[int, tuple[str, ...]]]:
    """Sequences of candidates joined by the multi separator, starting at `pos`."""
    results: list[tuple[int, tuple[str, ...]]] = []

    def extend(at: int, ids: tuple[str, ...]) -> None:
        for cand, option_id in cands:
            if text.startswith(cand, at):
                end = at + len(cand)
                acc = (*ids, option_id)
                results.append((end, acc))
                if multi_sep and text.startswith(multi_sep, end):
                    extend(end + len(multi_sep), acc)

    extend(pos, ())
    return results


def _score(path: list[_SlotRead | None]) -> tuple[object, ...]:
    flags = tuple(1 if r is not None else 0 for r in path)
    lengths = tuple(r.length if r is not None else 0 for r in path)
    return (sum(flags), flags, lengths)
