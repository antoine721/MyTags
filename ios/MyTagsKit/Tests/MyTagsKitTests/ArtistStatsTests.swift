import Foundation
import MyTagsKit
import Testing

@Suite("Artist statistics")
struct ArtistStatsTests {
    let config = Fixtures.config
    var genre: String { Fixtures.fieldID("genre") }
    func value(_ name: String) -> FieldValue { .option(Fixtures.optionID("genre", name)) }

    private func stats(_ entries: [(String, String, String?)]) -> ArtistStats {
        var stats = ArtistStats()
        for (trackID, artist, genreName) in entries {
            stats.setTrack(id: trackID, artist: artist, confirmedValues: genreName.map { [genre: value($0)] } ?? [:])
        }
        return stats
    }

    @Test("Most frequent value among the other tracks, at least half of them")
    func threshold() {
        let stats = stats([("a", "Jul", "RAP FR"), ("b", "Jul", "RAP FR"), ("c", "Jul", "POP"), ("d", "Jul", nil)])
        // Other tracks of "t": 4; RAP FR covers 2 → exactly half.
        #expect(stats.suggestion(fieldID: genre, artistKey: "JUL", excludingTrackID: "t", config: config) == value("RAP FR"))
        // Asking for "d": 3 others, RAP FR covers 2.
        #expect(stats.suggestion(fieldID: genre, artistKey: "JUL", excludingTrackID: "d", config: config) == value("RAP FR"))
        // Asking for "a": its own value is excluded; 3 others with RAP FR ×1, POP ×1 → below half.
        #expect(stats.suggestion(fieldID: genre, artistKey: "JUL", excludingTrackID: "a", config: config) == nil)
        let sparse = self.stats([("a", "Jul", "RAP FR"), ("b", "Jul", nil), ("c", "Jul", nil)])
        #expect(sparse.suggestion(fieldID: genre, artistKey: "JUL", excludingTrackID: "t", config: config) == nil)
        #expect(stats.trackCount(artistKey: "JUL") == 4)
    }

    @Test("Ties go to the first value in display order")
    func ties() {
        let stats = stats([("a", "Jul", "POP"), ("b", "Jul", "RAP US")])
        #expect(stats.suggestion(fieldID: genre, artistKey: "JUL", excludingTrackID: "t", config: config) == value("RAP US"))
    }

    @Test("Tracks group by primary artist")
    func grouping() {
        let stats = stats([("a", "Ninho feat. Jul", "RAP FR"), ("b", "NINHO", "RAP FR"), ("c", "Jul & Ninho", "POP")])
        let key = ArtistStats.artistKey(for: "Ninho x Damso")
        #expect(key == "NINHO")
        #expect(stats.trackCount(artistKey: key) == 2)
        #expect(stats.suggestion(fieldID: genre, artistKey: key, excludingTrackID: nil, config: config) == value("RAP FR"))
        #expect(Set(stats.artistKeys) == ["NINHO", "JUL"])
    }

    @Test("Incremental updates")
    func updates() {
        var stats = stats([("a", "Jul", "POP"), ("b", "Jul", "POP")])
        stats.setTrack(id: "b", artist: "Jul", confirmedValues: [genre: value("RAP FR")])
        stats.setTrack(id: "c", artist: "Jul", confirmedValues: [genre: value("RAP FR")])
        #expect(stats.suggestion(fieldID: genre, artistKey: "JUL", excludingTrackID: "t", config: config) == value("RAP FR"))
        stats.removeTrack(id: "c")
        stats.removeTrack(id: "b")
        stats.removeTrack(id: "missing")
        #expect(stats.trackCount(artistKey: "JUL") == 1)
        #expect(stats.suggestion(fieldID: genre, artistKey: "JUL", excludingTrackID: "t", config: config) == value("POP"))
        stats.removeTrack(id: "a")
        #expect(stats.trackCount(artistKey: "JUL") == 0)
        #expect(stats.suggestion(fieldID: genre, artistKey: "JUL", excludingTrackID: "t", config: config) == nil)
    }

    @Test("Unknown artists, lone tracks and archived values give nothing")
    func nothing() throws {
        let stats = stats([("a", "", "POP"), ("b", "Solo", "POP")])
        #expect(stats.suggestion(fieldID: genre, artistKey: "", excludingTrackID: "t", config: config) == nil)
        #expect(stats.suggestion(fieldID: genre, artistKey: "SOLO", excludingTrackID: "b", config: config) == nil)

        var document = try ConfigDocument.decode(from: Repo.data("shared/default-config.json"))
        for index in document.fieldOptions.indices where document.fieldOptions[index].value == "POP" {
            document.fieldOptions[index].archived = true
        }
        let archived = TagConfig(document: document)
        #expect(stats.suggestion(fieldID: genre, artistKey: "SOLO", excludingTrackID: "t", config: archived) == nil)
    }

    @Test("Built from tracks and rows, file values included")
    func build() {
        let tracks = [
            Fixtures.track("a", artist: "Jul", genre: "rap fr"),
            Fixtures.track("b", artist: "Jul"),
            Fixtures.track("c", artist: "Jul", genre: "POP"),
            Track(id: "gone", artist: "Jul", baseline: Baseline(genre: "POP"), deletedAt: "2026-10-08T00:00:00.000Z"),
        ]
        let rows = ["b": [Fixtures.row("b", "genre", ["RAP FR"])], "c": [Fixtures.row("c", "genre")]]
        let stats = ArtistStats(tracks: tracks, rowsByTrack: rows, config: config)
        #expect(stats.trackCount(artistKey: "JUL") == 3)
        #expect(stats.suggestion(fieldID: genre, artistKey: "JUL", excludingTrackID: "c", config: config) == value("RAP FR"))
        let resolved = ValueResolver.resolve(
            track: tracks[2], rows: rows["c"] ?? [], config: config, suggestionContext: SuggestionContext(artistStats: stats))
        // "c" was cleared on purpose: no suggestion.
        #expect(resolved[genre]?.state == .empty)
        let fresh = ValueResolver.resolve(
            track: Fixtures.track("d", artist: "Jul"), rows: [], config: config,
            suggestionContext: SuggestionContext(artistStats: stats))
        #expect(fresh[genre]?.state == .suggested && fresh[genre]?.source == .artist)
    }
}
