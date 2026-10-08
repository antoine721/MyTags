import Foundation

/// `rules.mode`.
public enum RuleMode: String, Codable, Hashable, Sendable, CaseIterable {
    /// The action is shown as a suggestion.
    case suggest
    /// The action is written as a confirmed value (source `rule`) after a user action on the track.
    case apply
}

/// `rules.condition`.
public enum RuleCondition: Hashable, Sendable {
    /// The effective value of `fieldID` contains `optionID`.
    case fieldEquals(fieldID: String, optionID: String)
    /// The title contains one of the patterns (``TitleMatcher``).
    case titleContains(patterns: [String])
    /// A condition this version does not understand; it never matches and round-trips unchanged.
    case unknown(JSONValue)

    /// Interprets the JSON stored in `rules.condition`.
    public init(json: JSONValue) {
        let type = json["type"]?.stringValue
        if type == "field_equals", let fieldID = json["field_id"]?.stringValue,
            let optionID = json["option_id"]?.stringValue
        {
            self = .fieldEquals(fieldID: fieldID, optionID: optionID)
        } else if type == "title_contains", let items = json["patterns"]?.arrayValue {
            self = .titleContains(patterns: items.compactMap(\.stringValue))
        } else {
            self = .unknown(json)
        }
    }

    /// The JSON stored in `rules.condition`.
    public var json: JSONValue {
        switch self {
        case .fieldEquals(let fieldID, let optionID):
            ["type": "field_equals", "field_id": .string(fieldID), "option_id": .string(optionID)]
        case .titleContains(let patterns):
            ["type": "title_contains", "patterns": .array(patterns.map(JSONValue.string))]
        case .unknown(let json):
            json
        }
    }
}

extension RuleCondition: Codable {
    public init(from decoder: any Decoder) throws {
        var json = try JSONValue(from: decoder)
        if case .string(let text) = json, let parsed = try? JSONValue(jsonData: Data(text.utf8)) {
            json = parsed
        }
        self.init(json: json)
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }
}

/// `rules.action`: the value a rule proposes.
public struct RuleAction: Codable, Hashable, Sendable {
    public var fieldID: String
    public var optionID: String

    public init(fieldID: String, optionID: String) {
        self.fieldID = fieldID
        self.optionID = optionID
    }

    enum CodingKeys: String, CodingKey {
        case fieldID = "field_id"
        case optionID = "option_id"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fieldID = try c.decode(String.self, forKey: .fieldID, default: "")
        optionID = try c.decode(String.self, forKey: .optionID, default: "")
    }
}

/// An automatic rule (`rules` table).
public struct Rule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var position: Int
    public var condition: RuleCondition
    public var action: RuleAction
    public var mode: RuleMode
    public var updatedAt: String
    public var deletedAt: String?
    public var rev: Int?

    public init(
        id: String,
        name: String = "",
        enabled: Bool = true,
        position: Int = 0,
        condition: RuleCondition,
        action: RuleAction,
        mode: RuleMode = .suggest,
        updatedAt: String = "",
        deletedAt: String? = nil,
        rev: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.position = position
        self.condition = condition
        self.action = action
        self.mode = mode
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.rev = rev
    }

    public var isDeleted: Bool { deletedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, position, condition, action, mode
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case rev
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name, default: "")
        enabled = try c.lenientBool(.enabled, default: true)
        position = try c.decode(Int.self, forKey: .position, default: 0)
        condition = try c.decodeIfPresent(RuleCondition.self, forKey: .condition) ?? .unknown(.null)
        action = try c.lenientJSON(RuleAction.self, forKey: .action) ?? RuleAction(fieldID: "", optionID: "")
        mode = try c.decode(RuleMode.self, forKey: .mode, default: .suggest)
        updatedAt = try c.decode(String.self, forKey: .updatedAt, default: "")
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(position, forKey: .position)
        try c.encode(condition, forKey: .condition)
        try c.encode(action, forKey: .action)
        try c.encode(mode, forKey: .mode)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
        try c.encodeIfPresent(rev, forKey: .rev)
    }
}
