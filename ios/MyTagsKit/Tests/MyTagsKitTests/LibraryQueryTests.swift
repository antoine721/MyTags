import Foundation
import MyTagsKit
import Testing

@Suite("Library query")
struct LibraryQueryTests {
    static let genre = "genre"
    static let color = "color"

    static let snapshots: [TrackSnapshot] = [
        TrackSnapshot(
            id: "1", title: "Été Edit", artist: "Aya Nakamura", album: "DNK", bpm: 100, musicalKey: "8A",
            addedAt: "2026-01-01T00:00:00.000Z", rating: 5, confirmedOptionIDs: [genre: ["pop"], color: ["green"]],
            status: .envoye, isToApply: true, hasAcceptedSuggestions: true),
        TrackSnapshot(
            id: "2", title: "Djadja", artist: "aya nakamura", bpm: 95, musicalKey: "5A", addedAt: "2026-03-01T00:00:00.000Z",
            rating: 3, confirmedOptionIDs: [genre: ["rapfr"]], status: .modifie, applyStatus: .conflit, isIncomplete: true,
            commentStatus: .nonConforme),
        TrackSnapshot(
            id: "3", title: "Bande organisée", artist: "Jul feat. SCH", album: "13'Organisé", bpm: nil, musicalKey: "8A",
            addedAt: nil, rating: nil, status: .none, isIncomplete: true, isUntagged: true, isOffline: true),
        TrackSnapshot(
            id: "4", title: "Alors on danse", artist: nil, bpm: 120, rating: 4, confirmedOptionIDs: [color: ["blue"]],
            status: .applique, applyStatus: .applique, commentStatus: .conforme),
        TrackSnapshot(
            id: "5", title: "Djadja", artist: "Aya Nakamura", bpm: 95, rating: 3, confirmedOptionIDs: [genre: ["pop", "rapfr"]],
            status: .erreur, applyStatus: .erreur, isIncomplete: true),
    ]

    private func run(_ filter: LibraryFilter = LibraryFilter(), _ sort: LibrarySort = .default) -> [String] {
        LibraryQuery.run(filter: filter, sort: sort, snapshots: Self.snapshots)
    }

    @Test("Default sort: artist, then title, then id; missing artist last")
    func defaultSort() {
        #expect(run() == ["2", "5", "1", "3", "4"])
        #expect(run(LibraryFilter(), LibrarySort(key: .artist, ascending: false)) == ["3", "2", "5", "1", "4"])
    }

    @Test("Sort keys with missing values last in both directions")
    func sortKeys() {
        #expect(run(LibraryFilter(), LibrarySort(key: .bpm, ascending: true)) == ["2", "5", "1", "4", "3"])
        #expect(run(LibraryFilter(), LibrarySort(key: .bpm, ascending: false)) == ["4", "1", "2", "5", "3"])
        #expect(run(LibraryFilter(), LibrarySort(key: .rating, ascending: false)) == ["1", "4", "2", "5", "3"])
        #expect(run(LibraryFilter(), LibrarySort(key: .addedAt, ascending: false)) == ["2", "1", "5", "3", "4"])
        #expect(run(LibraryFilter(), LibrarySort(key: .title, ascending: true)) == ["4", "3", "2", "5", "1"])
    }

