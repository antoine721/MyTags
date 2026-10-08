import Foundation

/// A local journal entry waiting to be sent (`POST /v1/sync/push`, `changes[]`).
///
/// `newValue == nil` deletes the row: the track goes back to its file value.
public struct PendingChange: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var trackID: String
    public var fieldID: String
    public var oldValue: FieldValue?
    public var newValue: FieldValue?
    public var source: ValueSource
    /// ISO 8601 UTC with milliseconds.
    public var createdAt: String

    public init(
        id: String, trackID: String, fieldID: String, oldValue: FieldValue?, newValue: FieldValue?,
        source: ValueSource = .user, createdAt: String
    ) {
        self.id = id
        self.trackID = trackID
        self.fieldID = fieldID
        self.oldValue = oldValue
        self.newValue = newValue
        self.source = source
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case trackID = "track_id"
        case fieldID = "field_id"
        case oldValue = "old_value"
        case newValue = "new_value"
        case source
        case createdAt = "created_at"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        trackID = try c.decode(String.self, forKey: .trackID)
        fieldID = try c.decode(String.self, forKey: .fieldID)
        oldValue = try c.lenientJSON(FieldValue.self, forKey: .oldValue)
        newValue = try c.lenientJSON(FieldValue.self, forKey: .newValue)
        source = try c.decode(ValueSource.self, forKey: .source, default: .user)
        createdAt = try c.decode(String.self, forKey: .createdAt)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(trackID, forKey: .trackID)
        try c.encode(fieldID, forKey: .fieldID)
        try c.encode(oldValue, forKey: .oldValue)
        try c.encode(newValue, forKey: .newValue)
        try c.encode(source, forKey: .source)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// Merges pending changes before sending: one change per (track, field).
public enum ChangeCoalescer {
    /// Keeps, per (track, field), the latest change (`id`, `newValue`, `source`, `createdAt`) with
    /// the earliest change's `oldValue`. "Latest" compares `createdAt`, then input order.
    /// The result is ordered by `createdAt`, then input order.
    public static func coalesce(_ changes: [PendingChange]) -> [PendingChange] {
        struct Key: Hashable {
            let trackID: String
            let fieldID: String
        }
        struct Group {
            var latest: PendingChange
            var latestIndex: Int
            var earliest: PendingChange
        }
        var groups: [Key: Group] = [:]
        for (index, change) in changes.enumerated() {
            let key = Key(trackID: change.trackID, fieldID: change.fieldID)
            guard var group = groups[key] else {
                groups[key] = Group(latest: change, latestIndex: index, earliest: change)
                continue
            }
            if change.createdAt >= group.latest.createdAt {
                group.latest = change
                group.latestIndex = index
            }
            if change.createdAt < group.earliest.createdAt { group.earliest = change }
            groups[key] = group
        }
        return groups.values
            .sorted { lhs, rhs in
                lhs.latest.createdAt != rhs.latest.createdAt
                    ? lhs.latest.createdAt < rhs.latest.createdAt : lhs.latestIndex < rhs.latestIndex
            }
            .map { group in
                var merged = group.latest
                merged.oldValue = group.earliest.oldValue
                return merged
            }
    }
}
