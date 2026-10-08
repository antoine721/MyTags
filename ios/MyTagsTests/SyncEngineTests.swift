import Foundation
import MyTagsKit
import Testing
@testable import MyTags

/// Worker stand-in: records accepted pushes, refuses some rows with a 400, serves one pull page.
actor FakeSyncAPI: SyncAPI {
    private(set) var pushes: [PushBody] = []
    private(set) var pushRequests = 0
    private(set) var pulls = 0
    private let pushError: APIError?
    /// A push holding one of these (change track id, or configuration row id or key) is refused.
    private let refusedIDs: Set<String>
    private let pullJSON: String

    init(pushError: APIError? = nil, refusedIDs: Set<String> = [], pullJSON: String = #"{"tables":{},"server_rev":1}"#) {
        self.pushError = pushError
        self.refusedIDs = refusedIDs
        self.pullJSON = pullJSON
    }

    func pull(cursors: [String: SyncCursor], limit: Int) async throws -> PullResponse {
        pulls += 1
        return try JSONDecoder().decode(PullResponse.self, from: Data(pullJSON.utf8))
    }

    func push(_ body: PushBody) async throws -> PushResponse {
        pushRequests += 1
        if let pushError { throw pushError }
        let tables = [body.changes.count, body.fields.count, body.fieldOptions.count, body.rules.count,
                      body.savedViews.count, body.settings.count]
        if tables.contains(where: { $0 > 500 }) { throw APIError.http(413, "at most 500 items per request") }
        let ids = body.changes.map(\.trackID) + body.fields.map(\.id) + body.settings.map(\.key)
        if ids.contains(where: refusedIDs.contains) { throw APIError.http(400, "invalid row") }
        pushes.append(body)
        return PushResponse(acceptedChanges: body.changes.map(\.id))
    }
}

