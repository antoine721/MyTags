"""File values, tag targets and "to apply" (docs/modele-tags.md, sections 3, 6 and 7)."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field

from .comment import CommentParse, compose_comment, option_texts, parse_comment
from .config import Field, TagConfig
from .normalize import blank_to_none, compact, norm
from .values_types import Baseline, FieldValue


@dataclass(frozen=True)
class FileValues:
    values: dict[str, FieldValue] = field(default_factory=dict)  # field id -> value read from file
    unknown: dict[str, str] = field(default_factory=dict)  # field id -> unrecognised raw text
    comment: CommentParse = field(default_factory=lambda: CommentParse("incomplet"))


def match_text(f: Field, text: str | None, config: TagConfig) -> FieldValue | None:
    """Recognise a GENRE / GROUPING text for a field, or None if unknown or empty."""
    if not norm(text):
        return None
    if f.kind == "text":
        return FieldValue(text=text)
    if f.kind == "multi":
        sep = compact(config.multi_separator).upper()
        parts = [p.strip() for p in norm(text).split(sep)] if sep else [norm(text)]
        ids: list[str] = []
        for part in parts:
            option_id = _match_option(f, part, config)
            if option_id is None:
                return None
            ids.append(option_id)
        return FieldValue(option_ids=tuple(sorted(set(ids), key=config.option_sort_key)))
    option_id = _match_option(f, norm(text), config)
    return FieldValue(option_ids=(option_id,)) if option_id else None


def _match_option(f: Field, normalised: str, config: TagConfig) -> str | None:
    for opt in config.options(f.id):
        if any(norm(c) == normalised for c in opt.candidates):
            return opt.id
    return None


def read_file_values(baseline: Baseline, config: TagConfig) -> FileValues:
    values: dict[str, FieldValue] = {}
    unknown: dict[str, str] = {}
    for tag in ("GENRE", "GROUPING"):
        f = config.field_for_tag(tag)
        raw = baseline.get(tag)
        if f is None or not isinstance(raw, str) or not norm(raw):
            continue
        matched = match_text(f, raw, config)
        if matched is None:
            unknown[f.id] = raw
        else:
            values[f.id] = matched
    rating_field = config.field_for_tag("RATING")
    if rating_field and baseline.rating:
        values[rating_field.id] = FieldValue(rating=baseline.rating)
    parsed = parse_comment(baseline.comment, config)
    values.update(parsed.values)
    return FileValues(values, unknown, parsed)


def format_value(f: Field, value: FieldValue, config: TagConfig) -> str | int | None:
    """Text (or rating) written in the file for a field value; None removes the tag."""
    if f.kind == "rating":
        return value.rating
    if f.kind == "text":
        return blank_to_none(value.text)
    texts = option_texts(value, config)
    if not texts:
        return None
    return config.multi_separator.join(texts) if f.kind == "multi" else texts[0]


def compute_targets(
    file_format: str, baseline: Baseline, rows: Mapping[str, FieldValue], config: TagConfig
) -> Baseline:
    """Managed tags the file should carry, given the app's confirmed rows."""
    genre, grouping, rating = baseline.genre, baseline.grouping, baseline.rating
    gf = config.field_for_tag("GENRE")
    if gf and gf.id in rows:
        genre = _as_text(format_value(gf, rows[gf.id], config))
    pf = config.field_for_tag("GROUPING")
    if pf and pf.id in rows:
        grouping = _as_text(format_value(pf, rows[pf.id], config))
    rf = config.field_for_tag("RATING")
    if rf and rf.id in rows and file_format in config.rating_write_formats:
        rating = rows[rf.id].rating

    comment = baseline.comment
    comment_fields = config.comment_fields()
    keyword_fields = config.keyword_fields()
    if any(f.id in rows for f in (*comment_fields, *keyword_fields)):
        parsed = parse_comment(baseline.comment, config)
        if any(f.id in rows for f in comment_fields):
            slot_values: dict[str, FieldValue | None] = {}
            for f in comment_fields:
                if f.id in rows:
                    slot_values[f.id] = rows[f.id]
                elif parsed.is_readable:
                    slot_values[f.id] = parsed.values.get(f.id)
            base = compose_comment(slot_values, config)
        else:
            base = parsed.rest or ""
        keywords: list[str] = []
        for f in keyword_fields:
            value = rows[f.id] if f.id in rows else parsed.values.get(f.id)
            texts = option_texts(value, config) if value else []
            if texts:
                keywords.append(texts[0])
        # Keywords are words: always joined by one space, whatever the COMMENT separator.
        comment = " ".join([base.rstrip(), *keywords]).strip() if keywords else base
    return Baseline(genre=genre, grouping=grouping, comment=comment, rating=rating)


def _as_text(value: str | int | None) -> str | None:
    return None if value is None else str(value)


def tags_equal(a: str | int | None, b: str | int | None) -> bool:
    """Exact comparison where empty strings equal absent values."""
    a2 = None if a == "" else a
    b2 = None if b == "" else b
    return a2 == b2


def differing_tags(target: Baseline, baseline: Baseline) -> list[str]:
    return [
        t
        for t in ("genre", "grouping", "comment", "rating")
        if not tags_equal(getattr(target, t), getattr(baseline, t))
    ]


def is_to_apply(
    file_format: str, baseline: Baseline, rows: Mapping[str, FieldValue], config: TagConfig
) -> bool:
    return bool(differing_tags(compute_targets(file_format, baseline, rows, config), baseline))
