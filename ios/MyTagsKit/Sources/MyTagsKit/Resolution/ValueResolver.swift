import Foundation

/// Inputs for phone-side suggestions. Passing `nil` to ``ValueResolver`` disables suggestions.
public struct SuggestionContext: Sendable {
    /// Statistics for artist suggestions; `nil` disables them.
    public var artistStats: ArtistStats?

    public init(artistStats: ArtistStats? = nil) {
        self.artistStats = artistStats
    }
}

/// State of a resolved field.
public enum ResolvedState: String, Hashable, Sendable {
    /// From a `track_values` row or from the file.
    case confirmed
    /// Proposed by a rule, the artist or the default value; never written until validated.
    case suggested
    case empty
}

/// The value of one field for one track (`docs/modele-tags.md`, section 6).
public struct ResolvedField: Hashable, Sendable {
    public let fieldID: String
    public var value: FieldValue
    public var state: ResolvedState
    /// Row source, `.file`, or the suggestion source; `nil` when empty without a row.
    public var source: ValueSource?
    /// A non-deleted `track_values` row exists (it may be empty: "cleared on purpose").
    public var hasRow: Bool
    /// GENRE / GROUPING text found in the file but not recognised ("GENRE actuel : …").
    public var unknownFileText: String?
    /// The COMMENT position was read as the empty token.
    public var isExplicitlyEmptyInFile: Bool

    public init(
        fieldID: String, value: FieldValue = .empty, state: ResolvedState = .empty, source: ValueSource? = nil,
        hasRow: Bool = false, unknownFileText: String? = nil, isExplicitlyEmptyInFile: Bool = false
    ) {
        self.fieldID = fieldID
        self.value = value
        self.state = state
        self.source = source
        self.hasRow = hasRow
        self.unknownFileText = unknownFileText
        self.isExplicitlyEmptyInFile = isExplicitlyEmptyInFile
    }

    public var isConfirmed: Bool { state == .confirmed }
    public var isSuggested: Bool { state == .suggested }
}

/// Every field of a track, resolved.
public struct ResolvedTrack: Hashable, Sendable {
    public let trackID: String
    public let fileFormat: String
    public let baseline: Baseline?
    /// Resolved fields by field id (every non-deleted field of the configuration).
    public let fields: [String: ResolvedField]
    /// Values deduced from the baseline.
    public let fileValues: FileValues
    /// Values of the non-deleted rows, by field id, as stored.
    public let rowValues: [String: FieldValue]
    /// Sources of the non-deleted rows, by field id.
    public let rowSources: [String: ValueSource]
    /// Suggestions coming from rules in "apply" mode, by field id. The app writes them as
    /// confirmed values (source `rule`) after a user action on the track, and at validation.
    public let applyModeRuleValues: [String: FieldValue]

    public subscript(fieldID: String) -> ResolvedField? {
        fields[fieldID]
    }

    /// Reading status of the baseline COMMENT.
    public var commentStatus: CommentStatus { fileValues.comment.status }

    /// The baseline COMMENT text, shown when it is not conforming ("COMMENT actuel : …").
    public var commentText: String? { baseline?.comment }

    /// Confirmed, non-empty values by field id.
    public var confirmedValues: [String: FieldValue] {
        fields.compactMapValues { $0.state == .confirmed ? $0.value : nil }
    }

    /// At least one row comes from an accepted suggestion (default, rule, artist, title).
    public var hasAcceptedSuggestions: Bool {
        rowSources.values.contains(where: \.isSuggestionSource)
    }

    /// Target tags for the file (section 7).
    public func targets(config: TagConfig) -> Baseline {
        TargetCalculator.targets(
            format: fileFormat, baseline: baseline, rows: rowValues, commentParse: fileValues.comment, config: config)
    }

    /// `true` when a target tag differs from the baseline.
    public func isToApply(config: TagConfig) -> Bool {
        !TargetCalculator.differingTags(targets(config: config), from: baseline).isEmpty
    }
}

