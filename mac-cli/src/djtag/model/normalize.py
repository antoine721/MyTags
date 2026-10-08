"""Text normalisation (docs/modele-tags.md, section 1)."""

from __future__ import annotations

import re

_WS = re.compile(r"\s+")


def compact(text: str) -> str:
    """Collapse every whitespace run into a single space, without trimming."""
    return _WS.sub(" ", text)


def norm(text: str | None) -> str:
    """Collapse whitespace, trim and upper-case. `None` becomes an empty string."""
    if text is None:
        return ""
    return compact(text).strip().upper()


def equivalent(a: str | None, b: str | None) -> bool:
    return norm(a) == norm(b)


def blank_to_none(text: str | None) -> str | None:
    """Treat empty strings as absent values (null ≡ "")."""
    return text if text else None
