#!/usr/bin/env python3
"""PreToolUse guard (spec section 16): Claude Code never touches the music folders itself.

- Bash: a command segment mentioning a music folder or `_Serato_` must be a `djtag` command.
- Edit / Write / MultiEdit / NotebookEdit: never inside a music folder or a `_Serato_` folder.

Music folders come from ~/.config/djtag/config.toml (or $DJTAG_CONFIG). Exit code 2 blocks the call.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
import tomllib
from pathlib import Path

DJTAG = re.compile(r"^(?:uv\s+run\s+(?:--\S+\s+)*)?djtag(?:\s|$)")


def music_folders() -> list[str]:
    path = Path(os.environ.get("DJTAG_CONFIG", "~/.config/djtag/config.toml")).expanduser()
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError):
        return []
    folders = data.get("library", {}).get("folders", [])
    out = []
    for f in folders:
        p = str(Path(f).expanduser())
        out.append(p.rstrip("/"))
        home = str(Path.home())
        if p.startswith(home):
            out.append("~" + p[len(home):])
    return [f for f in out if f and f not in ("/", "~")]


def segments(command: str) -> list[str]:
    parts = re.split(r"&&|\|\||;|\||\n", command)
    return [p.strip() for p in parts if p.strip()]


def mentions(text: str, folders: list[str]) -> bool:
    return "_Serato_" in text or any(f in text for f in folders)


def block(reason: str) -> None:
    print(f"Bloqué par le garde-fou MyTags : {reason}", file=sys.stderr)
    sys.exit(2)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError:
        return
    tool = payload.get("tool_name", "")
    data = payload.get("tool_input", {}) or {}
    folders = music_folders()
    if tool == "Bash":
        command = data.get("command", "")
        for segment in segments(command):
            if not mentions(segment, folders):
                continue
            stripped = segment
            if DJTAG.match(stripped):
                continue
            try:
                first = shlex.split(stripped)[0]
            except (ValueError, IndexError):
                first = stripped
            block(
                f"« {first} » vise un dossier de musique. Seul djtag peut lire ou écrire la bibliothèque "
                "(règle R1) : utiliser la skill appliquer-tags."
            )
    elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        target = data.get("file_path") or data.get("notebook_path") or ""
        resolved = str(Path(target).expanduser())
        if "_Serato_" in resolved or any(resolved.startswith(f + "/") or resolved == f for f in folders if not f.startswith("~")):
            block(f"écriture interdite dans la bibliothèque musicale ({target}).")


if __name__ == "__main__":
    main()