    @Test("Options of one field combine with or, fields with and")
    func fieldFilters() {
        #expect(run(LibraryFilter(fields: [Self.genre: FieldFilter(options: ["pop"])])) == ["5", "1"])
        #expect(run(LibraryFilter(fields: [Self.genre: FieldFilter(options: ["pop", "rapfr"])])) == ["2", "5", "1"])
        #expect(run(LibraryFilter(fields: [Self.genre: FieldFilter(options: ["pop"], empty: true)])) == ["5", "1", "3", "4"])
        #expect(
            run(LibraryFilter(fields: [Self.genre: FieldFilter(options: ["pop"]), Self.color: FieldFilter(options: ["green"])]))
                == ["1"])
        #expect(run(LibraryFilter(fields: [Self.color: FieldFilter(empty: true)])) == ["2", "5", "3"])
        #expect(run(LibraryFilter(fields: [Self.color: FieldFilter()])).count == 5)
    }

    @Test("Rating, BPM, keys and statuses")
    func scalarFilters() {
        #expect(run(LibraryFilter(minRating: 4)) == ["1", "4"])
        #expect(run(LibraryFilter(bpmMin: 96)) == ["1", "4"])
        #expect(run(LibraryFilter(bpmMin: 95, bpmMax: 100)) == ["2", "5", "1"])
        #expect(run(LibraryFilter(keys: ["8A"])) == ["1", "3"])
        #expect(run(LibraryFilter(keys: ["8a"])).isEmpty)
        #expect(run(LibraryFilter(statuses: ["modifie", "none"])) == ["2", "3"])
    }

    @Test("Special filters all have to hold")
    func specialFilters() {
        #expect(run(LibraryFilter(special: ["untagged"])) == ["3"])
        #expect(run(LibraryFilter(special: ["incomplete"])) == ["2", "5", "3"])
        #expect(run(LibraryFilter(special: ["incomplete", "offline"])) == ["3"])
        #expect(run(LibraryFilter(special: ["comment_non_conforme"])) == ["2"])
        #expect(run(LibraryFilter(special: ["to_apply"])) == ["1"])
        #expect(run(LibraryFilter(special: ["suggestions_accepted"])) == ["1"])
        #expect(run(LibraryFilter(special: ["conflict_or_error"])) == ["2", "5"])
        #expect(run(LibraryFilter(special: ["something_new"])).count == 5)
    }

    @Test("Search ignores case and accents; every term must match")
    func search() {
        #expect(run(LibraryFilter(search: "ete")) == ["1"])
        #expect(run(LibraryFilter(search: "AYA djadja")) == ["2", "5"])
        #expect(run(LibraryFilter(search: "organise")) == ["3"])
        #expect(run(LibraryFilter(search: "  sch  ")) == ["3"])
        #expect(run(LibraryFilter(search: "dnk aya")) == ["1"])
        #expect(run(LibraryFilter(search: "aya zzz")).isEmpty)
        #expect(run(LibraryFilter(search: "   ")).count == 5)
        #expect(LibraryQuery.matches(Self.snapshots[0], filter: LibraryFilter(search: "été")))
    }

    @Test("Active filter count")
    func activeCount() {
        #expect(LibraryFilter().activeCount == 0)
        #expect(LibraryFilter().isEmpty)
        #expect(!LibraryFilter(search: "x").isEmpty)
        let filter = LibraryFilter(
            fields: ["g": FieldFilter(options: ["a", "b"], empty: true), "h": FieldFilter()], minRating: 3, bpmMin: 90,
            bpmMax: 130, keys: ["8A"], statuses: ["envoye"], special: ["untagged", "unknown"], search: "x")
        #expect(filter.activeCount == 8)
    }

    @Test("Snapshot built from a track")
    func builder() {
        let config = Fixtures.config
        let track = Fixtures.track(
            "t", title: "Song", artist: "Ninho feat. Jul", format: "flac", genre: "RAP FR", comment: "8A - Energy 6",
            rating: 4, applyStatus: .applique)
        let rows = [Fixtures.row("t", "couleur", ["VERT"], source: .artist)]
        let snapshot = TrackSnapshot.build(track: track, rows: rows, config: config, hasPendingLocalChanges: false, isOffline: true)
        #expect(snapshot.primaryArtist == "Ninho")
        #expect(snapshot.rating == 4)
        #expect(snapshot.confirmedOptionIDs[Fixtures.fieldID("genre")] == [Fixtures.optionID("genre", "RAP FR")])
        #expect(snapshot.confirmedOptionIDs[Fixtures.fieldID("couleur")] == [Fixtures.optionID("couleur", "VERT")])
        #expect(snapshot.confirmedFieldIDs.contains(Fixtures.fieldID("note")))
        #expect(snapshot.commentStatus == .nonConforme)
        #expect(snapshot.isToApply)
        #expect(snapshot.status == .envoye)
        #expect(snapshot.isIncomplete && !snapshot.isUntagged)
        #expect(snapshot.isOffline && snapshot.hasAcceptedSuggestions)
        #expect(snapshot.searchKey == "song\nninho feat. jul\n")
        let pending = TrackSnapshot.build(track: track, rows: [], config: config, hasPendingLocalChanges: true)
        #expect(pending.status == .modifie)
        #expect(!pending.isToApply)
        #expect(pending.status != .applique)
    }

    @Test("Built-in views of the default configuration")
    func savedViews() throws {
        let document = try ConfigDocument.decode(from: Repo.data("shared/default-config.json"))
        let names = document.savedViews.map { view in
            (view.name, LibraryQuery.run(filter: view.filters, sort: view.sort, snapshots: Self.snapshots))
        }
        #expect(names.map(\.1) == [["2", "5", "3"], ["3"], ["1"], ["2"]])
    }

    @Test("5,000 snapshots and artist statistics build in reasonable time")
    func buildPerformance() {
        let config = Fixtures.config
        let genres = ["Rap Fr", "POP", "Techno", nil]
        let comments = ["fr extend sexy", "US REMIX ()", "8A - Energy 6", nil, "FR EDIT", "UK EDIT TIKTOK BONUS"]
        var tracks: [Track] = []
        var rows: [String: [TrackValue]] = [:]
        for index in 0..<5_000 {
            let track = Fixtures.track(
                "t\(index)", title: "Song \(index) (Extended Mix)", artist: "Artist \(index % 400) feat. X",
                genre: genres[index % 4], grouping: index % 3 == 0 ? "VERT" : nil, comment: comments[index % 6],
                rating: index % 6)
            tracks.append(track)
            if index % 2 == 0 {
                rows[track.id] = [Fixtures.row(track.id, "couleur", ["BLEU"]), Fixtures.row(track.id, "note", rating: 4)]
            }
        }
        var snapshots: [TrackSnapshot] = []
        var stats = ArtistStats()
        let elapsed = ContinuousClock().measure {
            snapshots = tracks.map { TrackSnapshot.build(track: $0, rows: rows[$0.id] ?? [], config: config) }
            stats = ArtistStats(tracks: tracks, rowsByTrack: rows, config: config)
        }
        #expect(snapshots.count == 5_000)
        #expect(stats.trackCount(artistKey: "ARTIST 7") == 13)
        #expect(snapshots.filter { $0.commentStatus == .nonConforme }.count == 1_666)
        // About 1 s in a debug build on Linux; generous bound against pathological regressions.
        #expect(elapsed < .seconds(5), "took \(elapsed)")
    }

    @Test("5,000 tracks filter and sort quickly")
    func performance() {
        let genres = ["rapfr", "rapus", "pop", "bouyon", "shatta", "zoukompa"]
        let colors = ["green", "yellow", "red", "blue", "purple"]
        let words = ["Love", "Été", "Nuit", "Club", "Remix", "Edit", "Soleil", "Bébé", "Danse", "Feu"]
        var snapshots: [TrackSnapshot] = []
        snapshots.reserveCapacity(5_000)
        for index in 0..<5_000 {
            snapshots.append(
                TrackSnapshot(
                    id: "track-\(index)",
                    title: "\(words[index % 10]) \(words[(index / 10) % 10]) \(index)",
                    artist: "Artiste \(index % 400)\(index % 3 == 0 ? " feat. Invité" : "")",
                    album: "Album \(index % 250)",
                    bpm: Double(80 + index % 70),
                    musicalKey: "\(index % 12 + 1)\(index % 2 == 0 ? "A" : "B")",
                    addedAt: "2026-\(index % 12 < 9 ? "0" : "")\(index % 12 + 1)-01T00:00:00.000Z",
                    rating: index % 6 == 0 ? nil : index % 6,
                    confirmedOptionIDs: index % 7 == 0 ? [:] : [Self.genre: [genres[index % 6]], Self.color: [colors[index % 5]]],
                    status: index % 11 == 0 ? .modifie : .none,
                    isIncomplete: index % 3 == 0,
                    isUntagged: index % 7 == 0,
                    isOffline: index % 4 == 0))
        }
        let filter = LibraryFilter(
            fields: [Self.genre: FieldFilter(options: ["rapfr", "pop"], empty: true)], minRating: 2, bpmMin: 90, bpmMax: 140,
            search: "ete")
        let clock = ContinuousClock()
        var all: [String] = []
        var filtered: [String] = []
        var sorted: [String] = []
        let elapsed = clock.measure {
            all = LibraryQuery.run(filter: LibraryFilter(), sort: .default, snapshots: snapshots)
            filtered = LibraryQuery.run(filter: filter, sort: LibrarySort(key: .bpm, ascending: false), snapshots: snapshots)
            sorted = LibraryQuery.run(
                filter: LibraryFilter(special: ["incomplete"]), sort: LibrarySort(key: .title), snapshots: snapshots)
        }
        #expect(all.count == 5_000)
        #expect(!filtered.isEmpty && filtered.count < 5_000)
        #expect(sorted.count == 1_667)
        #expect(Set(all).count == 5_000)
        // Three queries over 5,000 tracks, debug build.
        #expect(elapsed < .milliseconds(200), "took \(elapsed)")
    }
}
