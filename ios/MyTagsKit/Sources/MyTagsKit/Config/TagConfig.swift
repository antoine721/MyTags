import Foundation

/// A recognised text of an option, normalised (``TextNormalizer/norm(_:)``) as scalars.
struct Candidate: Hashable, Sendable {
    let scalars: [Unicode.Scalar]
    let optionID: String
}

struct OptionIndex: Hashable, Sendable {
    let fieldID: String
    let rank: Int
}

/// The resolved configuration: fields, options, rules and shared settings with fast lookups.
///
/// Soft-deleted rows are ignored. Archived options stay resolvable and recognised.
/// Fields are ordered by `(position, key)`, options by `(position, value)`, rules by `position`
/// (input order on ties), like the Mac tool.
public struct TagConfig: Sendable {
    public static let defaultSeparator = " "
    public static let defaultEmptyToken = "()"
    public static let defaultMultiSeparator = "/"
    public static let defaultRatingWriteFormats = ["mp3", "wav", "aiff"]

    /// Non-deleted fields in display order.
    public let fields: [Field]
    /// Non-deleted rules in evaluation order (enabled or not).
    public let rules: [Rule]
    /// Non-deleted settings by key.
    public let settings: [String: JSONValue]
    /// `comment.separator` (default `" "`).
    public let separator: String
    /// `comment.empty_token` (default `"()"`).
    public let emptyToken: String
    /// `multi.separator` (default `"/"`).
    public let multiSeparator: String
    /// `rating.write_formats` (default mp3, wav, aiff).
    public let ratingWriteFormats: [String]
    /// Fields targeting the COMMENT, ordered by `target_slot`: the positions read by ``CommentCodec``.
    public let commentFields: [Field]
    /// Number of COMMENT positions written by ``CommentCodec/compose(values:config:)``: the largest slot.
    public let commentSlotCount: Int

    private let fieldIndexByID: [String: Int]
    private let fieldIndexByKey: [String: Int]
    private let optionsByID: [String: FieldOption]
    private let optionsByField: [String: [FieldOption]]
    /// Option id to its field id and display rank, without copying whole rows.
    private let optionIndex: [String: OptionIndex]
    private let tagFieldIDs: [TargetTag: String]
    /// Slot number to the field written at that slot.
    let commentSlotFieldIDs: [Int: String]
    /// Recognised texts per field id, in option order (value, then aliases).
    let candidatesByField: [String: [Candidate]]
    /// Candidates of each COMMENT position (``commentFields`` order).
    let commentCandidates: [[Candidate]]
    /// Whether a COMMENT position has a candidate equal to the empty token.
    let commentEmptyIsOption: [Bool]
    let separatorScalars: [Unicode.Scalar]
    let multiSeparatorScalars: [Unicode.Scalar]
    let emptyTokenScalars: [Unicode.Scalar]

    /// Builds a configuration from rows (deleted rows are dropped).
    public init(fields: [Field], options: [FieldOption], rules: [Rule] = [], settings: [SettingRow] = []) {
        var values: [String: JSONValue] = [:]
        for row in settings where row.deletedAt == nil {
            values[row.key] = row.value
        }
        self.init(fields: fields, options: options, rules: rules, settingValues: values)
    }

