import Foundation

/// `fields.kind`.
public enum FieldKind: String, Codable, Hashable, Sendable, CaseIterable {
    case single, multi, rating, text
}

/// `fields.target_tag`: the file tag a field is written to.
public enum TargetTag: String, Codable, Hashable, Sendable, CaseIterable {
    case genre = "GENRE"
    case grouping = "GROUPING"
    case comment = "COMMENT"
    case rating = "RATING"
}

/// A configurable field (`fields` table).
public struct Field: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var key: String
    public var name: String
    public var kind: FieldKind
    public var targetTag: TargetTag
    /// Position in the composed COMMENT (1-based); `nil` for other tags.
    public var targetSlot: Int?
    public var required: Bool
    public var visible: Bool
    public var position: Int
    public var defaultOptionID: String?
    public var isAdvanceTrigger: Bool
    public var artistLevel: Bool
    public var updatedAt: String
    public var deletedAt: String?
    public var rev: Int?

    public init(
        id: String,
        key: String,
        name: String? = nil,
        kind: FieldKind,
        targetTag: TargetTag,
        targetSlot: Int? = nil,
        required: Bool = false,
        visible: Bool = true,
        position: Int = 0,
        defaultOptionID: String? = nil,
        isAdvanceTrigger: Bool = false,
        artistLevel: Bool = false,
        updatedAt: String = "",
        deletedAt: String? = nil,
        rev: Int? = nil
    ) {
        self.id = id
        self.key = key
        self.name = name ?? key
        self.kind = kind
        self.targetTag = targetTag
        self.targetSlot = targetSlot
        self.required = required
        self.visible = visible
        self.position = position
        self.defaultOptionID = defaultOptionID
        self.isAdvanceTrigger = isAdvanceTrigger
        self.artistLevel = artistLevel
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
    }

    public var isDeleted: Bool { deletedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, key, name, kind
        case targetTag = "target_tag"
        case targetSlot = "target_slot"
        case required, visible, position
        case defaultOptionID = "default_option_id"
        case isAdvanceTrigger = "is_advance_trigger"
        case artistLevel = "artist_level"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case rev
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        key = try c.decode(String.self, forKey: .key)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? key
        kind = try c.decode(FieldKind.self, forKey: .kind)
        targetTag = try c.decode(TargetTag.self, forKey: .targetTag)
        targetSlot = try c.decodeIfPresent(Int.self, forKey: .targetSlot)
        required = try c.lenientBool(.required, default: false)
        visible = try c.lenientBool(.visible, default: true)
        position = try c.decode(Int.self, forKey: .position, default: 0)
        defaultOptionID = try c.decodeIfPresent(String.self, forKey: .defaultOptionID)
        isAdvanceTrigger = try c.lenientBool(.isAdvanceTrigger, default: false)
        artistLevel = try c.lenientBool(.artistLevel, default: false)
        updatedAt = try c.decode(String.self, forKey: .updatedAt, default: "")
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(key, forKey: .key)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(targetTag, forKey: .targetTag)
        try c.encode(targetSlot, forKey: .targetSlot)
        try c.encode(required, forKey: .required)
        try c.encode(visible, forKey: .visible)
        try c.encode(position, forKey: .position)
        try c.encode(defaultOptionID, forKey: .defaultOptionID)
        try c.encode(isAdvanceTrigger, forKey: .isAdvanceTrigger)
        try c.encode(artistLevel, forKey: .artistLevel)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(rev, forKey: .rev)
    }
}

/// A value of a field (`field_options` table).
public struct FieldOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var fieldID: String
    /// Text written to the file, exactly as defined.
    public var value: String
    /// Display text; ``displayLabel`` falls back to ``value``.
    public var label: String?
    public var color: String?
    /// Variants recognised when reading a file.
    public var aliases: [String]
    public var position: Int
    /// Retired but still recognised and resolvable.
    public var archived: Bool
    public var updatedAt: String
    public var deletedAt: String?
    public var rev: Int?

    public init(
        id: String,
        fieldID: String,
        value: String,
        label: String? = nil,
        color: String? = nil,
        aliases: [String] = [],
        position: Int = 0,
        archived: Bool = false,
        updatedAt: String = "",
        deletedAt: String? = nil,
        rev: Int? = nil
    ) {
        self.id = id
        self.fieldID = fieldID
        self.value = value
        self.label = label
        self.color = color
        self.aliases = aliases
        self.position = position
        self.archived = archived
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
    }

    public var isDeleted: Bool { deletedAt != nil }

    /// Text shown in the app.
    public var displayLabel: String {
        if let label, !label.isEmpty { return label }
        return value
    }

    /// Texts recognised for this option when reading a file: the value, then the aliases.
    public var candidates: [String] { [value] + aliases }

    enum CodingKeys: String, CodingKey {
        case id
        case fieldID = "field_id"
        case value, label, color, aliases, position, archived
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case rev
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fieldID = try c.decode(String.self, forKey: .fieldID)
        value = try c.decode(String.self, forKey: .value)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        aliases = try c.lenientJSON([String].self, forKey: .aliases) ?? []
        position = try c.decode(Int.self, forKey: .position, default: 0)
        archived = try c.lenientBool(.archived, default: false)
        updatedAt = try c.decode(String.self, forKey: .updatedAt, default: "")
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(fieldID, forKey: .fieldID)
        try c.encode(value, forKey: .value)
        try c.encode(label, forKey: .label)
        try c.encode(color, forKey: .color)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(position, forKey: .position)
        try c.encode(archived, forKey: .archived)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(rev, forKey: .rev)
    }
}
