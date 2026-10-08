"""Cover art: embedded picture, else cover.jpg / folder.jpg next to the file; 600 and 150 px JPEGs."""

from __future__ import annotations

import io
from pathlib import Path

from mutagen._file import File as mutagen_file
from mutagen.flac import FLAC
from mutagen.mp4 import MP4
from PIL import Image, UnidentifiedImageError

FOLDER_NAMES = ("cover", "folder", "front", "album", "artwork")
SIZES = (600, 150)


def embedded_picture(path: Path, fmt: str) -> bytes | None:
    try:
        if fmt == "m4a":
            tags = MP4(path).tags
            covers = tags.get("covr") if tags else None
            return bytes(covers[0]) if covers else None
        if fmt == "flac":
            pictures = FLAC(path).pictures
            front = [p for p in pictures if p.type == 3] or pictures
            return front[0].data if front else None
        audio = mutagen_file(path)
        tags = getattr(audio, "tags", None)
        if tags is None:
            return None
        apics = tags.getall("APIC") if hasattr(tags, "getall") else []
        front = [a for a in apics if a.type == 3] or apics
        return front[0].data if front else None
    except Exception:
        return None


def folder_picture(path: Path) -> bytes | None:
    try:
        entries = list(path.parent.iterdir())
    except OSError:
        return None
    by_stem = {e.stem.lower(): e for e in entries if e.suffix.lower() in (".jpg", ".jpeg", ".png")}
    for name in FOLDER_NAMES:
        if name in by_stem:
            try:
                return by_stem[name].read_bytes()
            except OSError:
                return None
    return None


def render_covers(data: bytes, dest_dir: Path, stem: str) -> dict[int, Path] | None:
    """Square, centre-cropped JPEGs at each size; None if the picture is unreadable."""
    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except (UnidentifiedImageError, OSError, ValueError):
        return None
    image = image.convert("RGB")
    side = min(image.size)
    left = (image.width - side) // 2
    top = (image.height - side) // 2
    square = image.crop((left, top, left + side, top + side))
    out: dict[int, Path] = {}
    dest_dir.mkdir(parents=True, exist_ok=True)
    for size in SIZES:
        target = dest_dir / f"{stem}_{size}.jpg"
        square.resize((size, size), Image.Resampling.LANCZOS).save(target, "JPEG", quality=85, optimize=True)
        out[size] = target
    return out


def extract(path: Path, fmt: str, dest_dir: Path, stem: str) -> dict[int, Path] | None:
    data = embedded_picture(path, fmt) or folder_picture(path)
    return render_covers(data, dest_dir, stem) if data else None