/// Resolves the effective value of every field (`docs/modele-tags.md`, sections 6 and 9).
public enum ValueResolver {
    /// Resolves a track: row, then file, then (with a context) suggestion, then empty.
    ///
    /// Suggestions (never for rating fields, nor for fields with a row or a confirmed value):
    /// 1. enabled rules in order, the first matching rule per field wins. `field_equals` tests
    ///    whether the confirmed value, or the suggestion of an earlier rule, contains the option;
    ///    `title_contains` tests the title. Source: `title` for title rules, `rule` otherwise and
    ///    for every rule in "apply" mode;
    /// 2. the artist value (``ArtistStats``) for artist-level fields, source `artist`;
    /// 3. the field's default option, source `default`.
    /// Suggestions never use archived options.
    ///
    /// - Parameter rows: the track's `track_values` rows; deleted rows and rows of other tracks
    ///   are ignored.
    public static func resolve(
        track: Track, rows: [TrackValue], config: TagConfig, suggestionContext: SuggestionContext?
    ) -> ResolvedTrack {
        let fileValues = FileValueReader.read(baseline: track.baseline, config: config)
        let activeRows = TrackValue.activeRows(rows.filter { $0.trackID == track.id })

        var fields = [String: ResolvedField](minimumCapacity: config.fields.count)
        var confirmed = [String: FieldValue](minimumCapacity: config.fields.count)
        for field in config.fields {
            var resolved = ResolvedField(
                fieldID: field.id,
                unknownFileText: fileValues.unknownTexts[field.id],
                isExplicitlyEmptyInFile: fileValues.comment.explicitEmpty.contains(field.id))
            if let row = activeRows[field.id] {
                let value = config.normalized(row.value, for: field)
                resolved.value = value
                resolved.state = value.isEmpty ? .empty : .confirmed
                resolved.source = row.source
                resolved.hasRow = true
            } else if let fileValue = fileValues.values[field.id] {
                let value = config.normalized(fileValue, for: field)
                if !value.isEmpty {
                    resolved.value = value
                    resolved.state = .confirmed
                    resolved.source = .file
                }
            }
            if resolved.state == .confirmed { confirmed[field.id] = resolved.value }
            fields[field.id] = resolved
        }

        var applyMode: [String: FieldValue] = [:]
        if let context = suggestionContext {
            let suggestions = suggest(
                track: track, config: config, context: context, confirmed: confirmed,
                rowFieldIDs: Set(activeRows.keys), applyMode: &applyMode)
            for (fieldID, suggestion) in suggestions {
                fields[fieldID]?.value = suggestion.value
                fields[fieldID]?.state = .suggested
                fields[fieldID]?.source = suggestion.source
            }
        }

        return ResolvedTrack(
            trackID: track.id,
            fileFormat: track.fileFormat,
            baseline: track.baseline,
            fields: fields,
            fileValues: fileValues,
            rowValues: activeRows.mapValues(\.value),
            rowSources: activeRows.mapValues(\.source),
            applyModeRuleValues: applyMode)
    }

    /// Confirmed, non-empty values (rows, then file) by field id, without suggestions.
    public static func confirmedValues(track: Track, rows: [TrackValue], config: TagConfig) -> [String: FieldValue] {
        resolve(track: track, rows: rows, config: config, suggestionContext: nil).confirmedValues
    }

    private static func suggest(
        track: Track, config: TagConfig, context: SuggestionContext, confirmed: [String: FieldValue],
        rowFieldIDs: Set<String>, applyMode: inout [String: FieldValue]
    ) -> [String: (value: FieldValue, source: ValueSource)] {
        var suggested: [String: (value: FieldValue, source: ValueSource)] = [:]

        func isOpen(_ field: Field) -> Bool {
            field.kind != .rating && !rowFieldIDs.contains(field.id) && confirmed[field.id] == nil
                && suggested[field.id] == nil
        }
        func selectable(_ optionID: String, in field: Field) -> Bool {
            guard field.kind == .single || field.kind == .multi, let option = config.option(id: optionID) else {
                return false
            }
            return option.fieldID == field.id && !option.archived
        }

        var titleWords: [[Unicode.Scalar]]?
        for rule in config.activeRules {
            guard let field = config.field(id: rule.action.fieldID), isOpen(field),
                selectable(rule.action.optionID, in: field)
            else { continue }
            let holds: Bool
            let source: ValueSource
            switch rule.condition {
            case .fieldEquals(let fieldID, let optionID):
                let effective = confirmed[fieldID] ?? suggested[fieldID]?.value
                holds = effective?.optionIDs.contains(optionID) ?? false
                source = .rule
            case .titleContains(let patterns):
                let words = titleWords ?? TitleMatcher.words(track.title ?? "")
                titleWords = words
                holds = TitleMatcher.containsAny(titleWords: words, patterns: patterns)
                source = rule.mode == .apply ? .rule : .title
            case .unknown:
                holds = false
                source = .rule
            }
            guard holds else { continue }
            let value = FieldValue.option(rule.action.optionID)
            suggested[field.id] = (value, source)
            if rule.mode == .apply { applyMode[field.id] = value }
        }

        let artistKey = ArtistStats.artistKey(for: track.artist)
        for field in config.fields where isOpen(field) {
            if field.artistLevel, let stats = context.artistStats,
                let value = stats.suggestion(fieldID: field.id, artistKey: artistKey, excludingTrackID: track.id, config: config)
            {
                suggested[field.id] = (value, .artist)
            } else if let defaultID = field.defaultOptionID, selectable(defaultID, in: field) {
                suggested[field.id] = (.option(defaultID), .default)
            }
        }
        return suggested
    }
}
