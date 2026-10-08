import Foundation
import Testing
@testable import MyTags

/// The automatic cache stays under its cap, least recently played first; trips are pinned.
@MainActor
@Suite struct AudioCacheTests {
    let cache: AudioCache
    let folder: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)")
        folder = base.appending(path: "Audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let database = try AppDatabase(url: base.appending(path: "db.sqlite"))
        cache = try AudioCache(database: database, folder: folder)
    }

    private func add(_ id: String, kind: AudioCache.Kind = .auto, bytes: Int = 400_000) throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4a")
        try Data(count: bytes).write(to: file)
        try cache.store(trackID: id, downloadedFile: file, kind: kind)
    }

    @Test func evictsLeastRecentlyPlayedFirst() throws {
        cache.limitBytes = 1_000_000
        try add("a")
        try add("b")
        try add("c")
        cache.touch("a")
        cache.evict(protecting: [])
        #expect(cache.offlineIDs == ["a", "c"])
        #expect(cache.autoBytes <= 1_000_000)
    }

    @Test func neverEvictsProtectedOrPinnedTracks() throws {
        cache.limitBytes = 500_000
        try add("trip", kind: .trip)
        try add("current")
        try add("old")
        cache.evict(protecting: ["current"])
        #expect(cache.offlineIDs.contains("trip"))
        #expect(cache.offlineIDs.contains("current"))
        #expect(!cache.offlineIDs.contains("old"))
        #expect(cache.tripBytes == 400_000)
    }

    @Test func localURLOnlyForStoredFiles() throws {
        try add("x")
        #expect(cache.localURL(for: "x") != nil)
        #expect(cache.localURL(for: "y") == nil)
        try FileManager.default.removeItem(at: cache.fileURL(for: "x"))
        #expect(cache.localURL(for: "x") == nil)
        #expect(!cache.offlineIDs.contains("x"))
    }
}
