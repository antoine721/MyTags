"""Load shared/test-vectors/tag-model.json and its simplified configurations."""

from __future__ import annotations

import json
from functools import cache
from pathlib import Path
from typing import Any

from djtag.model.config import Field, FieldOption, TagConfig

REPO = Path(__file__).resolve().parents[2]
VECTORS = REPO / "shared" / "test-vectors" / "tag-model.json"
DEFAULT_CONFIG = REPO / "shared" / "default-config.json"


@cache
def vectors() -> dict[str, Any]:
    return json.loads(VECTORS.read_text(encoding="utf-8"))


@cache
def config(name: str) -> TagConfig:
    if name == "default":
        return TagConfig.from_json(json.loads(DEFAULT_CONFIG.read_text(encoding="utf-8")))
    spec = vectors()["configs"][name]
    fields: list[Field] = []
    options: list[FieldOption] = []
    for pos, f in enumerate(spec["fields"]):
        fields.append(
            Field(
                id=f["key"],
                key=f["key"],
                name=f["key"],
                kind=f["kind"],
                target_tag=f["target_tag"],
                target_slot=f["target_slot"],
                position=pos,
            )
        )
        for opos, o in enumerate(f["options"]):
            value, aliases = (o, []) if isinstance(o, str) else (o["value"], o.get("aliases", []))
            options.append(
                FieldOption(
                    id=f"{f['key']}:{value}",
                    field_id=f["key"],
                    value=value,
                    aliases=tuple(aliases),
                    position=opos,
                )
            )
    return TagConfig(fields, options, (), spec["settings"])


def option_id(cfg: TagConfig, field_key: str, value: str) -> str:
    f = cfg.field_by_key[field_key]
    for opt in cfg.options(f.id):
        if opt.value == value:
            return opt.id
    raise KeyError(f"{field_key}:{value}")


def values_by_key(cfg: TagConfig, values: dict[str, Any]) -> dict[str, list[str]]:
    """Convert {field id: FieldValue} to {field key: [option values]} for comparison."""
    out: dict[str, list[str]] = {}
    for field_id, value in values.items():
        key = cfg.field_by_id[field_id].key
        out[key] = [cfg.option_by_id[i].value for i in value.option_ids]
    return out