    /// Builds a configuration from rows and a settings dictionary.
    public init(fields: [Field], options: [FieldOption], rules: [Rule] = [], settingValues: [String: JSONValue]) {
        let emptyTokenSetting = Self.stringSetting(settingValues, "comment.empty_token", Self.defaultEmptyToken)
        let liveFields = fields.filter { $0.deletedAt == nil }.sorted { lhs, rhs in
            lhs.position != rhs.position ? lhs.position < rhs.position : Self.precedes(lhs.key, rhs.key)
        }
        self.fields = liveFields

        var byID: [String: Int] = [:]
        var byKey: [String: Int] = [:]
        for (index, field) in liveFields.enumerated() {
            if byID[field.id] == nil { byID[field.id] = index }
            if byKey[field.key] == nil { byKey[field.key] = index }
        }
        fieldIndexByID = byID
        fieldIndexByKey = byKey

        var grouped: [String: [FieldOption]] = [:]
        var optionMap: [String: FieldOption] = [:]
        for option in options where option.deletedAt == nil && byID[option.fieldID] != nil {
            optionMap[option.id] = option
            grouped[option.fieldID, default: []].append(option)
        }
        var index: [String: OptionIndex] = [:]
        var candidates: [String: [Candidate]] = [:]
        for (fieldID, list) in grouped {
            let sorted = list.sorted { lhs, rhs in
                lhs.position != rhs.position ? lhs.position < rhs.position : Self.precedes(lhs.value, rhs.value)
            }
            grouped[fieldID] = sorted
            var fieldCandidates: [Candidate] = []
            for (rank, option) in sorted.enumerated() {
                index[option.id] = OptionIndex(fieldID: fieldID, rank: rank)
                for text in option.candidates {
                    let normalized = TextNormalizer.scalars(TextNormalizer.norm(text))
                    if !normalized.isEmpty {
                        fieldCandidates.append(Candidate(scalars: normalized, optionID: option.id))
                    }
                }
            }
            candidates[fieldID] = fieldCandidates
        }
        optionsByID = optionMap
        optionsByField = grouped
        optionIndex = index
        candidatesByField = candidates

        var tagFields: [TargetTag: String] = [:]
        for field in liveFields where field.targetTag != .comment && tagFields[field.targetTag] == nil {
            tagFields[field.targetTag] = field.id
        }
        tagFieldIDs = tagFields

        // Stable sort by slot over the display order.
        let comment = liveFields.enumerated()
            .filter { $0.element.targetTag == .comment && $0.element.targetSlot != nil }
            .sorted { lhs, rhs in
                let left = lhs.element.targetSlot ?? 0
                let right = rhs.element.targetSlot ?? 0
                return left != right ? left < right : lhs.offset < rhs.offset
            }
            .map(\.element)
        commentFields = comment
        var slotFields: [Int: String] = [:]
        for field in comment {
            if let slot = field.targetSlot, slot >= 1 { slotFields[slot] = field.id }
        }
        commentSlotFieldIDs = slotFields
        commentSlotCount = slotFields.keys.max() ?? 0
        let tokenScalars = TextNormalizer.scalars(TextNormalizer.norm(emptyTokenSetting))
        let slotCandidates = comment.map { candidates[$0.id] ?? [] }
        commentCandidates = slotCandidates
        commentEmptyIsOption = slotCandidates.map { list in list.contains { $0.scalars == tokenScalars } }

        self.rules = rules.enumerated()
            .filter { $0.element.deletedAt == nil }
            .sorted { lhs, rhs in
                lhs.element.position != rhs.element.position
                    ? lhs.element.position < rhs.element.position : lhs.offset < rhs.offset
            }
            .map(\.element)

        settings = settingValues
        separator = Self.stringSetting(settingValues, "comment.separator", Self.defaultSeparator)
        emptyToken = emptyTokenSetting
        multiSeparator = Self.stringSetting(settingValues, "multi.separator", Self.defaultMultiSeparator)
        if let formats = settingValues["rating.write_formats"]?.arrayValue {
            ratingWriteFormats = formats.compactMap { item in
                if let text = item.stringValue { return text }
                if let number = item.intValue { return String(number) }
                return nil
            }
        } else {
            ratingWriteFormats = Self.defaultRatingWriteFormats
        }
        separatorScalars = TextNormalizer.scalars(TextNormalizer.compact(separator).uppercased())
        multiSeparatorScalars = TextNormalizer.scalars(TextNormalizer.compact(multiSeparator).uppercased())
        emptyTokenScalars = tokenScalars
    }

    /// Builds a configuration from a full configuration document.
    public init(document: ConfigDocument) {
        self.init(
            fields: document.fields, options: document.fieldOptions, rules: document.rules,
            settings: document.settings)
    }

    /// Loads a configuration in the format of `shared/default-config.json`.
    public static func load(fromDefaultConfigJSON data: Data) throws -> TagConfig {
        TagConfig(document: try ConfigDocument.decode(from: data))
    }

    // MARK: Lookups

    public func field(id: String) -> Field? {
        fieldIndexByID[id].map { fields[$0] }
    }

