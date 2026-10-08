import Foundation
import MyTagsKit
import Testing
@testable import MyTags

/// Local storage: every edit and its journal entry survive a restart (R7), resends never duplicate.
@Suite struct AppDatabaseTests {
    let url: URL
    let database: AppDatabase

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "mytags-\(UUID().uuidString).sqlite")
        database = try AppDatabase(url: url)
    }

    private func change(_ id: String, track: String = "t1", field: String = "f1", option: String, at time: String) -> PendingChange {
        PendingChange(id: id, trackID: track, fieldID: field, oldValue: nil, newValue: .option(option), createdAt: time)
    }

    @Test func editsSurviveARestart() throws {
        let row = TrackValue(trackID: "t1", fieldID: "f1", value: .option("o1"), updatedAt: "2026-10-08T10:00:00.000Z")
        try database.record(rows: [row], changes: [change("c1", option: "o1", at: "2026-10-08T10:00:00.000Z")])
        let reopened = try AppDatabase(url: url)
        let state = try reopened.loadAll()
        #expect(state.values.map(\.optionIDs) == [["o1"]])
        #expect(state.pendingTrackIDs == ["t1"])
        #expect(try reopened.pendingChanges().map(\.id) == ["c1"])
    }

    @Test func sentChangesAreNotResent() throws {
        try database.record(rows: [], changes: [
            change("c1", option: "o1", at: "2026-10-08T10:00:00.000Z"),
            change("c2", option: "o2", at: "2026-10-08T10:00:01.000Z"),
        ])
        try database.markSent(ids: ["c1", "c2"])
        #expect(try database.pendingChanges().isEmpty)
        #expect(try database.pendingSummary().count == 0)
    }

    @Test func coalescingKeepsTheLastValuePerField() throws {
        try database.record(rows: [], changes: [
            change("c1", option: "o1", at: "2026-10-08T10:00:00.000Z"),
            change("c2", option: "o2", at: "2026-10-08T10:00:01.000Z"),
            change("c3", field: "f2", option: "o9", at: "2026-10-08T10:00:02.000Z"),
        ])
        let coalesced = ChangeCoalescer.coalesce(try database.pendingChanges())
        #expect(coalesced.count == 2)
        #expect(coalesced.first { $0.fieldID == "f1" }?.newValue?.optionIDs == ["o2"])
    }

    @Test func pullKeepsValuesEditedLocally() throws {
        try database.record(
            rows: [TrackValue(trackID: "t1", fieldID: "f1", value: .option("mine"), updatedAt: "2026-10-08T10:00:00.000Z")],
            changes: [change("c1", option: "mine", at: "2026-10-08T10:00:00.000Z")])
        var batch = PullBatch()
        batch.values = [
            TrackValue(trackID: "t1", fieldID: "f1", value: .option("server"), updatedAt: "2026-10-08T09:00:00.000Z"),
            TrackValue(trackID: "t2", fieldID: "f1", value: .option("server"), updatedAt: "2026-10-08T09:00:00.000Z"),
        ]
        batch.cursors = ["track_values": SyncCursor(rev: 4, rowid: 9)]
        let applied = try database.apply(batch)
        #expect(applied.values.map(\.trackID) == ["t2"])
        let values = Dictionary(uniqueKeysWithValues: try database.loadAll().values.map { ($0.trackID, $0.optionIDs) })
        #expect(values["t1"] == ["mine"])
        #expect(values["t2"] == ["server"])
        #expect(try database.cursors()["track_values"] == SyncCursor(rev: 4, rowid: 9))
    }

    @Test func localConfigEditWinsOverOlderServerRow() throws {
        let local = Field(id: "f1", key: "genre", name: "Mon genre", kind: .single, targetTag: .genre,
                          updatedAt: "2026-10-08T12:00:00.000Z")
        try database.saveConfig(DirtyConfig(fields: [local]))
        var batch = PullBatch()
        batch.fields = [Field(id: "f1", key: "genre", name: "Genre", kind: .single, targetTag: .genre,
                              updatedAt: "2026-10-08T11:00:00.000Z")]
        _ = try database.apply(batch)
        #expect(try database.loadConfigDocument().fields.first?.name == "Mon genre")
        #expect(try database.dirtyConfig().fields.count == 1)
        try database.markConfigPushed(try database.dirtyConfig())
        #expect(try database.dirtyConfig().isEmpty)
    }
}
