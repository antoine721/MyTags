"""Value types shared by the model modules."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class FieldValue:
    """A field's value for one track: options (single/multi), a rating, or free text."""

    option_ids: tuple[str, ...] = ()
    rating: int | None = None
    text: str | None = None

    @property
    def is_empty(self) -> bool:
        return not self.option_ids and self.rating is None and not self.text

    def to_json(self) -> dict[str, Any]:
        return {"option_ids": list(self.option_ids), "rating": self.rating, "text": self.text}

    @classmethod
    def from_json(cls, data: Mapping[str, Any] | None) -> FieldValue:
        if not data:
            return cls()
        return cls(
            option_ids=tuple(data.get("option_ids") or ()),
            rating=data.get("rating"),
            text=data.get("text", data.get("text_value")),
        )


@dataclass(frozen=True)
class Baseline:
    """Managed tags as they are in the file (the reference used for conflicts)."""

    genre: str | None = None
    grouping: str | None = None
    comment: str | None = None
    rating: int | None = None  # 1..5 stars

    def get(self, tag: str) -> str | int | None:
        return getattr(self, tag.lower())

    def to_json(self) -> dict[str, Any]:
        return {
            "genre": self.genre,
            "grouping": self.grouping,
            "comment": self.comment,
            "rating": self.rating,
        }

    @classmethod
    def from_json(cls, data: Mapping[str, Any] | None) -> Baseline:
        if not data:
            return cls()
        return cls(
            genre=data.get("genre"),
            grouping=data.get("grouping"),
            comment=data.get("comment"),
            rating=data.get("rating"),
        )
