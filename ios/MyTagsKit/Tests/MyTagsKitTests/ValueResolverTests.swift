import Foundation
import MyTagsKit
import Testing

@Suite("Value resolution and suggestions")
struct ValueResolverTests {
    let config = Fixtures.config

    private func id(_ key: String) -> String { Fixtures.fieldID(key) }
    private func option(_ key: String, _ value: String) -> String { Fixtures.optionID(key, value) }

    private func resolve(
        _ track: Track, rows: [TrackValue] = [], stats: ArtistStats? = nil, suggestions: Bool = true,
        config: TagConfig? = nil
    ) -> ResolvedTrack {
        ValueResolver.resolve(
            track: track, rows: rows, config: config ?? self.config,
            suggestionContext: suggestions ? SuggestionContext(artistStats: stats) : nil)
    }

    @Test("Row, then file, then suggestion, then empty")
    func precedence() {
        let track = Fixtures.track("t", genre: "Rap Fr", grouping: "Techno", comment: "FR EXTEND", rating: 3)
        let rows = [Fixtures.row("t", "genre", ["POP"])]
        let resolved = resolve(track, rows: rows)

        let genre = resolved[id("genre")]
        #expect(genre?.state == .confirmed && genre?.source == .user && genre?.hasRow == true)
        #expect(genre?.value == .option(option("genre", "POP")))

        let pays = resolved[id("pays")]
        #expect(pays?.state == .confirmed && pays?.source == .file && pays?.hasRow == false)

        let couleur = resolved[id("couleur")]
        #expect(couleur?.state == .empty)
        #expect(couleur?.unknownFileText == "Techno")

        let attribut = resolved[id("attribut")]
        #expect(attribut?.state == .suggested && attribut?.source == .default)
        #expect(attribut?.value == .option(option("attribut", "()")))

        #expect(resolved[id("note")]?.value == .stars(3))
        #expect(resolved[id("note")]?.source == .file)
        #expect(resolved.commentStatus == .incomplet)
        #expect(resolved.fields.count == config.fields.count)
    }

    @Test("A cleared row stays empty and blocks file values and suggestions")
    func clearedRow() {
        let track = Fixtures.track("t", genre: "POP", comment: "FR EXTEND")
        let rows = [Fixtures.row("t", "genre"), Fixtures.row("t", "attribut")]
        let resolved = resolve(track, rows: rows)
        #expect(resolved[id("genre")]?.state == .empty)
        #expect(resolved[id("genre")]?.hasRow == true)
        #expect(resolved[id("genre")]?.source == .user)
        #expect(resolved[id("attribut")]?.state == .empty)
    }

    @Test("Deleted rows and rows of other tracks are ignored")
    func ignoredRows() {
        let track = Fixtures.track("t", genre: "POP")
        let rows = [
            Fixtures.row("t", "genre", ["RAP US"], deletedAt: "2026-10-08T11:00:00.000Z"),
            Fixtures.row("other", "couleur", ["VERT"]),
        ]
        let resolved = resolve(track, rows: rows)
        #expect(resolved[id("genre")]?.source == .file)
        #expect(resolved[id("couleur")]?.state == .empty)
        #expect(resolved.rowValues.isEmpty)
    }

    @Test("title_contains rules suggest with source title; the first rule wins")
    func titleRules() {
        let resolved = resolve(Fixtures.track("t", title: "Song (Extended Remix)"))
        let type = resolved[id("type")]
        #expect(type?.state == .suggested)
        #expect(type?.source == .title)
        #expect(type?.value == .option(option("type", "EXTEND")))
        #expect(resolved.applyModeRuleValues.isEmpty)
    }

    @Test("Rules never override a confirmed value")
    func confirmedWins() {
        let resolved = resolve(Fixtures.track("t", title: "Song (Remix)", comment: "FR EDIT"))
        #expect(resolved[id("type")]?.state == .confirmed)
        #expect(resolved[id("type")]?.value == .option(option("type", "EDIT")))
    }

    @Test("field_equals uses the confirmed value")
    func fieldEqualsConfirmed() {
        let fromFile = resolve(Fixtures.track("t", genre: "RAP US"))
        #expect(fromFile[id("pays")]?.state == .suggested)
        #expect(fromFile[id("pays")]?.source == .rule)
        #expect(fromFile[id("pays")]?.value == .option(option("pays", "US")))

        let fromRow = resolve(Fixtures.track("t", genre: "RAP US"), rows: [Fixtures.row("t", "genre", ["RAP FR"])])
        #expect(fromRow[id("pays")]?.value == .option(option("pays", "FR")))
    }

