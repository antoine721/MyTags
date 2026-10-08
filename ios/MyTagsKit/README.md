# MyTagsKit

The platform-independent domain package of the MyTags iPhone app: models of the API rows,
the tag model of `docs/modele-tags.md` (COMMENT reading and composition, target tags, ratings,
title patterns, primary artist), value resolution with suggestions, completeness, statuses,
library filtering and sorting, the tagging queue and change coalescing.

Foundation only (no Combine, SwiftUI, OSLog or CryptoKit), Swift 6 language mode, iOS 26 and
macOS 15. It builds and tests on Linux:

```sh
docker run --rm -v "$PWD":/src -w /src/ios/MyTagsKit swift:6.2-noble swift test
```

The tests run the shared vectors of `shared/test-vectors/tag-model.json` (also run by the Python
implementation in `mac-cli/`) and read `shared/default-config.json`; they find the repository root
from `#filePath`.

## Conventions

- Ids are lowercase UUID `String`s; timestamps are ISO 8601 `String`s (`Timestamp` formats the
  exact `2026-10-08T12:00:00.000Z` form the Worker requires).
- Every row model is `Codable` with explicit snake_case keys, `Hashable` and `Sendable`. Decoding is
  lenient where it costs nothing: missing columns take the schema defaults, booleans may be `0`/`1`,
  JSON columns may arrive as JSON text. Encoding writes full rows with explicit `null`s (`rev` only
  when set).
- Text comparisons of the tag model use Unicode scalars (code points), not Swift's canonical
  equivalence, so that results match Python exactly.

## Public API

| Area | Types and entry points |
| --- | --- |
| Rows | `Track`, `Baseline`, `ApplyStatus` (open set), `CommentStatus`, `Field` (`FieldKind`, `TargetTag`), `FieldOption`, `TrackValue` (`ValueSource`, `ValueState`), `Rule` (`RuleCondition`, `RuleAction`, `RuleMode`), `SavedView`, `SettingRow`, `ConfigDocument` (the `default-config.json` / `config/reset` shape), `JSONValue` |
| Configuration | `TagConfig(fields:options:rules:settings:)`, `TagConfig(document:)`, `TagConfig.load(fromDefaultConfigJSON:)`; `field(id:)`, `field(key:)`, `field(for: TargetTag)`, `option(id:)`, `options(forField:)`, `selectableOptions(forField:)`, `visibleFields`, `commentFields`, `commentField(atSlot:)`, `activeRules`, `separator`, `emptyToken`, `multiSeparator`, `ratingWriteFormats`, `normalized(_:for:)` |
| Values | `FieldValue {optionIDs, rating, text}` with `isEmpty`; also the `changes` value JSON shape |
| Text | `TextNormalizer.norm(_:)`, `.compact(_:)`, `.areEquivalent(_:_:)`, `.tagsEqual(_:_:)`; `TitleMatcher.contains(title:pattern:)`, `.containsAny(title:patterns:)`; `ArtistName.primary(_:)`, `.key(_:)` |
| Tag model | `CommentCodec.parse(_:config:) -> CommentParse {status, values, explicitEmpty}`, `CommentCodec.compose(values:config:)`; `FileValueReader.read(baseline:config:) -> FileValues {values, unknownTexts, comment}`, `FileValueReader.match(_:field:config:)`; `TargetCalculator.targets(format:baseline:rows:config:)`, `.isToApply(...)`, `.differingTags(_:from:)`; `RatingScale.stars(fromRaw:scheme:)`, `.starsFromPOPM(_:)`, `.starsFromGeneric(_:)`, `.popmValue(forStars:)` |
| Resolution | `ValueResolver.resolve(track:rows:config:suggestionContext:) -> ResolvedTrack` (per field `ResolvedField {value, state: confirmed/suggested/empty, source, hasRow, unknownFileText, isExplicitlyEmptyInFile}`, plus `commentStatus`, `commentText`, `applyModeRuleValues`, `hasAcceptedSuggestions`, `targets(config:)`, `isToApply(config:)`); `SuggestionContext(artistStats:)`; `ArtistStats` (build from tracks and rows, `setTrack`, `removeTrack`, `suggestion(fieldID:artistKey:excludingTrackID:config:)`) |
| Completeness | `Completeness.isIncomplete`, `.isUntagged`, `.missingRequiredFields`, `.isValidatable`; `ValidationPlan.make(resolved:config:)` → `[PlannedValue {fieldID, value, source}]`, `.pendingChanges(trackID:createdAt:makeID:)` |
| Status | `TrackStatus.compute(hasPendingLocalChanges:applyStatus:isToApply:)` → `modifie`, `conflit`, `erreur`, `envoye`, `applique`, `none` |
| Library | `TrackSnapshot` (memberwise init, `init(track:resolved:config:hasPendingLocalChanges:isOffline:)`, `build(track:rows:config:...)`), `LibraryFilter` (`FieldFilter`, `SpecialFilter`, `activeCount`), `LibrarySort`, `LibraryQuery.run(filter:sort:snapshots:) -> [String]`, `LibraryQuery.fold(_:)` |
| Queue | `TagQueue` (frozen ids, `currentIndex` in `0...count`, `next()`, `previous()`, `next(where:)`, `nextIndex(after:where:)`, `previousIndex(before:where:)`) |
| Sync | `PendingChange` (push shape), `ChangeCoalescer.coalesce(_:)`, `Timestamp.string(from:)`, `Timestamp.date(from:)` |

