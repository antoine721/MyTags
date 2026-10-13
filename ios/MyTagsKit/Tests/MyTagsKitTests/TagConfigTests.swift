import Foundation
import MyTagsKit
import Testing

@Suite("Configuration")
struct TagConfigTests {
    @Test("Default configuration lookups")
    func defaultLookups() throws {
        let config = try #require(Fixtures.defaultConfig)
        #expect(config.fields.map(\.key) == ["genre", "couleur", "pays", "type", "attribut", "note", "actualite"])
        #expect(config.visibleFields.count == 6)
        #expect(config.commentFields.map(\.key) == ["pays", "type", "attribut"])
        #expect(config.keywordFields.map(\.key) == ["actualite"])
        #expect(config.commentSlotCount == 3)
        #expect(config.commentField(atSlot: 2)?.key == "type")
        #expect(config.field(for: .genre)?.key == "genre")
        #expect(config.field(for: .grouping)?.key == "couleur")
        #expect(config.field(for: .rating)?.key == "note")
        #expect(config.field(for: .comment) == nil)
        let genre = try #require(config.field(key: "genre"))
        #expect(config.field(id: genre.id)?.key == "genre")
        #expect(config.options(forField: genre.id).map(\.value) == ["RAP FR", "RAP US", "POP", "BOUYON", "SHATTA", "ZOUKOMPA"])
        #expect(config.option(id: "b504918d-a09f-5af7-ba3f-9e7bd2b7d221")?.value == "RAP FR")
        #expect(config.rules.count == 5 && config.activeRules.count == 5)
        #expect(config.separator == " ")
        #expect(config.emptyToken == "()")
        #expect(config.multiSeparator == "/")
        #expect(config.ratingWriteFormats == ["mp3", "wav", "aiff"])
        #expect(config.writesRating(format: "wav"))
        #expect(!config.writesRating(format: "m4a"))
    }

    @Test("Deleted rows are ignored; archived options stay resolvable")
    func deletedAndArchived() {
        let deleted = "2026-10-08T00:00:00.000Z"
        let config = TagConfig(
            fields: [
                Field(id: "b", key: "b", kind: .single, targetTag: .grouping, position: 1),
                Field(id: "a", key: "a", kind: .single, targetTag: .genre, position: 1),
                Field(id: "x", key: "x", kind: .single, targetTag: .genre, position: 0, deletedAt: deleted),
                Field(id: "h", key: "h", kind: .text, targetTag: .comment, targetSlot: 1, visible: false, position: 2),
            ],
            options: [
                FieldOption(id: "a2", fieldID: "a", value: "Z", position: 0),
                FieldOption(id: "a1", fieldID: "a", value: "M", position: 0, archived: true),
                FieldOption(id: "a3", fieldID: "a", value: "N", position: 1, deletedAt: deleted),
                FieldOption(id: "orphan", fieldID: "x", value: "O"),
            ],
            rules: [
                Rule(id: "r2", position: 1, condition: .titleContains(patterns: ["x"]), action: RuleAction(fieldID: "a", optionID: "a1")),
                Rule(id: "r1", position: 0, condition: .titleContains(patterns: ["y"]), action: RuleAction(fieldID: "a", optionID: "a1")),
                Rule(id: "r0", enabled: false, position: 0, condition: .titleContains(patterns: ["z"]), action: RuleAction(fieldID: "a", optionID: "a1")),
                Rule(id: "rd", position: 0, condition: .titleContains(patterns: ["z"]), action: RuleAction(fieldID: "a", optionID: "a1"), deletedAt: deleted),
            ],
            settings: [
                SettingRow(key: "comment.separator", value: " - ", deletedAt: deleted),
                SettingRow(key: "comment.empty_token", value: ""),
                SettingRow(key: "multi.separator", value: 3),
            ])
        // Ordered by (position, key).
        #expect(config.fields.map(\.id) == ["a", "b", "h"])
        #expect(config.visibleFields.map(\.id) == ["a", "b"])
        #expect(config.field(id: "x") == nil)
        #expect(config.field(for: .genre)?.id == "a")
        // Ordered by (position, value); archived kept, deleted dropped.
        #expect(config.options(forField: "a").map(\.id) == ["a1", "a2"])
        #expect(config.selectableOptions(forField: "a").map(\.id) == ["a2"])
        #expect(config.option(id: "a1")?.archived == true)
        #expect(config.option(id: "a3") == nil)
        #expect(config.option(id: "orphan") == nil)
        #expect(config.rules.map(\.id) == ["r1", "r0", "r2"])
        #expect(config.activeRules.map(\.id) == ["r1", "r2"])
        // Deleted, empty or non-text settings fall back to the defaults.
        #expect(config.separator == " ")
        #expect(config.emptyToken == "()")
        #expect(config.multiSeparator == "/")
        #expect(config.ratingWriteFormats == TagConfig.defaultRatingWriteFormats)
        #expect(config.setting("comment.separator") == nil)
    }

    @Test("Value normalisation per field kind")
    func normalization() throws {
        let config = Fixtures.config
        let genre = try #require(config.field(key: "genre"))
        let pop = Fixtures.optionID("genre", "POP")
        let rapFR = Fixtures.optionID("genre", "RAP FR")
        let foreign = Fixtures.optionID("pays", "FR")
        #expect(config.sortedOptionIDs([pop, foreign, rapFR, pop], forField: genre.id) == [rapFR, pop])
        #expect(config.normalized(FieldValue(optionIDs: [pop, rapFR], rating: 3), for: genre) == .option(rapFR))
        let note = try #require(config.field(key: "note"))
        #expect(config.normalized(FieldValue(optionIDs: [pop], rating: 4), for: note) == .stars(4))
        #expect(FieldValue().isEmpty && FieldValue(text: "").isEmpty && !FieldValue(text: "a").isEmpty)
    }

    @Test("COMMENT positions are the COMMENT fields sorted by slot; composition covers slots 1 to max")
    func commentSlots() {
        let config = TagConfig(
            fields: [
                Field(id: "c3", key: "c3", kind: .single, targetTag: .comment, targetSlot: 3, position: 0),
                Field(id: "c1", key: "c1", kind: .single, targetTag: .comment, targetSlot: 1, position: 1),
            ],
            options: [
                FieldOption(id: "o1", fieldID: "c1", value: "FR"),
                FieldOption(id: "o3", fieldID: "c3", value: "SEXY"),
            ])
        #expect(config.commentFields.map(\.id) == ["c1", "c3"])
        #expect(config.commentSlotCount == 3)
        #expect(config.commentField(atSlot: 2) == nil)
        #expect(CommentCodec.compose(values: ["c1": .option("o1"), "c3": .option("o3")], config: config) == "FR () SEXY")
        #expect(CommentCodec.parse("FR SEXY", config: config).status == .conforme)
    }
}
