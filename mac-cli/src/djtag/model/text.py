"""Title patterns and primary artist (docs/modele-tags.md, sections 10 and 11)."""

from __future__ import annotations

import re

_WORD = re.compile(r"[^\W_]+", re.UNICODE)
_ARTIST_SEPARATORS = (
    " feat. ",
    " feat ",
    " ft. ",
    " ft ",
    " featuring ",
    " & ",
    ", ",
    " x ",
    " vs. ",
    " vs ",
)


def words(text: str) -> list[str]:
    """Unicode letter/digit runs, case-folded."""
    return [w.casefold() for w in _WORD.findall(text or "")]


def title_contains(title: str, pattern: str) -> bool:
    haystack = words(title)
    needle = words(pattern)
    if not needle or len(needle) > len(haystack):
        return False
    n = len(needle)
    return any(haystack[i : i + n] == needle for i in range(len(haystack) - n + 1))


def primary_artist(artist: str | None) -> str:
    text = (artist or "").strip()
    lowered = text.lower()
    cut = len(text)
    for sep in _ARTIST_SEPARATORS:
        idx = lowered.find(sep)
        if idx != -1 and idx < cut:
            cut = idx
    primary = text[:cut].strip()
    return primary or text
