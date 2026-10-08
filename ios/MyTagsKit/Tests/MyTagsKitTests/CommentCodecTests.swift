import Foundation
import MyTagsKit
import Testing

@Suite("COMMENT reading and composition")
struct CommentCodecTests {
    @Test("Shared vectors load")
    func vectorsLoad() throws {
        let vectors = try #require(Vectors.shared)
        #expect(!vectors.comment_parse.isEmpty)
        #expect(!vectors.comment_compose.isEmpty)
        #expect(Fixtures.defaultConfig != nil)
        for name in Set(vectors.comment_parse.map(\.config) + vectors.comment_compose.map(\.config)) {
            #expect(Vectors.configs[name] != nil, "missing config \(name)")
        }
    }

    @Test("Shared vectors: comment_parse", arguments: Vectors.commentParse)
    func parse(_ vector: CommentParseCase) throws {
        let config = try #require(Vectors.configs[vector.config])
        let result = CommentCodec.parse(vector.comment, config: config)
        #expect(result.status.rawValue == vector.status)
        #expect(Fixtures.valuesByKey(result.values, in: config) == vector.values)
        let explicitKeys = Set(result.explicitEmpty.compactMap { config.field(id: $0)?.key })
        #expect(explicitKeys == Set(vector.explicit_empty))
    }

    @Test("Shared vectors: comment_compose", arguments: Vectors.commentCompose)
    func compose(_ vector: CommentComposeCase) throws {
        let config = try #require(Vectors.configs[vector.config])
        let values = Fixtures.values(vector.values, in: config)
        #expect(CommentCodec.compose(values: values, config: config) == vector.expected)
    }

    @Test("Composition reads back to the same values")
    func roundTrip() {
        let config = Fixtures.config
        let cases: [[String: [String]]] = [
            ["pays": ["FR"], "type": ["EXTEND"], "attribut": ["SEXY"]],
            ["pays": ["UK"], "type": ["EDIT"], "attribut": ["()"]],
            ["pays": ["US"], "attribut": ["SINGALONG"]],
        ]
        for values in cases {
            let composed = CommentCodec.compose(values: Fixtures.values(values), config: config)
            let parsed = CommentCodec.parse(composed, config: config)
            #expect(parsed.status == .conforme)
            #expect(Fixtures.valuesByKey(parsed.values) == values)
        }
    }

    @Test("A separator at the very end of the text is invalid")
    func trailingSeparator() {
        let config = Self.config(separator: "-")
        #expect(CommentCodec.parse("FR-", config: config).status == .nonConforme)
        #expect(CommentCodec.parse("FR-EXTEND-SEXY", config: config).status == .conforme)
        #expect(CommentCodec.parse("FR-EXTEND-", config: config).status == .nonConforme)
        let incomplete = CommentCodec.parse("FR-SEXY", config: config)
        #expect(incomplete.status == .incomplet)
        #expect(Fixtures.valuesByKey(incomplete.values, in: config) == ["pays": ["FR"], "attribut": ["SEXY"]])
    }

    @Test("Equal texts go to the first option in display order")
    func duplicateCandidates() {
        let fields = [
            Field(id: "pays", key: "pays", kind: .single, targetTag: .comment, targetSlot: 1),
        ]
        let options = [
            FieldOption(id: "fr", fieldID: "pays", value: "FR", aliases: ["F"], position: 0),
            FieldOption(id: "fra", fieldID: "pays", value: "FRA", aliases: ["f"], position: 1),
        ]
        let config = TagConfig(fields: fields, options: options)
        #expect(CommentCodec.parse("f", config: config).values == ["pays": .option("fr")])
    }

    @Test("Archived options are recognised, deleted ones are not")
    func archivedAndDeletedOptions() {
        let fields = [Field(id: "pays", key: "pays", kind: .single, targetTag: .comment, targetSlot: 1)]
        let options = [
            FieldOption(id: "fr", fieldID: "pays", value: "FR", position: 0, archived: true),
            FieldOption(id: "us", fieldID: "pays", value: "US", position: 1, deletedAt: "2026-10-08T00:00:00.000Z"),
        ]
        let config = TagConfig(fields: fields, options: options)
        #expect(CommentCodec.parse("FR", config: config).status == .conforme)
        #expect(CommentCodec.parse("US", config: config).status == .nonConforme)
    }

    @Test("Unknown option ids compose as the empty token")
    func composeIgnoresForeignOptions() {
        let config = Fixtures.config
        let values = [
            Fixtures.fieldID("pays"): FieldValue(optionIDs: ["not-an-option"]),
            Fixtures.fieldID("type"): .option(Fixtures.optionID("genre", "POP")),
        ]
        #expect(CommentCodec.compose(values: values, config: config) == "() () ()")
    }

    @Test("A configuration without COMMENT fields")
    func noCommentFields() {
        let config = TagConfig(fields: [Field(id: "g", key: "g", kind: .single, targetTag: .genre)], options: [])
        #expect(CommentCodec.compose(values: [:], config: config) == "")
        #expect(CommentCodec.parse("", config: config).status == .incomplet)
        #expect(CommentCodec.parse("FR", config: config).status == .nonConforme)
    }

    private static func config(separator: String) -> TagConfig {
        let fields = [
            Field(id: "pays", key: "pays", kind: .single, targetTag: .comment, targetSlot: 1, position: 0),
            Field(id: "type", key: "type", kind: .single, targetTag: .comment, targetSlot: 2, position: 1),
            Field(id: "attribut", key: "attribut", kind: .single, targetTag: .comment, targetSlot: 3, position: 2),
        ]
        let options = [
            FieldOption(id: "pays:FR", fieldID: "pays", value: "FR"),
            FieldOption(id: "type:EXTEND", fieldID: "type", value: "EXTEND"),
            FieldOption(id: "attribut:SEXY", fieldID: "attribut", value: "SEXY"),
        ]
        return TagConfig(fields: fields, options: options, settingValues: ["comment.separator": .string(separator)])
    }
}
