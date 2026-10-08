"""Detect a running Serato DJ (rule R6: never write tags while it is open)."""

from __future__ import annotations

import os
import subprocess

PROCESS_MARKERS = ("Serato DJ Pro", "Serato DJ Lite", "Serato DJ")


def running_processes() -> list[str]:
    try:
        out = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


def is_running() -> bool:
    forced = os.environ.get("DJTAG_SERATO_RUNNING")
    if forced is not None:
        return forced == "1"
    return any(marker in proc for proc in running_processes() for marker in PROCESS_MARKERS)
