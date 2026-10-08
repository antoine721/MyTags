import Foundation
import MyTagsKit
import Testing
@testable import MyTags

/// The Library opens on the view worth tagging, and tagging from it follows its own options (spec 9.5).
@MainActor
@Suite struct LibraryModelTests {
    let store: LibraryStore
    let defaults: UserDefaults

    init() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString).sqlite")
        let database = try AppDatabase(url: url)
        let data = try Data(contentsOf: try #require(Bundle.main.url(forResource: "default-config", withExtension: "json")))
        let config = try ConfigDocument.decode(from: data)
        try database.saveConfig(DirtyConfig(fields: config.fields, fieldOptions: config.fieldOptions, rules: config.rules,
                                            savedViews: config.savedViews, settings: config.settings), dirty: false)
        var batch = PullBatch()
        batch.tracks = [Track(id: "t1", title: "Song", artist: "Artist", durationMs: 200_000,
                              updatedAt: "2026-10-08T00:00:00.000Z")]
        _ = try database.apply(batch)
        store = LibraryStore(database: database, deviceID: "test")
        await store.load()
        defaults = try #require(UserDefaults(suiteName: "library-\(UUID().uuidString)"))
    }

    @Test func opensOnToComplete() throws {
        let model = LibraryModel(defaults: defaults)
        model.restoreView(store: store)
        let view = try #require(model.selectedView(store: store))
        #expect(view.name == "À compléter")
        #expect(view.skipComplete)
        model.refresh(store: store)
        #expect(model.results == ["t1"])
    }

    @Test func remembersTheLastView() throws {
        let untagged = try #require(store.document.savedViews.first { $0.name == "Non tagués" })
        LibraryModel(defaults: defaults).apply(untagged)
        let model = LibraryModel(defaults: defaults)
        model.restoreView(store: store)
        #expect(model.selectedViewID == untagged.id)
        #expect(model.selectedView(store: store)?.skipComplete == false)
    }

    @Test func keepsWhatTheUserAlreadyChose() {
        let model = LibraryModel(defaults: defaults)
        model.searchText = "song"
        model.restoreView(store: store)
        #expect(model.selectedViewID == nil)
    }
}

/// Demo tracks start inside their generated audio: a start point past the end used to end
/// the item at once and race through the queue.
@Suite struct DemoDataTests {
    @Test func startPointsAreInsideTheGeneratedAudio() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "demo-\(UUID().uuidString).sqlite")
        let database = try AppDatabase(url: url)
        DemoData.install(into: database)
        let tracks = try database.loadAll().tracks
        #expect(!tracks.isEmpty)
        for track in tracks {
            #expect(track.durationMs == Int(DemoAudio.seconds * 1_000))
            #expect((track.startMs ?? 0) < (track.durationMs ?? 0) - 1_000)
        }
    }
}
