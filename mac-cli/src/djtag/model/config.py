"""Field configuration (fields, options, rules, shared settings).

Mirrors the `fields`, `field_options`, `rules` and `settings` tables. The same
JSON shape is used by the API and by `shared/default-config.json`.
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from importlib import resources
from typing import Any

MANAGED_TAGS = ("GENRE", "GROUPING", "COMMENT", "RATING")
SINGLE_TARGET_TAGS = ("GENRE", "GROUPING", "RATING")

DEFAULT_SEPARATOR = " "
DEFAULT_EMPTY_TOKEN = "()"
DEFAULT_MULTI_SEPARATOR = "/"
DEFAULT_RATING_WRITE_FORMATS = ("mp3", "wav", "aiff")


@dataclass(frozen=True)
class FieldOption:
    id: str
    field_id: str
    value: str
    label: str | None = None
    color: str | None = None
    aliases: tuple[str, ...] = ()
    position: int = 0
    archived: bool = False

    @property
    def candidates(self) -> tuple[str, ...]:
        """Texts recognised for this option when reading a file: value, then aliases."""
        return (self.value, *self.aliases)


@dataclass(frozen=True)
class Field:
    id: str
    key: str
    name: str
    kind: str  # single | multi | rating | text
    target_tag: str  # GENRE | GROUPING | COMMENT | RATING
    target_slot: int | None = None
    required: bool = False
    visible: bool = True
    position: int = 0
    default_option_id: str | None = None
    is_advance_trigger: bool = False
    artist_level: bool = False


@dataclass(frozen=True)
class Rule:
    id: str
    name: str
    enabled: bool
    position: int
    condition: Mapping[str, Any]
    action: Mapping[str, Any]
    mode: str  # suggest | apply


class TagConfig:
    """Resolved configuration with fast lookups. Soft-deleted rows are ignored."""

    def __init__(
        self,
        fields: Iterable[Field],
        options: Iterable[FieldOption],
        rules: Iterable[Rule] = (),
        settings: Mapping[str, Any] | None = None,
    ) -> None:
        self.fields: list[Field] = sorted(fields, key=lambda f: (f.position, f.key))
        self.field_by_id: dict[str, Field] = {f.id: f for f in self.fields}
        self.field_by_key: dict[str, Field] = {f.key: f for f in self.fields}
        self.option_by_id: dict[str, FieldOption] = {}
        self._options_by_field: dict[str, list[FieldOption]] = {f.id: [] for f in self.fields}
        for opt in options:
            self.option_by_id[opt.id] = opt
            self._options_by_field.setdefault(opt.field_id, []).append(opt)
        for opts in self._options_by_field.values():
            opts.sort(key=lambda o: (o.position, o.value))
        self.rules: list[Rule] = sorted(rules, key=lambda r: r.position)
        settings = dict(settings or {})
        self.separator: str = _str_setting(settings, "comment.separator", DEFAULT_SEPARATOR)
        self.empty_token: str = _str_setting(settings, "comment.empty_token", DEFAULT_EMPTY_TOKEN)
        self.multi_separator: str = _str_setting(settings, "multi.separator", DEFAULT_MULTI_SEPARATOR)
        formats = settings.get("rating.write_formats")
        self.rating_write_formats: tuple[str, ...] = (
            tuple(str(f) for f in formats) if isinstance(formats, list) else DEFAULT_RATING_WRITE_FORMATS
        )

    def options(self, field_id: str) -> list[FieldOption]:
        """Options of a field in display order, archived ones included."""
        return self._options_by_field.get(field_id, [])

    def field_for_tag(self, tag: str) -> Field | None:
        """The field targeting GENRE, GROUPING or RATING (at most one is allowed)."""
        for f in self.fields:
            if f.target_tag == tag:
                return f
        return None

    def comment_fields(self) -> list[Field]:
        """Fields targeting the composed COMMENT, ordered by slot."""
        return sorted(
            (f for f in self.fields if f.target_tag == "COMMENT" and f.target_slot is not None),
            key=lambda f: f.target_slot or 0,
        )

    def keyword_fields(self) -> list[Field]:
        """Single-choice fields targeting the COMMENT without a slot, in display order (section 4 bis)."""
        return [
            f
            for f in self.fields
            if f.target_tag == "COMMENT" and f.target_slot is None and f.kind == "single"
        ]

    def option_sort_key(self, option_id: str) -> tuple[int, str]:
        opt = self.option_by_id.get(option_id)
        return (opt.position, opt.value) if opt else (1 << 30, option_id)

    # -- construction -------------------------------------------------------------------------

    @classmethod
    def from_json(cls, data: Mapping[str, Any]) -> TagConfig:
        """Build from the API / default-config.json shape."""
        fields = [
            Field(
                id=row["id"],
                key=row["key"],
                name=row.get("name") or row["key"],
                kind=row["kind"],
                target_tag=row["target_tag"],
                target_slot=row.get("target_slot"),
                required=bool(row.get("required", False)),
                visible=bool(row.get("visible", True)),
                position=int(row.get("position", 0)),
                default_option_id=row.get("default_option_id"),
                is_advance_trigger=bool(row.get("is_advance_trigger", False)),
                artist_level=bool(row.get("artist_level", False)),
            )
            for row in data.get("fields", [])
            if not row.get("deleted_at")
        ]
        options = [
            FieldOption(
                id=row["id"],
                field_id=row["field_id"],
                value=row["value"],
                label=row.get("label"),
                color=row.get("color"),
                aliases=tuple(row.get("aliases") or ()),
                position=int(row.get("position", 0)),
                archived=bool(row.get("archived", False)),
            )
            for row in data.get("field_options", [])
            if not row.get("deleted_at")
        ]
        rules = [
            Rule(
                id=row["id"],
                name=row.get("name", ""),
                enabled=bool(row.get("enabled", True)),
                position=int(row.get("position", 0)),
                condition=row.get("condition") or {},
                action=row.get("action") or {},
                mode=row.get("mode", "suggest"),
            )
            for row in data.get("rules", [])
            if not row.get("deleted_at")
        ]
        settings = {
            row["key"]: row.get("value") for row in data.get("settings", []) if not row.get("deleted_at")
        }
        return cls(fields, options, rules, settings)

    @classmethod
    def default(cls) -> TagConfig:
        """The starting configuration bundled with the tool (spec annex A)."""
        return cls.from_json(load_default_config_json())


def load_default_config_json() -> dict[str, Any]:
    text = resources.files("djtag.data").joinpath("default-config.json").read_text(encoding="utf-8")
    return json.loads(text)


def _str_setting(settings: Mapping[str, Any], key: str, default: str) -> str:
    value = settings.get(key)
    return value if isinstance(value, str) and value != "" else default
