import Foundation

/// Where a value comes from (`track_values.source`, `changes.source`).
public enum ValueSource: String, Codable, Hashable, Sendable, CaseIterable {
    case user, file, `default`, rule, artist, title

    /// Sources of suggestions; a row with one of them is an accepted suggestion.
    public var isSuggestionSource: Bool {
        switch self {
        case .default, .rule, .artist, .title: true
        case .user, .file: false
        }
    }
}

/// `track_values.state`. Rows are always written as confirmed (decision 0005).
public enum ValueState: String, Codable, Hashable, Sendable, CaseIterable {
    case confirmed, suggested
}

/// A value set from the app for one track and one field (`track_values` table).
public struct TrackValue: Codable, Hashable, Sendable {
    public var trackID: String
    public var fieldID: String
    /// Empty means "cleared on purpose".
    public var optionIDs: [String]
    public var rating: Int?
    public var textValue: String?
    public var state: ValueState
    public var source: ValueSource
    public var updatedAt: String
    public var deviceID: String?
    public var deletedAt: String?
    public var rev: Int?

    public init(
        trackID: String,
        fieldID: String,
        optionIDs: [String] = [],
        rating: Int? = nil,
        textValue: String? = nil,
        state: ValueState = .confirmed,
        source: ValueSource = .user,
        updatedAt: String = "",
        deviceID: String? = nil,
        deletedAt: String? = nil,
        rev: Int? = nil
    ) {
        self.trackID = trackID
        self.fieldID = fieldID
        self.optionIDs = optionIDs
        self.rating = rating
        self.textValue = textValue
        self.state = state
        self.source = source
        self.updatedAt = updatedAt
        self.deviceID = deviceID
        self.deletedAt = deletedAt
        self.rev = rev
    }

    /// Builds a row from a value.
    public init(
        trackID: String, fieldID: String, value: FieldValue, source: ValueSource = .user, updatedAt: String = "",
        deviceID: String? = nil
    ) {
        self.init(
            trackID: trackID, fieldID: fieldID, optionIDs: value.optionIDs, rating: value.rating,
            textValue: value.text, source: source, updatedAt: updatedAt, deviceID: deviceID)
    }

    public var isDeleted: Bool { deletedAt != nil }

    public var value: FieldValue {
        FieldValue(optionIDs: optionIDs, rating: rating, text: textValue)
    }

    /// Values of the non-deleted rows, by field id (the most recent row wins on duplicates).
    public static func activeValues(_ rows: [TrackValue]) -> [String: FieldValue] {
        activeRows(rows).mapValues(\.value)
    }

    /// Non-deleted rows by field id (the most recent row wins on duplicates).
    public static func activeRows(_ rows: [TrackValue]) -> [String: TrackValue] {
        var result: [String: TrackValue] = [:]
        for row in rows where row.deletedAt == nil {
            if let existing = result[row.fieldID], existing.updatedAt > row.updatedAt { continue }
            result[row.fieldID] = row
        }
        return result
    }

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case fieldID = "field_id"
        case optionIDs = "option_ids"
        case rating
        case textValue = "text_value"
        case state, source
        case updatedAt = "updated_at"
        case deviceID = "device_id"
        case deletedAt = "deleted_at"
        case rev
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try c.decode(String.self, forKey: .trackID)
        fieldID = try c.decode(String.self, forKey: .fieldID)
        optionIDs = try c.lenientJSON([String].self, forKey: .optionIDs) ?? []
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        textValue = try c.decodeIfPresent(String.self, forKey: .textValue)
        state = try c.decodeIfPresent(String.self, forKey: .state).flatMap(ValueState.init(rawValue:)) ?? .confirmed
        source = try c.decodeIfPresent(String.self, forKey: .source).flatMap(ValueSource.init(rawValue:)) ?? .user
        updatedAt = try c.decode(String.self, forKey: .updatedAt, default: "")
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(trackID, forKey: .trackID)
        try c.encode(fieldID, forKey: .fieldID)
        try c.encode(optionIDs, forKey: .optionIDs)
        try c.encode(rating, forKey: .rating)
        try c.encode(textValue, forKey: .textValue)
        try c.encode(state, forKey: .state)
        try c.encode(source, forKey: .source)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(rev, forKey: .rev)
    }
}
