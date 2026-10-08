"""Synthetic audio files with realistic tags and fake Serato data (never real music)."""

from __future__ import annotations

import base64
import os
import shutil
import subprocess
from pathlib import Path

from mutagen.aiff import AIFF
from mutagen.flac import FLAC, Picture
from mutagen.id3 import (
    APIC,
    COMM,
    GEOB,
    ID3,
    POPM,
    TBPM,
    TCON,
    TIT1,
    TIT2,
    TKEY,
    TPE1,
    TXXX,
)
from mutagen.mp4 import MP4, MP4Cover, MP4FreeForm
from mutagen.wave import WAVE

SERATO_EMAIL = "serato.test@local"


def _tiny_jpeg() -> bytes:
    import io

    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (64, 64), (200, 30, 30)).save(buf, "JPEG")
    return buf.getvalue()


TINY_JPEG = _tiny_jpeg()

SERATO_MARKERS2 = b"\x01\x01" + os.urandom(470)
SERATO_OVERVIEW = b"\x01\x05" + os.urandom(3840)
SERATO_BEATGRID = b"\x01\x00" + os.urandom(30)


def _ffmpeg(args: list[str]) -> None:
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], check=True)


def make_base_audio(
    directory: Path, frequency: int = 440, duration: float = 2, noise_seed: int | None = None
) -> dict[str, Path]:
    """Sine tones (plus seeded pink noise, for distinct fingerprints) in every format, without tags."""
    directory.mkdir(parents=True, exist_ok=True)
    src = ["-f", "lavfi", "-i", f"sine=frequency={frequency}:duration={duration}:sample_rate=44100"]
    if noise_seed is not None:
        src += [
            "-f",
            "lavfi",
            "-i",
            f"anoisesrc=d={duration}:c=pink:a=0.05:seed={noise_seed}",
            "-filter_complex",
            "amix=inputs=2",
        ]
    src += ["-ac", "2"]
    out = {
        "mp3": directory / "base.mp3",
        "m4a": directory / "base.m4a",
        "flac": directory / "base.flac",
        "wav": directory / "base.wav",
        "aiff": directory / "base.aiff",
    }
    _ffmpeg(
        [
            *src,
            "-c:a",
            "libmp3lame",
            "-b:a",
            "128k",
            "-id3v2_version",
            "0",
            "-write_xing",
            "0",
            str(out["mp3"]),
        ]
    )
    _ffmpeg([*src, "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", str(out["m4a"])])
    _ffmpeg([*src, "-c:a", "flac", str(out["flac"])])
    _ffmpeg([*src, "-c:a", "pcm_s16le", str(out["wav"])])
    _ffmpeg([*src, "-c:a", "pcm_s16be", str(out["aiff"])])
    return out


def _id3_frames(tags: ID3, *, genre: str, grouping: str, comment: str, rating: int) -> None:
    tags.add(TIT2(encoding=3, text="Test Title (Extended Mix)"))
    tags.add(TPE1(encoding=3, text="Test Artist feat. Guest"))
    tags.add(TBPM(encoding=0, text="128"))
    tags.add(TKEY(encoding=0, text="8A"))
    tags.add(TCON(encoding=0, text=genre))
    tags.add(TIT1(encoding=0, text=grouping))
    tags.add(COMM(encoding=0, lang="eng", desc="", text=comment))
    tags.add(COMM(encoding=0, lang="eng", desc="iTunNORM", text=" 00000A00 00000B00"))
    tags.add(POPM(email=SERATO_EMAIL, rating=rating, count=3))
    tags.add(
        GEOB(
            encoding=0,
            mime="application/octet-stream",
            filename="",
            desc="Serato Markers2",
            data=SERATO_MARKERS2,
        )
    )
    tags.add(
        GEOB(
            encoding=0,
            mime="application/octet-stream",
            filename="",
            desc="Serato Overview",
            data=SERATO_OVERVIEW,
        )
    )
    tags.add(
        GEOB(
            encoding=0,
            mime="application/octet-stream",
            filename="",
            desc="Serato BeatGrid",
            data=SERATO_BEATGRID,
        )
    )
    tags.add(TXXX(encoding=3, desc="Serato Rating Emoji", text="🔥"))
    tags.add(APIC(encoding=0, mime="image/jpeg", type=3, desc="", data=TINY_JPEG))


