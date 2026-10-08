"""Listening copies (AAC, -14 LUFS, faststart), waveform and start point (spec sections 10 and 12)."""

from __future__ import annotations

import base64
import json
import math
import re
import shutil
import subprocess
from array import array
from dataclasses import dataclass
from functools import cache
from pathlib import Path

ANALYSIS_RATE = 8000
WAVEFORM_BINS = 600
ENERGY_FRAME_S = 0.5
ENERGY_WINDOW_S = 4.0


class AudioError(Exception):
    pass


@cache
def ffmpeg_encoders() -> str:
    try:
        return subprocess.run(
            ["ffmpeg", "-hide_banner", "-encoders"], capture_output=True, text=True, check=True
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return ""


def ffmpeg_available() -> bool:
    return shutil.which("ffmpeg") is not None


def pick_encoder(preference: str) -> str:
    """'aac_at' (Apple AudioToolbox, better quality) when available, else ffmpeg's 'aac'."""
    has_at = re.search(r"^\s*A\S*\s+aac_at\s", ffmpeg_encoders(), re.MULTILINE) is not None
    if preference == "aac_at" and not has_at:
        raise AudioError("l'encodeur aac_at n'est pas disponible dans ce ffmpeg")
    if preference in ("aac", "aac_at"):
        return preference
    return "aac_at" if has_at else "aac"


def _run(args: list[str], *, timeout: float = 600) -> subprocess.CompletedProcess[bytes]:
    try:
        return subprocess.run(args, capture_output=True, timeout=timeout, check=True)
    except subprocess.CalledProcessError as exc:
        tail = exc.stderr.decode("utf-8", "replace")[-400:] if exc.stderr else ""
        raise AudioError(f"ffmpeg a échoué : {tail}") from exc
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AudioError(str(exc)) from exc


@dataclass(frozen=True)
class Loudness:
    input_i: float
    input_tp: float
    input_lra: float
    input_thresh: float
    target_offset: float


def measure_loudness(src: Path, target_lufs: float) -> Loudness | None:
    result = _run(
        [
            "ffmpeg",
            "-hide_banner",
            "-nostats",
            "-i",
            str(src),
            "-map",
            "0:a:0",
            "-vn",
            "-af",
            f"loudnorm=I={target_lufs}:TP=-1.0:LRA=11:print_format=json",
            "-f",
            "null",
            "-",
        ]
    )
    text = result.stderr.decode("utf-8", "replace")
    start = text.rfind("{")
    end = text.rfind("}")
    if start == -1 or end == -1:
        return None
    try:
        data = json.loads(text[start : end + 1])
        values = Loudness(
            float(data["input_i"]),
            float(data["input_tp"]),
            float(data["input_lra"]),
            float(data["input_thresh"]),
            float(data["target_offset"]),
        )
    except (KeyError, ValueError):
        return None
    if not all(
        math.isfinite(v) for v in (values.input_i, values.input_tp, values.input_lra, values.input_thresh)
    ):
        return None  # silence: loudnorm reports -inf
    return values


def transcode(src: Path, dest: Path, *, bitrate: str, target_lufs: float, encoder: str) -> int:
    """Write the listening copy and return its size in bytes."""
    dest.parent.mkdir(parents=True, exist_ok=True)
    loud = measure_loudness(src, target_lufs)
    if loud is not None:
        af = (
            f"loudnorm=I={target_lufs}:TP=-1.0:LRA=11:measured_I={loud.input_i}:measured_TP={loud.input_tp}"
            f":measured_LRA={loud.input_lra}:measured_thresh={loud.input_thresh}:offset={loud.target_offset}"
            ":linear=true"
        )
        filters = ["-af", af]
    else:
        filters = []
    tmp = dest.with_suffix(".part.m4a")
    _run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(src),
            "-map",
            "0:a:0",
            "-vn",
            "-map_metadata",
            "-1",
            *filters,
            "-ar",
            "44100",
            "-ac",
            "2",
            "-c:a",
            encoder,
            "-b:a",
            bitrate,
            "-movflags",
            "+faststart",
            str(tmp),
        ]
    )
    tmp.replace(dest)
    return dest.stat().st_size


def decode_pcm(src: Path) -> array:
    """Mono signed 16-bit samples at ANALYSIS_RATE."""
    result = _run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(src),
            "-map",
            "0:a:0",
            "-vn",
            "-ac",
            "1",
            "-ar",
            str(ANALYSIS_RATE),
            "-f",
            "s16le",
            "-acodec",
            "pcm_s16le",
            "-",
        ]
    )
    samples = array("h")
    samples.frombytes(result.stdout[: len(result.stdout) // 2 * 2])
    return samples


def waveform(samples: array, bins: int = WAVEFORM_BINS) -> bytes:
    """Peak amplitude per bin, scaled so the loudest bin is 255."""
    if not samples:
        return bytes(bins)
    n = len(samples)
    peaks: list[int] = []
    for i in range(bins):
        chunk = samples[i * n // bins : (i + 1) * n // bins]
        peaks.append(max(max(chunk), -min(chunk)) if chunk else 0)
    top = max(peaks) or 1
    return bytes(min(255, round(p * 255 / top)) for p in peaks)


def waveform_b64(samples: array) -> str:
    return base64.b64encode(waveform(samples)).decode("ascii")


def start_point_ms(samples: array, rate: int = ANALYSIS_RATE) -> int:
    """Start of the first 4 s zone reaching 90 % of the loudest one, minus 2 s.

    Never in the last 10 % of the track; falls back to 25 % of the duration.
    """
    duration_s = len(samples) / rate if rate else 0
    if duration_s <= 0:
        return 0
    frame = int(rate * ENERGY_FRAME_S)
    energies: list[float] = []
    for start in range(0, len(samples) - frame + 1, frame):
        chunk = samples[start : start + frame]
        energies.append(math.fsum(x * x for x in chunk) / frame)
    window = int(ENERGY_WINDOW_S / ENERGY_FRAME_S)
    if len(energies) < window:
        return 0
    averages = [math.fsum(energies[i : i + window]) / window for i in range(len(energies) - window + 1)]
    peak = max(averages)
    if peak <= 0:
        return int(duration_s * 250)
    first = next(i for i, e in enumerate(averages) if e >= 0.9 * peak)
    start_s = max(0.0, first * ENERGY_FRAME_S - 2.0)
    if start_s > 0.9 * duration_s:
        start_s = 0.25 * duration_s
    return int(start_s * 1000)
