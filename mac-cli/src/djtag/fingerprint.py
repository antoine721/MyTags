"""Chromaprint acoustic fingerprints (fpcalc), to recognise moved or renamed files."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Fingerprint:
    digest: str  # sha256 of the Chromaprint string, 32 hex chars (what the cloud stores)
    duration: float


def available() -> bool:
    return shutil.which("fpcalc") is not None


def compute(path: Path, timeout: float = 120) -> Fingerprint | None:
    try:
        result = subprocess.run(
            ["fpcalc", "-json", str(path)], capture_output=True, text=True, timeout=timeout, check=True
        )
        data = json.loads(result.stdout)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return None
    fp = data.get("fingerprint")
    if not fp:
        return None
    return Fingerprint(hashlib.sha256(fp.encode("ascii")).hexdigest()[:32], float(data.get("duration", 0)))


def same_audio(a: Fingerprint | None, b: Fingerprint | None) -> bool:
    """Same fingerprint and same duration within one second."""
    return a is not None and b is not None and a.digest == b.digest and abs(a.duration - b.duration) <= 1.0