def tagged_mp3(
    base: Path, dest: Path, *, version: int = 3, v1: bool = True, padding: int = 1024, **values: object
) -> Path:
    shutil.copyfile(base, dest)
    tags = ID3()
    _id3_frames(tags, **_defaults(values))
    if version == 3:
        tags.update_to_v23()
    tags.save(dest, v2_version=version, v1=2 if v1 else 0, padding=lambda info: padding)
    return dest


def tagged_wav(base: Path, dest: Path, **values: object) -> Path:
    shutil.copyfile(base, dest)
    audio = WAVE(dest)
    audio.add_tags()
    assert audio.tags is not None
    _id3_frames(audio.tags, **_defaults(values))
    audio.tags.update_to_v23()
    audio.save(v2_version=3)
    return dest


def tagged_aiff(base: Path, dest: Path, **values: object) -> Path:
    shutil.copyfile(base, dest)
    audio = AIFF(dest)
    audio.add_tags()
    assert audio.tags is not None
    _id3_frames(audio.tags, **_defaults(values))
    audio.save(v2_version=4)
    return dest


def tagged_m4a(base: Path, dest: Path, **values: object) -> Path:
    shutil.copyfile(base, dest)
    v = _defaults(values)
    audio = MP4(dest)
    audio.add_tags() if audio.tags is None else None
    assert audio.tags is not None
    audio.tags["©nam"] = ["Test Title (Extended Mix)"]
    audio.tags["©ART"] = ["Test Artist feat. Guest"]
    audio.tags["©gen"] = [str(v["genre"])]
    audio.tags["©grp"] = [str(v["grouping"])]
    audio.tags["©cmt"] = [str(v["comment"])]
    audio.tags["tmpo"] = [128]
    audio.tags["trkn"] = [(1, 10)]
    audio.tags["covr"] = [MP4Cover(TINY_JPEG, imageformat=MP4Cover.FORMAT_JPEG)]
    audio.tags["----:com.serato.dj:markersv2"] = [MP4FreeForm(base64.b64encode(SERATO_MARKERS2))]
    audio.tags["----:com.serato.dj:beatgrid"] = [MP4FreeForm(base64.b64encode(SERATO_BEATGRID))]
    audio.tags["----:com.apple.iTunes:RATE"] = [MP4FreeForm(str(int(v["rating"]) // 51 * 20).encode())]
    audio.save()
    return dest


def tagged_flac(base: Path, dest: Path, padding: int = 1024, **values: object) -> Path:
    shutil.copyfile(base, dest)
    v = _defaults(values)
    audio = FLAC(dest)
    audio.add_tags() if audio.tags is None else None
    assert audio.tags is not None
    audio.tags["TITLE"] = "Test Title (Extended Mix)"
    audio.tags["ARTIST"] = "Test Artist feat. Guest"
    audio.tags["GENRE"] = str(v["genre"])
    audio.tags["GROUPING"] = str(v["grouping"])
    audio.tags["COMMENT"] = str(v["comment"])
    audio.tags["SERATO_MARKERS_V2"] = base64.b64encode(SERATO_MARKERS2).decode()
    audio.tags["SERATO_BEATGRID"] = base64.b64encode(SERATO_BEATGRID).decode()
    pic = Picture()
    pic.type = 3
    pic.mime = "image/jpeg"
    pic.data = TINY_JPEG
    audio.add_picture(pic)
    audio.save(padding=lambda info: padding)
    return dest


def _defaults(values: dict[str, object]) -> dict[str, object]:
    return {
        "genre": values.get("genre", "Rap Fr"),
        "grouping": values.get("grouping", "VERT"),
        "comment": values.get("comment", "fr extend sexy"),
        "rating": values.get("rating", 128),
    }


def tagged(fmt: str, base: dict[str, Path], dest_dir: Path, name: str = "track", **values: object) -> Path:
    dest = dest_dir / f"{name}.{fmt}"
    builders = {
        "mp3": tagged_mp3,
        "wav": tagged_wav,
        "aiff": tagged_aiff,
        "m4a": tagged_m4a,
        "flac": tagged_flac,
    }
    return builders[fmt](base[fmt], dest, **values)  # type: ignore[operator]