## Behaviour notes

Choices made where `docs/modele-tags.md` leaves room, aligned with the Python implementation
(`mac-cli/src/djtag/model/`) when it exists:

- **Ordering.** Fields by `(position, key)`, options by `(position, value)`, rules by `position`
  (input order on ties). A field's candidates are its options' `value` then `aliases`, in that order.
- **Settings.** A missing, deleted, empty or non-text `comment.separator`, `comment.empty_token` or
  `multi.separator` falls back to its default. `rating.write_formats` is compared exactly with
  `tracks.file_format`.
- **COMMENT positions.** Reading uses the COMMENT fields sorted by `target_slot` as positions;
  composition writes slots 1 to the largest slot, with the empty token for a slot without field.
  Fields of kind `text` or `rating` in the COMMENT only read the empty token and always compose as
  the empty token. On a full tie between readings, the first one found wins: candidates in option
  order, then the empty token, then skipping. Criterion 3 compares the whole text read at a position
  (a full multiple-choice sequence).
- **GENRE / GROUPING.** Only the first field (display order) targeting a tag is used. A
  multiple-choice text is split on `multi.separator`; an empty piece makes the text unknown. A
  baseline rating of `0` means no rating.
- **Rows.** A non-deleted `track_values` row is always confirmed, whatever its `state` column.
  Option ids that are deleted or belong to another field are dropped; a single-choice field keeps
  its first option in display order. A row with an empty value ("cleared on purpose") blocks the file
  value and suggestions, and counts as not confirmed for completeness.
- **Suggestions** (only with a `SuggestionContext`): never for rating fields, nor for fields that
  have a row or a confirmed value, and never with archived options. `field_equals` on a
  multiple-choice field means "contains". Sources: `title` for `title_contains` rules, `rule` for
  `field_equals` rules and for every rule in apply mode. Artist suggestions group tracks by
  `norm(primary artist)` (no suggestion when the artist is empty); the threshold is "at least half of
  the artist's other tracks", whether or not they have a value; ties go to the value whose options
  come first in display order.
- **Completeness.** `missingRequiredFields` (validation) checks required **and visible** fields, like
  "incomplete": a hidden field cannot be filled on the Tag screen.
- **Validation plan.** For each field without a row: its non-empty suggestion (with its source) or its
  file value (source `file`), the rating included.
- **Library.** Snapshots reflect confirmed values only. Field selections are "or" within a field
  (options and "empty"), "and" across fields; special filters are all required; unknown special
  values are ignored; `conflict_or_error` tests `apply_status`, not the composite status; musical
  keys match exactly. Sorting puts missing values last in both directions, then breaks ties by
  artist, title and id ascending. `activeCount` counts removable chips (one per option, "empty",
  key, status and special filter, one for the minimum rating, one for the BPM range).
- **Coalescing.** Per (track, field): the latest change (`createdAt`, then input order) with the
  earliest `oldValue`; results ordered by `createdAt`. No-op pairs are kept.

## Performance

Measured on Linux x86-64 in Docker: `LibraryQuery.run` over 5,000 snapshots takes about 15 ms per
query in a debug build. Building 5,000 snapshots takes about 0.17 s in release (about 0.6 s in
debug), and `ArtistStats` over 5,000 tracks about 0.1 s; both can run off the main thread and be
updated incrementally per track.
