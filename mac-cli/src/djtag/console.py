"""Terminal output: rich for humans, JSON for AI agents (--json)."""

from __future__ import annotations

import json
import sys
from typing import Any

from rich.console import Console

console = Console(highlight=False)
err = Console(stderr=True, highlight=False)

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_CONFLICTS = 2
EXIT_REFUSED = 3


def emit_json(payload: Any) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, indent=2, default=str) + "\n")
