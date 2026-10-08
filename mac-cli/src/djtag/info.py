"""Descriptive metadata (title, artist, BPM, key, duration) read with mutagen."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from mutagen._file import File as mutagen_file


@dataclass
class TrackInfo:
    title: str | None = None
    artist: str | None = None
    album: str | None = None
    bpm: float | None = None
    musical_key: str | None = None
    duration_ms: int | None = None
    bitrate: int | None = None
    sample_rate: int | None = None


def _first(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, list):
        value = value[0] if value else None
    if value is None:
        return None
    if hasattr(value, "text"):
        texts = value.text
        value = texts[0] if texts else None
    if isinstance(value, bytes):
        value = value.decode("utf-8", "replace")
    text = str(value).strip() if value is not None else ""
    return text or None


def _bpm(value: str | None) -> float | None:
    if not value:
        return None
    try:
        bpm = float(value.replace(",", "."))
    except ValueError:
        return None
    return round(bpm, 2) if 20 <= bpm <= 400 else None


def read_info(path: Path, fmt: str) -> TrackInfo:
    audio = mutagen_file(path)
    info = TrackInfo()
    if audio is None:
        return info
    if audio.info is not None:
        length = getattr(audio.info, "length", None)
        info.duration_ms = int(round(length * 1000)) if length else None
        info.bitrate = getattr(audio.info, "bitrate", None)
        info.sample_rate = getattr(audio.info, "sample_rate", None)
    tags = audio.tags
    if tags is None:
        return info
    if fmt in ("mp3", "wav", "aiff"):
        info.title = _first(tags.get("TIT2"))
        info.artist = _first(tags.get("TPE1"))
        info.album = _first(tags.get("TALB"))
        info.bpm = _bpm(_first(tags.get("TBPM")))
        info.musical_key = _first(tags.get("TKEY"))
    elif fmt == "m4a":
        info.title = _first(tags.get("©nam"))
        info.artist = _first(tags.get("©ART"))
        info.album = _first(tags.get("©alb"))
        tmpo = tags.get("tmpo")
        info.bpm = _bpm(str(tmpo[0])) if tmpo else None
        for key in ("----:com.apple.iTunes:initialkey", "----:com.apple.iTunes:KEY"):
            if key in tags:
                info.musical_key = _first(tags[key])
                break
    elif fmt == "flac":
        info.title = _first(tags.get("TITLE"))
        info.artist = _first(tags.get("ARTIST"))
        info.album = _first(tags.get("ALBUM"))
        info.bpm = _bpm(_first(tags.get("BPM")))
        info.musical_key = _first(tags.get("INITIALKEY")) or _first(tags.get("KEY"))
    return info
