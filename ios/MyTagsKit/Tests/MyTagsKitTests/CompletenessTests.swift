import Foundation
import MyTagsKit
import Testing

@Suite("Completeness")
struct CompletenessTests {
    let config = Fixtures.config

    private func resolve(_ track: Track, rows: [TrackValue] = [], config: TagConfig? = nil) -> ResolvedTrack {
        ValueResolver.resolve(
            track: track, rows: rows, config: config ?? self.config, suggestionContext: SuggestionContext())
    }

    @Test("Untouched track without tags")
    func untagged() {
        let resolved = resolve(Fixtures.track("t"))
        #expect(Completeness.isUntagged(resolved, config: config))
        #expect(Completeness.isIncomplete(resolved, config: config))
        #expect(
            Completeness.missingRequiredFields(resolved, config: config)
                == ["genre", "couleur", "pays", "type", "note"].map { Fixtures.fieldID($0) })
        #expect(!Completeness.isValidatable(resolved, config: config))
    }

    @Test("A file rating alone makes the track tagged")
    func ratingOnly() {
        let resolved = resolve(Fixtures.track("t", rating: 4))
        #expect(!Completeness.isUntagged(resolved, config: config))
    }

    @Test("Suggestions count for validation, not for completeness")
    func suggestions() {
        let track = Fixtures.track("t", title: "Song (Remix)", genre: "RAP FR", grouping: "VERT", rating: 3)
        let resolved = resolve(track)
        // pays (rule) and type (title) are suggested; attribut (optional) has its default.
        #expect(Completeness.isIncomplete(resolved, config: config))
        #expect(Completeness.missingRequiredFields(resolved, config: config).isEmpty)
        #expect(Completeness.isValidatable(resolved, config: config))
    }

    @Test("Complete track")
    func complete() {
        let track = Fixtures.track("t", genre: "POP", grouping: "BLEU", comment: "UK EDIT", rating: 5)
        let resolved = resolve(track)
        #expect(!Completeness.isIncomplete(resolved, config: config))
        #expect(!Completeness.isUntagged(resolved, config: config))
    }

    @Test("A cleared required field is missing")
    func cleared() {
        let track = Fixtures.track("t", genre: "POP", grouping: "BLEU", comment: "UK EDIT", rating: 5)
        let resolved = resolve(track, rows: [Fixtures.row("t", "couleur")])
        #expect(Completeness.isIncomplete(resolved, config: config))
        #expect(Completeness.missingRequiredFields(resolved, config: config) == [Fixtures.fieldID("couleur")])
    }

    @Test("Hidden required fields are ignored")
    func hidden() throws {
        var document = try ConfigDocument.decode(from: Repo.data("shared/default-config.json"))
        for index in document.fields.indices where document.fields[index].key != "genre" {
            document.fields[index].visible = false
        }
        let config = TagConfig(document: document)
        let resolved = resolve(Fixtures.track("t", genre: "POP"), config: config)
        #expect(!Completeness.isIncomplete(resolved, config: config))
        #expect(Completeness.isValidatable(resolved, config: config))
    }
}
