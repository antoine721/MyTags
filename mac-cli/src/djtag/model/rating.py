"""Rating scales (docs/modele-tags.md, section 13)."""

from __future__ import annotations

POPM_WRITE = {1: 1, 2: 64, 3: 128, 4: 196, 5: 255}


def stars_from_popm(raw: int | None) -> int | None:
    if raw is None or raw <= 0:
        return None
    if raw < 32:
        return 1
    if raw < 96:
        return 2
    if raw < 160:
        return 3
    if raw < 224:
        return 4
    return 5


def stars_from_generic(raw: int | None) -> int | None:
    """MP4 / FLAC ratings of unknown scale: 0-5, 0-100 or 0-255."""
    if raw is None or raw <= 0:
        return None
    if raw <= 5:
        return raw
    if raw <= 100:
        return max(1, min(5, (raw + 10) // 20))
    return stars_from_popm(raw)


def popm_from_stars(stars: int) -> int:
    if stars not in POPM_WRITE:
        raise ValueError(f"rating must be 1..5, got {stars}")
    return POPM_WRITE[stars]


def parse_int(text: str | bytes | None) -> int | None:
    if text is None:
        return None
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    text = text.strip()
    try:
        return int(float(text))
    except ValueError:
        return None
