import Foundation
import MyTagsKit

/// Locates files of the repository from this source file.
enum Repo {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            let marker = url.appendingPathComponent("shared/test-vectors/tag-model.json")
            if FileManager.default.fileExists(atPath: marker.path) { return url }
        }
        return url
    }()

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(relativePath))
    }
}

// MARK: - Shared vectors (shared/test-vectors/tag-model.json)

struct SimplifiedOption: Decodable, Sendable {
    let value: String
    let aliases: [String]

    init(from decoder: any Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            self.value = value
            aliases = []
            return
        }
        struct Detailed: Decodable {
            let value: String
            let aliases: [String]?
        }
        let detailed = try Detailed(from: decoder)
        value = detailed.value
        aliases = detailed.aliases ?? []
    }
}

struct SimplifiedField: Decodable, Sendable {
    let key: String
    let kind: FieldKind
    let target_tag: TargetTag
    let target_slot: Int?
    let options: [SimplifiedOption]
}

struct SimplifiedConfig: Decodable, Sendable {
    let settings: [String: JSONValue]
    let fields: [SimplifiedField]

    /// Field id = key, option id = "<key>:<value>".
    var tagConfig: TagConfig {
        var fields: [Field] = []
        var options: [FieldOption] = []
        for (position, field) in self.fields.enumerated() {
            fields.append(
                Field(
                    id: field.key, key: field.key, kind: field.kind, targetTag: field.target_tag,
                    targetSlot: field.target_slot, position: position))
            for (optionPosition, option) in field.options.enumerated() {
                options.append(
                    FieldOption(
                        id: "\(field.key):\(option.value)", fieldID: field.key, value: option.value,
                        aliases: option.aliases, position: optionPosition))
            }
        }
        return TagConfig(fields: fields, options: options, settingValues: settings)
    }
}

struct CommentParseCase: Decodable, Sendable, CustomStringConvertible {
    let config: String
    let comment: String?
    let status: String
    let values: [String: [String]]
    let explicit_empty: [String]

    var description: String { "\(config): \(comment.map { "\"\($0)\"" } ?? "null")" }
}

struct CommentComposeCase: Decodable, Sendable, CustomStringConvertible {
    let config: String
    let values: [String: [String]]
    let expected: String

    var description: String { "\(config): \(expected)" }
}

struct TargetRow: Decodable, Sendable {
    let values: [String]?
    let source: String?
    let rating: Int?
}

struct TargetCase: Decodable, Sendable, CustomStringConvertible {
    let name: String
    let config: String
    let format: String
    let baseline: Baseline
    let rows: [String: TargetRow]
    let targets: Baseline
    let to_apply: Bool

    var description: String { name }
}

struct TitleCase: Decodable, Sendable, CustomStringConvertible {
    let title: String
    let pattern: String
    let match: Bool

    var description: String { "\(title) ~ \(pattern)" }
}

struct ArtistCase: Decodable, Sendable, CustomStringConvertible {
    let artist: String
    let primary: String

    var description: String { "\"\(artist)\"" }
}

struct RatingCase: Decodable, Sendable, CustomStringConvertible {
    let scheme: String
    let raw: Int
    let stars: Int?

    var description: String { "\(scheme): \(raw)" }
}

struct TagModelVectors: Decodable, Sendable {
    let configs: [String: SimplifiedConfig]
    let comment_parse: [CommentParseCase]
    let comment_compose: [CommentComposeCase]
    let targets: [TargetCase]
    let title_contains: [TitleCase]
    let primary_artist: [ArtistCase]
    let rating_read: [RatingCase]
    let popm_write: [String: Int]
}

enum Vectors {
    static let shared: TagModelVectors? = {
        guard let data = try? Repo.data("shared/test-vectors/tag-model.json") else { return nil }
        return try? JSONDecoder().decode(TagModelVectors.self, from: data)
    }()

    static let configs: [String: TagConfig] = {
        var result = (shared?.configs ?? [:]).mapValues(\.tagConfig)
        result["default"] = Fixtures.defaultConfig
        return result
    }()

    static var commentParse: [CommentParseCase] { shared?.comment_parse ?? [] }
    static var commentCompose: [CommentComposeCase] { shared?.comment_compose ?? [] }
    static var targets: [TargetCase] { shared?.targets ?? [] }
    static var titleContains: [TitleCase] { shared?.title_contains ?? [] }
    static var primaryArtist: [ArtistCase] { shared?.primary_artist ?? [] }
    static var ratingRead: [RatingCase] { shared?.rating_read ?? [] }
}

// MARK: - Default configuration helpers

enum Fixtures {
    static let defaultConfig: TagConfig? = {
        guard let data = try? Repo.data("shared/default-config.json") else { return nil }
        return try? TagConfig.load(fromDefaultConfigJSON: data)
    }()

    /// The default configuration; an empty one when the file cannot be read (tests then fail).
    static var config: TagConfig {
        defaultConfig ?? TagConfig(fields: [], options: [])
    }

    static func fieldID(_ key: String, in config: TagConfig = config) -> String {
        config.field(key: key)?.id ?? "missing-field:\(key)"
    }

    static func optionID(_ key: String, _ value: String, in config: TagConfig = config) -> String {
        config.option(fieldID: fieldID(key, in: config), value: value)?.id ?? "missing-option:\(key):\(value)"
    }

    /// `{key: [values]}` to `{field id: FieldValue}`.
    static func values(_ byKey: [String: [String]], in config: TagConfig = config) -> [String: FieldValue] {
        var result: [String: FieldValue] = [:]
        for (key, values) in byKey {
            result[fieldID(key, in: config)] = FieldValue(optionIDs: values.map { optionID(key, $0, in: config) })
        }
        return result
    }

    /// `{field id: FieldValue}` to `{key: [option values]}`.
    static func valuesByKey(_ values: [String: FieldValue], in config: TagConfig = config) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (fieldID, value) in values {
            let key = config.field(id: fieldID)?.key ?? fieldID
            result[key] = value.optionIDs.map { config.option(id: $0)?.value ?? $0 }
        }
        return result
    }

    static func row(
        _ trackID: String, _ key: String, _ values: [String] = [], rating: Int? = nil, source: ValueSource = .user,
        updatedAt: String = "2026-10-08T10:00:00.000Z", deletedAt: String? = nil, in config: TagConfig = config
    ) -> TrackValue {
        TrackValue(
            trackID: trackID, fieldID: fieldID(key, in: config), optionIDs: values.map { optionID(key, $0, in: config) },
            rating: rating, source: source, updatedAt: updatedAt, deletedAt: deletedAt)
    }

    static func track(
        _ id: String, title: String? = nil, artist: String? = nil, format: String = "mp3", genre: String? = nil,
        grouping: String? = nil, comment: String? = nil, rating: Int? = nil, applyStatus: ApplyStatus = .aucun
    ) -> Track {
        Track(
            id: id, filePath: "/Music/\(id).\(format)", fileFormat: format, title: title, artist: artist,
            baseline: Baseline(genre: genre, grouping: grouping, comment: comment, rating: rating),
            applyStatus: applyStatus, updatedAt: "2026-10-08T00:00:00.000Z")
    }
}