    @Test("field_equals sees earlier rule suggestions, not artist or default suggestions")
    func ruleChain() throws {
        let document = try ConfigDocument.decode(from: Repo.data("shared/default-config.json"))
        let genreRule = Rule(
            id: "title-rap", position: -1, condition: .titleContains(patterns: ["rap"]),
            action: RuleAction(fieldID: id("genre"), optionID: option("genre", "RAP FR")))
        var withChain = document
        withChain.rules.append(genreRule)
        let chained = ValueResolver.resolve(
            track: Fixtures.track("t", title: "Rap song"), rows: [], config: TagConfig(document: withChain),
            suggestionContext: SuggestionContext())
        #expect(chained[id("genre")]?.source == .title)
        #expect(chained[id("pays")]?.source == .rule)
        #expect(chained[id("pays")]?.value == .option(option("pays", "FR")))

        // A rule placed after the one it depends on does not see it.
        var late = document
        late.rules.append(
            Rule(
                id: "late", position: 99, condition: .titleContains(patterns: ["rap"]),
                action: RuleAction(fieldID: id("genre"), optionID: option("genre", "RAP FR"))))
        let unchained = ValueResolver.resolve(
            track: Fixtures.track("t", title: "Rap song"), rows: [], config: TagConfig(document: late),
            suggestionContext: SuggestionContext())
        #expect(unchained[id("genre")]?.state == .suggested)
        #expect(unchained[id("pays")]?.state == .empty)

        // A genre suggested by the artist does not trigger field_equals rules.
        var stats = ArtistStats()
        stats.setTrack(id: "o1", artist: "Ninho", confirmedValues: [id("genre"): .option(option("genre", "RAP FR"))])
        let byArtist = resolve(Fixtures.track("t", artist: "Ninho"), stats: stats)
        #expect(byArtist[id("genre")]?.source == .artist)
        #expect(byArtist[id("pays")]?.state == .empty)
    }

    @Test("Apply-mode rules are exposed with source rule")
    func applyMode() throws {
        var document = try ConfigDocument.decode(from: Repo.data("shared/default-config.json"))
        for index in document.rules.indices { document.rules[index].mode = .apply }
        let config = TagConfig(document: document)
        let resolved = resolve(Fixtures.track("t", title: "Song (Radio Edit)", genre: "RAP FR"), config: config)
        #expect(
            resolved.applyModeRuleValues
                == [id("type"): .option(option("type", "EDIT")), id("pays"): .option(option("pays", "FR"))])
        #expect(resolved[id("type")]?.source == .rule)
        let plan = ValidationPlan.make(resolved: resolved, config: config)
        #expect(plan.values.contains(PlannedValue(fieldID: id("type"), value: .option(option("type", "EDIT")), source: .rule)))
    }

    @Test("Disabled rules, archived options and rating fields are never suggested")
    func neverSuggested() throws {
        var document = try ConfigDocument.decode(from: Repo.data("shared/default-config.json"))
        for index in document.rules.indices { document.rules[index].enabled = false }
        if let index = document.fieldOptions.firstIndex(where: { $0.id == "bc85a049-b586-5c70-a07e-949b93ca0d79" }) {
            document.fieldOptions[index].archived = true
        }
        document.rules.append(
            Rule(
                id: "rating", condition: .titleContains(patterns: ["song"]),
                action: RuleAction(fieldID: id("note"), optionID: option("genre", "POP"))))
        let config = TagConfig(document: document)
        let resolved = resolve(Fixtures.track("t", title: "Song (Extended)"), config: config)
        #expect(resolved[id("type")]?.state == .empty)
        #expect(resolved[id("attribut")]?.state == .empty)
        #expect(resolved[id("note")]?.state == .empty)
    }

    @Test("Without a suggestion context nothing is suggested")
    func noContext() {
        let resolved = resolve(Fixtures.track("t", title: "Song (Extended)"), suggestions: false)
        #expect(!resolved.fields.values.contains { $0.state == .suggested })
    }

    @Test("Artist suggestions apply to artist-level fields and beat the default")
    func artistSuggestion() {
        var stats = ArtistStats()
        let attribut = FieldValue.option(option("attribut", "SEXY"))
        let genre = FieldValue.option(option("genre", "SHATTA"))
        stats.setTrack(id: "o1", artist: "Kalash", confirmedValues: [id("genre"): genre, id("attribut"): attribut])
        stats.setTrack(id: "o2", artist: "Kalash feat. X", confirmedValues: [id("genre"): genre, id("attribut"): attribut])
        let resolved = resolve(Fixtures.track("t", artist: "KALASH"), stats: stats)
        #expect(resolved[id("genre")]?.source == .artist)
        #expect(resolved[id("genre")]?.value == genre)
        // attribut is not artist-level: default wins.
        #expect(resolved[id("attribut")]?.source == .default)
    }

    @Test("Explicitly empty COMMENT positions are flagged and still get suggestions")
    func explicitEmpty() {
        let resolved = resolve(Fixtures.track("t", genre: "RAP FR", comment: "() REMIX SEXY"))
        #expect(resolved[id("pays")]?.isExplicitlyEmptyInFile == true)
        #expect(resolved[id("pays")]?.state == .suggested)
        #expect(resolved.commentStatus == .conforme)
    }

    @Test("Targets and to-apply from the resolved track")
    func targets() {
        let track = Fixtures.track("t", format: "m4a", genre: "Rap Fr", comment: "8A - Energy 6", rating: 2)
        let rows = [Fixtures.row("t", "type", ["REMIX"]), Fixtures.row("t", "note", rating: 5)]
        let resolved = resolve(track, rows: rows)
        #expect(resolved.commentStatus == .nonConforme)
        #expect(resolved.commentText == "8A - Energy 6")
        #expect(resolved.targets(config: config) == Baseline(genre: "Rap Fr", comment: "() REMIX ()", rating: 2))
        #expect(resolved.isToApply(config: config))
        #expect(!resolved.hasAcceptedSuggestions)
        let accepted = resolve(track, rows: [Fixtures.row("t", "type", ["REMIX"], source: .title)])
        #expect(accepted.hasAcceptedSuggestions)
    }
}