/// Sync robustness: a refused push never blocks the pull, the Worker limits are respected,
/// refused rows are isolated and kept, and one unreadable pulled row never blocks a page.
@MainActor
@Suite struct SyncEngineTests {
    let database: AppDatabase
    let store: LibraryStore

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "sync-\(UUID().uuidString).sqlite")
        database = try AppDatabase(url: url)
        store = LibraryStore(database: database, deviceID: "test")
    }

    private func recordChanges(tracks: [String]) throws {
        let changes = tracks.enumerated().map { index, track in
            PendingChange(id: "c-\(track)", trackID: track, fieldID: "f1", oldValue: nil, newValue: .option("o1"),
                          createdAt: String(format: "2026-10-08T10:%02d:%02d.000Z", index / 60 % 60, index % 60))
        }
        try database.record(rows: [], changes: changes)
    }

    private func engine(_ api: FakeSyncAPI) async -> SyncEngine {
        await store.load()
        let sync = SyncEngine(store: store)
        sync.configure(api: api)
        return sync
    }

    @Test func pullRunsWhenPushFails() async throws {
        try recordChanges(tracks: ["t1"])
        let api = FakeSyncAPI(
            pushError: .http(500, "boom"),
            pullJSON: """
                {"tables":{"tracks":{"rows":[{"id":"t9","title":"Pulled","updated_at":"2026-10-08T10:00:00.000Z"}],
                "cursor":{"rev":3,"rowid":1},"has_more":false}},"server_rev":3}
                """)
        let sync = await engine(api)
        await sync.sync()
        #expect(await api.pulls == 1)
        #expect(store.tracks["t9"]?.title == "Pulled")
        #expect(try database.cursors()["tracks"] == SyncCursor(rev: 3, rowid: 1))
        #expect(try database.pendingChanges().map(\.id) == ["c-t1"])
        #expect(sync.lastError != nil)
    }

    @Test func pushRespectsTheWorkerLimits() async throws {
        try recordChanges(tracks: (0..<600).map { "t\($0)" })
        let settings = (0..<700).map {
            SettingRow(key: "k\($0)", value: .string("v"), updatedAt: "2026-10-08T10:00:00.000Z")
        }
        try database.saveConfig(DirtyConfig(settings: settings))
        let api = FakeSyncAPI()
        let sync = await engine(api)
        await sync.sync(pull: false)
        let pushes = await api.pushes
        #expect(await api.pushRequests == pushes.count)  // no 413
        #expect(pushes.allSatisfy { $0.changes.count <= 500 && $0.settings.count <= 500 })
        #expect(pushes.reduce(0) { $0 + $1.changes.count } == 600)
        #expect(pushes.reduce(0) { $0 + $1.settings.count } == 700)
        #expect(try database.pendingChanges().isEmpty)
        #expect(try database.dirtyConfig().isEmpty)
        #expect(sync.lastError == nil)
    }

    @Test func refusedRowsAreIsolatedAndKept() async throws {
        try recordChanges(tracks: (0..<10).map { "t\($0)" })
        let fields = ["fa", "fbad", "fc"].map {
            Field(id: $0, key: $0, kind: .single, targetTag: .grouping, updatedAt: "2026-10-08T10:00:00.000Z")
        }
        try database.saveConfig(DirtyConfig(fields: fields))
        let api = FakeSyncAPI(refusedIDs: ["t3", "fbad"])
        let sync = await engine(api)
        await sync.sync(pull: false)

        let pushes = await api.pushes
        #expect(Set(pushes.flatMap(\.changes).map(\.trackID)) == Set((0..<10).map { "t\($0)" }).subtracting(["t3"]))
        #expect(Set(pushes.flatMap(\.fields).map(\.id)) == ["fa", "fc"])
        #expect(sync.rejectedCount == 2)
        #expect(store.pendingCount == 0)
        #expect(try database.pendingChanges().isEmpty)
        #expect(try database.dirtyConfig().isEmpty)
        #expect(sync.lastError == nil)

        // Kept out of the next pushes...
        let requests = await api.pushRequests
        await sync.sync(pull: false)
        #expect(await api.pushRequests == requests)
        // ...and offered again at the next launch, without being lost.
        sync.configure(api: api)
        #expect(try database.pendingChanges().map(\.id) == ["c-t3"])
        #expect(try database.dirtyConfig().fields.map(\.id) == ["fbad"])
        await sync.sync(pull: false)
        #expect(try database.pendingChanges().isEmpty)
        #expect(sync.rejectedCount == 2)
        #expect(try database.hasUnsentEdits())
    }

    @Test func unreadablePulledRowIsSkipped() throws {
        let json = """
            {"tables":{"fields":{"rows":[
              {"id":"f1","key":"genre","kind":"single","target_tag":"GENRE","updated_at":"2026-10-08T10:00:00.000Z"},
              {"id":"f2","key":"tempo","kind":"slider","target_tag":"GENRE","updated_at":"2026-10-08T10:00:00.000Z"},
              {"id":"f3","key":"type","kind":"multi","target_tag":"GROUPING","updated_at":"2026-10-08T10:00:00.000Z"}
            ],"cursor":{"rev":7,"rowid":3},"has_more":true}},"server_rev":7}
            """
        let page = try #require(try JSONDecoder().decode(PullResponse.self, from: Data(json.utf8)).tables.fields)
        #expect(page.rows.map(\.id) == ["f1", "f3"])
        #expect(page.skipped == 1)
        #expect(page.cursor == SyncCursor(rev: 7, rowid: 3))
        #expect(page.hasMore)
    }

    @Test func resetKeepsUnsentEdits() throws {
        try database.record(
            rows: [TrackValue(trackID: "t1", fieldID: "f1", value: .option("o1"), updatedAt: "2026-10-08T10:00:00.000Z"),
                   TrackValue(trackID: "t2", fieldID: "f1", value: .option("o2"), updatedAt: "2026-10-08T10:00:00.000Z")],
            changes: [PendingChange(id: "c1", trackID: "t1", fieldID: "f1", oldValue: nil, newValue: .option("o1"),
                                    createdAt: "2026-10-08T10:00:00.000Z"),
                      PendingChange(id: "c2", trackID: "t2", fieldID: "f1", oldValue: nil, newValue: .option("o2"),
                                    createdAt: "2026-10-08T10:00:00.000Z")])
        try database.markSent(ids: ["c2"])
        try database.reset(keepingUnsent: true)
        #expect(try database.pendingChanges().map(\.id) == ["c1"])
        #expect(try database.loadAll().values.map(\.trackID) == ["t1"])
        try database.reset()
        #expect(try database.hasUnsentEdits() == false)
    }
}
