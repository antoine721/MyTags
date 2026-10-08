"""The shared tag-model vectors, also run by the Swift implementation."""

from __future__ import annotations

import pytest

from djtag.model.comment import compose_comment, parse_comment
from djtag.model.rating import popm_from_stars, stars_from_generic, stars_from_popm
from djtag.model.text import primary_artist, title_contains
from djtag.model.values import compute_targets, is_to_apply
from djtag.model.values_types import Baseline, FieldValue

from .vectors import config, option_id, values_by_key, vectors

V = vectors()


@pytest.mark.parametrize("case", V["comment_parse"], ids=lambda c: f"{c['config']}:{c['comment']!r}")
def test_comment_parse(case):
    cfg = config(case["config"])
    result = parse_comment(case["comment"], cfg)
    assert result.status == case["status"]
    assert values_by_key(cfg, result.values) == case["values"]
    assert sorted(cfg.field_by_id[i].key for i in result.explicit_empty) == sorted(case["explicit_empty"])


@pytest.mark.parametrize("case", V["comment_compose"], ids=lambda c: c["expected"])
def test_comment_compose(case):
    cfg = config(case["config"])
    values = {
        cfg.field_by_key[k].id: FieldValue(option_ids=tuple(option_id(cfg, k, v) for v in vals))
        for k, vals in case["values"].items()
    }
    assert compose_comment(values, cfg) == case["expected"]


def _rows(cfg, rows):
    out = {}
    for key, row in rows.items():
        f = cfg.field_by_key[key]
        if "rating" in row:
            out[f.id] = FieldValue(rating=row["rating"])
        else:
            out[f.id] = FieldValue(option_ids=tuple(option_id(cfg, key, v) for v in row.get("values", [])))
    return out


@pytest.mark.parametrize("case", V["targets"], ids=lambda c: c["name"])
def test_targets(case):
    cfg = config(case["config"])
    baseline = Baseline.from_json(case["baseline"])
    rows = _rows(cfg, case["rows"])
    assert compute_targets(case["format"], baseline, rows, cfg).to_json() == case["targets"]
    assert is_to_apply(case["format"], baseline, rows, cfg) is case["to_apply"]


@pytest.mark.parametrize("case", V["title_contains"], ids=lambda c: f"{c['title']}~{c['pattern']}")
def test_title_contains(case):
    assert title_contains(case["title"], case["pattern"]) is case["match"]


@pytest.mark.parametrize("case", V["primary_artist"], ids=lambda c: c["artist"])
def test_primary_artist(case):
    assert primary_artist(case["artist"]) == case["primary"]


@pytest.mark.parametrize("case", V["rating_read"], ids=lambda c: f"{c['scheme']}:{c['raw']}")
def test_rating_read(case):
    fn = stars_from_popm if case["scheme"] == "popm" else stars_from_generic
    assert fn(case["raw"]) == case["stars"]


def test_popm_write():
    for stars, raw in V["popm_write"].items():
        assert popm_from_stars(int(stars)) == raw
