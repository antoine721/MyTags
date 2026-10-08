# MyTags — instructions for Claude Code

MyTags tags ~5,000 DJ tracks from an iPhone (train, offline) and writes the tags into the files
read by Serato DJ, **only on explicit command**, from the Mac.

- `docs/cahier-des-charges.md` is the reference specification (French). Deviations are recorded in
  `docs/decisions/`. Progress lives in `docs/avancement.md`.
- Languages: app UI and `docs/` in French; code, identifiers, comments and commit messages in English.

## Layout

| Path | What |
| --- | --- |
| `mac-cli/` | `djtag`, the Mac tool (Python 3.12+, uv): audit, import, diff, apply, rollback |
| `backend/` | Cloudflare Worker + D1 + R2 (`docs/api.md`, `docs/backend.md`) |
| `ios/` | iPhone app (SwiftUI, iOS 26) and `MyTagsKit` (pure Swift domain logic) |
| `shared/` | Default field configuration and test vectors shared by Python and Swift |

## Absolute rules (spec section 0 — never break them)

- **R1** Never modify, move, rename or delete a file of the music library without an explicit
  command from the user ("applique", "annule"). Only `djtag apply` and `djtag rollback` write audio files.
- **R2** Every write is preceded by a backup and followed by a full verification (built into `djtag apply`).
- **R3** Only GENRE, GROUPING, COMMENT and the rating change; every other tag (Serato cue points,
  beatgrids, loops, colors, overview) stays byte-identical.
- **R4** Never write into the real library before the write was validated on a copy.
- **R5** No secret and no audio file in the repository.
- **R6** Never write tags while Serato DJ is open (`djtag apply` refuses, exit code 3).
- **R7** An edit shown as done in the app is already stored on the phone.
- **R8** No useless text in the UI.

Never run shell commands that touch the music folders yourself (`cp`, `mv`, `rm`, `ffmpeg -y`,
mutagen scripts…): always go through `djtag`. Never write into a `_Serato_` folder.

## djtag commands

Run from `mac-cli/` with `uv run djtag …` (or `djtag` if installed with `uv tool install`).
Every command accepts `--json`. Exit codes: 0 ok, 1 error, 2 conflicts, 3 safety refusal.

| Command | Writes audio files |
| --- | --- |
| `djtag doctor` — tools, cloud, disk, Serato closed | No |
| `djtag audit [--summary docs/audit.md]` — read-only library report | No |
| `djtag import [--limit N]` — new/changed files to the cloud | No |
| `djtag status` / `djtag diff [--markdown f.md]` — what would be written | No |
| `djtag apply [--dry-run] [--yes] [--limit N] [--track ID]` — write, with backup + verification | **Yes** |
| `djtag rollback <run-id> [--track ID]` — restore the files of an application | **Yes** |
| `djtag resolve <ids…> --keep-file / --keep-app [--all]` — settle conflicts in the database | No |
| `djtag pair`, `djtag devices list/revoke`, `djtag backup-db`, `djtag prune-backups` | No |

To apply the tags tagged on the phone, use the `appliquer-tags` skill ("applique mes tags du train").

## Development

- CLI: `cd mac-cli && uv run ruff check src tests && uv run pyright && uv run pytest -q`
  (needs `ffmpeg` and `fpcalc`).
- Backend: `cd backend && npm ci && npm run typecheck && npm test`.
- Swift domain: `cd ios/MyTagsKit && swift test` (or Docker `swift:6.2-noble`).
- iOS app: open `ios/MyTags.xcodeproj` in Xcode 26; CI builds it on macOS (`.github/workflows/ci-ios.yml`).
- Tag-model algorithms are implemented twice (Python and Swift): change both and add a case to
  `shared/test-vectors/tag-model.json`.
- Any change to `apply`, `rollback`, the sync engine or local writes gets reviewed by a separate agent.
