import Foundation

/// A saved library view (`saved_views` table).
public struct SavedView: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var filters: LibraryFilter
    public var sort: LibrarySort
    /// "Skip tracks that are already complete" when tagging from this view.
    public var skipComplete: Bool
    public var position: Int
    public var builtin: Bool
    public var updatedAt: String
    public var deletedAt: String?
    public var rev: Int?

    public init(
        id: String,
        name: String,
        filters: LibraryFilter = LibraryFilter(),
        sort: LibrarySort = .default,
        skipComplete: Bool = false,
        position: Int = 0,
        builtin: Bool = false,
        updatedAt: String = "",
        deletedAt: String? = nil,
        rev: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.filters = filters
        self.sort = sort
        self.skipComplete = skipComplete
        self.position = position
        self.builtin = builtin
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
    }

    public var isDeleted: Bool { deletedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, filters, sort
        case skipComplete = "skip_complete"
        case position, builtin
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case rev
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name, default: "")
        filters = try c.lenientJSON(LibraryFilter.self, forKey: .filters) ?? LibraryFilter()
        sort = try c.lenientJSON(LibrarySort.self, forKey: .sort) ?? .default
        skipComplete = try c.lenientBool(.skipComplete, default: false)
        position = try c.decode(Int.self, forKey: .position, default: 0)
        builtin = try c.lenientBool(.builtin, default: false)
        updatedAt = try c.decode(String.self, forKey: .updatedAt, default: "")
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(filters, forKey: .filters)
        try c.encode(sort, forKey: .sort)
        try c.encode(skipComplete, forKey: .skipComplete)
        try c.encode(position, forKey: .position)
        try c.encode(builtin, forKey: .builtin)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(rev, forKey: .rev)
    }
}

/// A shared setting (`settings` table). `value` is arbitrary JSON.
public struct SettingRow: Codable, Hashable, Sendable {
    public var key: String
    public var value: JSONValue
    public var updatedAt: String
    public var deletedAt: String?
    public var rev: Int?

    public init(key: String, value: JSONValue, updatedAt: String = "", deletedAt: String? = nil, rev: Int? = nil) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
    }

    public var isDeleted: Bool { deletedAt != nil }

    enum CodingKeys: String, CodingKey {
        case key, value
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case rev
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        value = try c.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        updatedAt = try c.decode(String.self, forKey: .updatedAt, default: "")
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(value, forKey: .value)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(rev, forKey: .rev)
    }
}

/// A complete configuration, in the shape of `shared/default-config.json`
/// and of `POST /v1/admin/config/reset`.
public struct ConfigDocument: Codable, Hashable, Sendable {
    public var version: Int?
    public var fields: [Field]
    public var fieldOptions: [FieldOption]
    public var rules: [Rule]
    public var savedViews: [SavedView]
    public var settings: [SettingRow]

    public init(
        version: Int? = nil,
        fields: [Field] = [],
        fieldOptions: [FieldOption] = [],
        rules: [Rule] = [],
        savedViews: [SavedView] = [],
        settings: [SettingRow] = []
    ) {
        self.version = version
        self.fields = fields
        self.fieldOptions = fieldOptions
        self.rules = rules
        self.savedViews = savedViews
        self.settings = settings
    }

    /// Decodes a configuration document.
    public static func decode(from data: Data) throws -> ConfigDocument {
        try JSONDecoder().decode(ConfigDocument.self, from: data)
    }

    enum CodingKeys: String, CodingKey {
        case version, fields
        case fieldOptions = "field_options"
        case rules
        case savedViews = "saved_views"
        case settings
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version)
        fields = try c.decode([Field].self, forKey: .fields, default: [])
        fieldOptions = try c.decode([FieldOption].self, forKey: .fieldOptions, default: [])
        rules = try c.decode([Rule].self, forKey: .rules, default: [])
        savedViews = try c.decode([SavedView].self, forKey: .savedViews, default: [])
        settings = try c.decode([SettingRow].self, forKey: .settings, default: [])
    }
}
