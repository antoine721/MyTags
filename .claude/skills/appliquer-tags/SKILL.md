---
name: appliquer-tags
description: Apply the tags edited on the iPhone to the music files on the Mac with djtag (status, diff, explicit confirmation, apply, report, Serato re-scan reminder). Use when the user says "applique mes tags", "applique mes tags du train", "écris les tags", or asks to write, apply or roll back MyTags changes.
---

# Appliquer les tags (djtag)

Writes the tags confirmed in the app into the audio files, safely. Talk to the user in French.
Run every command from the `mac-cli/` folder of the repository with `uv run djtag … --json`.

## Steps

1. **Check** — `uv run djtag doctor --json`.
   - Exit code ≠ 0: show the failing checks and stop.
   - If "Serato DJ fermé" is not ok: ask the user to quit Serato DJ, then re-run doctor. Never continue
     while Serato is open (rule R6).
2. **Summary** — `uv run djtag status --json`. If `to_apply` is 0 and there is no conflict, say so and stop.
3. **Preview** — `uv run djtag diff --json` (and `--markdown ~/DJTag/reports/diff-latest.md`).
   Show the user: number of tracks, totals per tag (GENRE, GROUPING, COMMENT, NOTE), 5 examples
   (artist — title: current → new), the conflicts and the warnings (e.g. ratings not written).
4. **Explicit confirmation** — ask: « J'écris ces N morceaux ? (sauvegarde automatique, annulable) ».
   Only continue on a clear yes. Anything else: stop without writing.
   - First real use (no previous application in `status.last_runs`): propose `--limit 20` first and a
     check in Serato before the rest (rule R4 / spec phase 6).
5. **Apply** — `uv run djtag apply --yes --json` (add `--limit N` if agreed).
   - Exit 3: safety refusal — show the message, stop.
   - Exit 2: conflicts — go to "Conflicts".
   - Exit 1: errors — list them (the files were restored or never touched), stop.
6. **Report** — give: written / conflicts / errors, the application id, the report path, and how to undo:
   `uv run djtag rollback <id>`.
7. **Serato** — remind: in Serato DJ Pro 4, select the modified tracks, right-click › "Re-Scan File Info"
   (see `docs/serato.md`).

## Conflicts

A conflict means the file changed outside the app (often in Serato) since the import; nothing was written.
List them (path + message) and ask, track by track or for all at once:

- keep the file's value → `uv run djtag resolve <ids…> --keep-file --json`
- impose the app's value → `uv run djtag resolve <ids…> --keep-app --json`, then offer to apply again.

## Undo

« annule la dernière application » → find the id in `djtag status --json` (`last_runs`), confirm with the
user, then `uv run djtag rollback <id> --yes --json`. A file modified after the application is skipped
unless the user explicitly asks to force it (`--force`).

## Never

- Never run `djtag apply` or `djtag rollback` without the user's explicit yes in this conversation.
- Never touch the music files with any other command (cp, mv, rm, ffmpeg, mutagen…).
- Never edit files in a `_Serato_` folder.
