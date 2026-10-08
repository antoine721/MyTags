import Foundation

/// Selection for one field: any of the options ("or"), or no confirmed value when `empty`.
public struct FieldFilter: Codable, Hashable, Sendable {
    public var options: [String]
    public var empty: Bool

    public init(options: [String] = [], empty: Bool = false) {
        self.options = options
        self.empty = empty
    }

    public var isActive: Bool { !options.isEmpty || empty }

    enum CodingKeys: String, CodingKey {
        case options, empty
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        options = try c.decode([String].self, forKey: .options, default: [])
        empty = try c.lenientBool(.empty, default: false)
    }
}

/// Flag filters of the library (`filters.special`).
public enum SpecialFilter: String, Codable, Hashable, Sendable, CaseIterable {
    case untagged
    case incomplete
    case commentNonConforme = "comment_non_conforme"
    case toApply = "to_apply"
    case offline
    case suggestionsAccepted = "suggestions_accepted"
    case conflictOrError = "conflict_or_error"
}

/// Library filters (`saved_views.filters`). Fields combine with "and", options of one field with "or".
public struct LibraryFilter: Codable, Hashable, Sendable {
    /// Selections by field id.
    public var fields: [String: FieldFilter]
    public var minRating: Int?
    public var bpmMin: Double?
    public var bpmMax: Double?
    /// Musical keys, matched exactly ("or").
    public var keys: [String]
    /// ``TrackStatus`` raw values ("or").
    public var statuses: [String]
    /// ``SpecialFilter`` raw values; all must hold ("and"). Unknown values are ignored.
    public var special: [String]
    /// Free text: every whitespace-separated term must appear in title, artist or album.
    public var search: String

    public init(
        fields: [String: FieldFilter] = [:],
        minRating: Int? = nil,
        bpmMin: Double? = nil,
        bpmMax: Double? = nil,
        keys: [String] = [],
        statuses: [String] = [],
        special: [String] = [],
        search: String = ""
    ) {
        self.fields = fields
        self.minRating = minRating
        self.bpmMin = bpmMin
        self.bpmMax = bpmMax
        self.keys = keys
        self.statuses = statuses
        self.special = special
        self.search = search
    }

    /// Known special filters, without duplicates, in input order.
    public var specialFilters: [SpecialFilter] {
        var seen = Set<SpecialFilter>()
        return special.compactMap(SpecialFilter.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    /// Number of removable filter chips: one per selected option, per field "empty", per key,
    /// per status and per known special filter, plus one for the minimum rating and one for the
    /// BPM range. The search text is not counted.
    public var activeCount: Int {
        var count = 0
        for filter in fields.values {
            count += Set(filter.options).count + (filter.empty ? 1 : 0)
        }
        if minRating != nil { count += 1 }
        if bpmMin != nil || bpmMax != nil { count += 1 }
        count += Set(keys).count + Set(statuses).count + specialFilters.count
        return count
    }

    /// No active filter and no search text.
    public var isEmpty: Bool {
        activeCount == 0 && search.unicodeScalars.allSatisfy(TextNormalizer.isWhitespace)
    }

    enum CodingKeys: String, CodingKey {
        case fields
        case minRating = "min_rating"
        case bpmMin = "bpm_min"
        case bpmMax = "bpm_max"
        case keys, statuses, special, search
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fields = try c.decode([String: FieldFilter].self, forKey: .fields, default: [:])
        minRating = try c.decodeIfPresent(Int.self, forKey: .minRating)
        bpmMin = try c.decodeIfPresent(Double.self, forKey: .bpmMin)
        bpmMax = try c.decodeIfPresent(Double.self, forKey: .bpmMax)
        keys = try c.decode([String].self, forKey: .keys, default: [])
        statuses = try c.decode([String].self, forKey: .statuses, default: [])
        special = try c.decode([String].self, forKey: .special, default: [])
        search = try c.decode(String.self, forKey: .search, default: "")
    }

    /// Encodes only what is set, so `{"special": ["incomplete"]}` round-trips unchanged.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let activeFields = fields.filter { $0.value.isActive }
        if !activeFields.isEmpty { try c.encode(activeFields, forKey: .fields) }
        try c.encodeIfPresent(minRating, forKey: .minRating)
        try c.encodeIfPresent(bpmMin, forKey: .bpmMin)
        try c.encodeIfPresent(bpmMax, forKey: .bpmMax)
        if !keys.isEmpty { try c.encode(keys, forKey: .keys) }
        if !statuses.isEmpty { try c.encode(statuses, forKey: .statuses) }
        if !special.isEmpty { try c.encode(special, forKey: .special) }
        if !search.isEmpty { try c.encode(search, forKey: .search) }
    }
}

/// Library sort (`saved_views.sort`).
public struct LibrarySort: Codable, Hashable, Sendable {
    public enum Key: String, Codable, Hashable, Sendable, CaseIterable {
        case artist, title, bpm
        case addedAt = "added_at"
        case rating
    }

    public var key: Key
    public var ascending: Bool

    public init(key: Key = .artist, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    /// Artist, ascending.
    public static let `default` = LibrarySort()

    enum CodingKeys: String, CodingKey {
        case key, ascending
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decodeIfPresent(String.self, forKey: .key).flatMap(Key.init(rawValue:)) ?? .artist
        ascending = try c.lenientBool(.ascending, default: true)
    }
}
