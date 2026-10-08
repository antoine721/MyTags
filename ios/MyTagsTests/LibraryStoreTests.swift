import Foundation
import MyTagsKit
import Testing
@testable import MyTags

/// The in-memory store follows the database and recomputes snapshots after each edit.
@MainActor
@Suite struct LibraryStoreTests {
    let database: AppDatabase
    let store: LibraryStore
    let config: ConfigDocument

    init() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "store-\(UUID().uuidString).sqlite")
        database = try AppDatabase(url: url)
        let data = try Data(contentsOf: try #require(Bundle.main.url(forResource: "default-config", withExtension: "json")))
        config = try ConfigDocument.decode(from: data)
        try database.saveConfig(DirtyConfig(fields: config.fields, fieldOptions: config.fieldOptions, rules: config.rules,
                                            savedViews: config.savedViews, settings: config.settings), dirty: false)
        var batch = PullBatch()
        batch.tracks = [Track(id: "t1", title: "Song (Extended Mix)", artist: "Artist", durationMs: 200_000,
                              baseline: Baseline(genre: "RAP FR"), updatedAt: "2026-10-08T00:00:00.000Z")]
        _ = try database.apply(batch)
        store = LibraryStore(database: database, deviceID: "test")
        await store.load()
    }

    @Test func loadsTracksAndConfig() {
        #expect(store.tracks.count == 1)
        #expect(store.config.fields.count == 6)
        #expect(store.snapshots["t1"]?.isIncomplete == true)
    }

    @Test func editsArePersistedBeforeMemory() throws {
        let couleur = try #require(store.config.field(key: "couleur"))
        let vert = try #require(store.config.option(fieldID: couleur.id, value: "VERT"))
        #expect(store.apply([ValueEdit(trackID: "t1", fieldID: couleur.id, value: .option(vert.id), source: .user)]))
        #expect(store.rows["t1"]?[couleur.id]?.optionIDs == [vert.id])
        #expect(store.pendingTrackIDs == ["t1"])
        #expect(store.snapshots["t1"]?.status == .modifie)
        let onDisk = try database.loadAll()
        #expect(onDisk.values.contains { $0.fieldID == couleur.id && $0.optionIDs == [vert.id] })
        #expect(onDisk.pendingCount == 1)
    }

    @Test func titleRuleSuggestsType() throws {
        let type = try #require(store.config.field(key: "type"))
        let extend = try #require(store.config.option(fieldID: type.id, value: "EXTEND"))
        let resolved = try #require(store.resolve("t1"))
        #expect(resolved[type.id]?.state == .suggested)
        #expect(resolved[type.id]?.value.optionIDs == [extend.id])
    }
}
