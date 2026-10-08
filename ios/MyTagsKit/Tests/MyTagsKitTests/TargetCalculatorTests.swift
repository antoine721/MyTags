import Foundation
import MyTagsKit
import Testing

@Suite("Target tags and to-apply")
struct TargetCalculatorTests {
    @Test("Shared vectors: targets", arguments: Vectors.targets)
    func targets(_ vector: TargetCase) throws {
        let config = try #require(Vectors.configs[vector.config])
        var rows: [String: FieldValue] = [:]
        for (key, row) in vector.rows {
            let fieldID = Fixtures.fieldID(key, in: config)
            if let rating = row.rating {
                rows[fieldID] = FieldValue(rating: rating)
            } else {
                rows[fieldID] = FieldValue(optionIDs: (row.values ?? []).map { Fixtures.optionID(key, $0, in: config) })
            }
        }
        let targets = TargetCalculator.targets(format: vector.format, baseline: vector.baseline, rows: rows, config: config)
        #expect(targets == vector.targets)
        #expect(
            TargetCalculator.isToApply(format: vector.format, baseline: vector.baseline, rows: rows, config: config)
                == vector.to_apply)
    }

    @Test("Shared vectors load")
    func vectorsLoad() {
        #expect(!Vectors.targets.isEmpty)
    }

    @Test("Multiple-choice GENRE joins values in display order")
    func multiGenre() {
        let fields = [Field(id: "genre", key: "genre", kind: .multi, targetTag: .genre)]
        let options = [
            FieldOption(id: "a", fieldID: "genre", value: "AFRO", position: 0),
            FieldOption(id: "b", fieldID: "genre", value: "POP", position: 1),
        ]
        let config = TagConfig(fields: fields, options: options)
        let rows = ["genre": FieldValue(optionIDs: ["b", "a"])]
        let targets = TargetCalculator.targets(format: "mp3", baseline: nil, rows: rows, config: config)
        #expect(targets.genre == "AFRO/POP")
    }

    @Test("Text GROUPING writes the text, an empty text removes the tag")
    func textGrouping() {
        let config = TagConfig(fields: [Field(id: "g", key: "g", kind: .text, targetTag: .grouping)], options: [])
        let baseline = Baseline(grouping: "OLD")
        #expect(
            TargetCalculator.targets(format: "mp3", baseline: baseline, rows: ["g": FieldValue(text: "New")], config: config)
                .grouping == "New")
        #expect(
            TargetCalculator.targets(format: "mp3", baseline: baseline, rows: ["g": FieldValue(text: "")], config: config)
                .grouping == nil)
    }

    @Test("Differing tags are listed")
    func differingTags() {
        let target = Baseline(genre: "POP", grouping: "", comment: "FR () ()", rating: 4)
        let baseline = Baseline(genre: "POP", grouping: nil, comment: "FR", rating: 4)
        #expect(TargetCalculator.differingTags(target, from: baseline) == [.comment])
        #expect(TargetCalculator.differingTags(Baseline(), from: nil).isEmpty)
    }

    @Test("Comparison is exact: case and spacing count")
    func exactComparison() {
        let config = Fixtures.config
        let rows = [Fixtures.fieldID("genre"): FieldValue.option(Fixtures.optionID("genre", "POP"))]
        #expect(TargetCalculator.isToApply(format: "mp3", baseline: Baseline(genre: "Pop"), rows: rows, config: config))
        #expect(!TargetCalculator.isToApply(format: "mp3", baseline: Baseline(genre: "POP"), rows: rows, config: config))
    }
}
