"""Detect a running Serato DJ (rule R6: never write tags while it is open)."""

from __future__ import annotations

import os
import subprocess

PROCESS_MARKERS = ("Serato DJ Pro", "Serato DJ Lite", "Serato DJ")


def running_processes() -> list[str] | None:
    """Process names, or None when they cannot be listed."""
    try:
        out = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    return [line.strip() for line in out.splitlines() if line.strip()]


def is_running() -> bool:
    """True when Serato DJ is open, or when that cannot be checked (fail closed)."""
    forced = os.environ.get("DJTAG_SERATO_RUNNING")
    if forced is not None and os.environ.get("PYTEST_CURRENT_TEST"):
        return forced == "1"  # test hook only: a stray variable must never disable R6
    procs = running_processes()
    if procs is None:
        return True
    return any(marker in proc for proc in procs for marker in PROCESS_MARKERS)
