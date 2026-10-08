import Foundation
import MyTagsKit
import Testing

@Suite("File values")
struct FileValueReaderTests {
    @Test("GENRE, GROUPING, COMMENT and rating from the baseline")
    func readAll() {
        let config = Fixtures.config
        let baseline = Baseline(genre: " rap  fr ", grouping: "Vert", comment: "fr extend sexy", rating: 3)
        let values = FileValueReader.read(baseline: baseline, config: config)
        #expect(
            Fixtures.valuesByKey(values.values.filter { $0.key != Fixtures.fieldID("note") })
                == ["genre": ["RAP FR"], "couleur": ["VERT"], "pays": ["FR"], "type": ["EXTEND"], "attribut": ["SEXY"]])
        #expect(values.values[Fixtures.fieldID("note")] == .stars(3))
        #expect(values.unknownTexts.isEmpty)
        #expect(values.comment.status == .conforme)
    }

    @Test("Unknown GENRE text is reported and gives no value")
    func unknownText() {
        let values = FileValueReader.read(baseline: Baseline(genre: "Techno", grouping: "  "), config: Fixtures.config)
        #expect(values.values.isEmpty)
        #expect(values.unknownTexts == [Fixtures.fieldID("genre"): "Techno"])
        #expect(values.comment.status == .incomplet)
    }

    @Test("Missing baseline and zero rating")
    func emptyBaseline() {
        #expect(FileValueReader.read(baseline: nil, config: Fixtures.config).values.isEmpty)
        #expect(FileValueReader.read(baseline: Baseline(rating: 0), config: Fixtures.config).values.isEmpty)
    }

    @Test("Aliases are recognised, labels are not")
    func aliases() {
        let fields = [Field(id: "g", key: "g", kind: .single, targetTag: .genre)]
        let options = [
            FieldOption(id: "rapfr", fieldID: "g", value: "RAP FR", label: "Rap français", aliases: ["RAPFR", "Rap Français"]),
        ]
        let config = TagConfig(fields: fields, options: options)
        let field = fields[0]
        #expect(FileValueReader.match("rapfr", field: field, config: config) == .option("rapfr"))
        #expect(FileValueReader.match("rap français", field: field, config: config) == .option("rapfr"))
        #expect(FileValueReader.match("Rap francais", field: field, config: config) == nil)
        #expect(FileValueReader.match("Rap français ", field: field, config: config) == .option("rapfr"))
    }

    @Test("Multiple-choice GENRE: every piece must match")
    func multiGenre() {
        let field = Field(id: "g", key: "g", kind: .multi, targetTag: .genre)
        let options = [
            FieldOption(id: "pop", fieldID: "g", value: "POP", position: 1),
            FieldOption(id: "afro", fieldID: "g", value: "AFRO", position: 0),
        ]
        let config = TagConfig(fields: [field], options: options)
        #expect(FileValueReader.match("pop / afro", field: field, config: config) == FieldValue(optionIDs: ["afro", "pop"]))
        #expect(FileValueReader.match("POP/POP", field: field, config: config) == FieldValue(optionIDs: ["pop"]))
        #expect(FileValueReader.match("POP/", field: field, config: config) == nil)
        #expect(FileValueReader.match("POP/ROCK", field: field, config: config) == nil)
    }

    @Test("Text GENRE keeps the raw text")
    func textGenre() {
        let field = Field(id: "g", key: "g", kind: .text, targetTag: .genre)
        let config = TagConfig(fields: [field], options: [])
        #expect(FileValueReader.match("  Deep House ", field: field, config: config) == FieldValue(text: "  Deep House "))
        #expect(FileValueReader.match("   ", field: field, config: config) == nil)
    }
}