    public func field(key: String) -> Field? {
        fieldIndexByKey[key].map { fields[$0] }
    }

    /// The field written to GENRE, GROUPING or RATING (the first one in display order).
    public func field(for tag: TargetTag) -> Field? {
        tagFieldIDs[tag].flatMap { field(id: $0) }
    }

    /// The field written at a COMMENT slot (1-based), if any.
    public func commentField(atSlot slot: Int) -> Field? {
        commentSlotFieldIDs[slot].flatMap { field(id: $0) }
    }

    /// Fields shown on the Tag screen, in display order.
    public var visibleFields: [Field] {
        fields.filter(\.visible)
    }

    /// Enabled rules in evaluation order.
    public var activeRules: [Rule] {
        rules.filter(\.enabled)
    }

    /// Any non-deleted option, archived ones included.
    public func option(id: String) -> FieldOption? {
        optionsByID[id]
    }

    /// Options of a field in display order, archived ones included.
    public func options(forField fieldID: String) -> [FieldOption] {
        optionsByField[fieldID] ?? []
    }

    /// Options offered for selection: non-archived, in display order.
    public func selectableOptions(forField fieldID: String) -> [FieldOption] {
        options(forField: fieldID).filter { !$0.archived }
    }

    /// The option of a field whose `value` is exactly `value`.
    public func option(fieldID: String, value: String) -> FieldOption? {
        options(forField: fieldID).first { $0.value == value }
    }

    /// The setting value for `key`, if present and not deleted.
    public func setting(_ key: String) -> JSONValue? {
        settings[key]
    }

    /// `true` when ratings are written for this file format (`rating.write_formats`).
    public func writesRating(format: String) -> Bool {
        ratingWriteFormats.contains(format)
    }

    // MARK: Values

    /// Keeps the options that belong to the field, without duplicates, in display order.
    public func sortedOptionIDs(_ optionIDs: [String], forField fieldID: String) -> [String] {
        if optionIDs.count == 1, let id = optionIDs.first {
            return optionIndex[id]?.fieldID == fieldID ? optionIDs : []
        }
        var ranked: [(rank: Int, id: String)] = []
        ranked.reserveCapacity(optionIDs.count)
        for id in optionIDs {
            guard let entry = optionIndex[id], entry.fieldID == fieldID, !ranked.contains(where: { $0.id == id }) else {
                continue
            }
            ranked.append((entry.rank, id))
        }
        return ranked.sorted { $0.rank < $1.rank }.map(\.id)
    }

    /// The part of a value that is meaningful for the field's kind, with options cleaned up
    /// (a single-choice field keeps its first option in display order).
    public func normalized(_ value: FieldValue, for field: Field) -> FieldValue {
        switch field.kind {
        case .single:
            let ids = sortedOptionIDs(value.optionIDs, forField: field.id)
            return FieldValue(optionIDs: ids.first.map { [$0] } ?? [])
        case .multi:
            return FieldValue(optionIDs: sortedOptionIDs(value.optionIDs, forField: field.id))
        case .rating:
            return FieldValue(rating: value.rating)
        case .text:
            return FieldValue(text: value.text)
        }
    }

    /// Display-order rank of an option within its field.
    func rank(ofOption optionID: String) -> Int {
        optionIndex[optionID]?.rank ?? Int.max
    }

    /// Deterministic ordering of two values of the same field (option ranks, then text).
    func precedes(_ lhs: FieldValue, _ rhs: FieldValue) -> Bool {
        let left = lhs.optionIDs.map(rank(ofOption:))
        let right = rhs.optionIDs.map(rank(ofOption:))
        if left != right { return left.lexicographicallyPrecedes(right) }
        if lhs.optionIDs != rhs.optionIDs { return lhs.optionIDs.lexicographicallyPrecedes(rhs.optionIDs) }
        return Self.precedes(lhs.text ?? "", rhs.text ?? "")
    }

    /// Code point ordering, like Python string comparison.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
    }

    private static func stringSetting(_ settings: [String: JSONValue], _ key: String, _ fallback: String) -> String {
        guard let value = settings[key]?.stringValue, !value.isEmpty else { return fallback }
        return value
    }
}
