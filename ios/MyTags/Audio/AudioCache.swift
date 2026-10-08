import Foundation
import GRDB
import Observation

/// Local audio files (spec section 10, "Cache").
///
/// Two spaces: the automatic cache, capped and emptied least-recently-played first, and the
/// prepared trips, pinned and counted apart. Files live in Application Support (never purged by
/// iOS) and are excluded from iCloud backups.
@MainActor
@Observable
final class AudioCache {
    enum Kind: String {
        case auto, trip
    }

    private(set) var autoBytes: Int64 = 0
    private(set) var tripBytes: Int64 = 0
    private(set) var offlineIDs: Set<String> = []
    private(set) var tripIDs: Set<String> = []

    @ObservationIgnored let folder: URL
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored var limitBytes: Int64 = 1_000_000_000
    @ObservationIgnored var onChange: ((Set<String>) -> Void)?

    init(database: AppDatabase) throws {
        self.database = database
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        folder = base.appending(path: "MyTags/Audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        reload()
    }

    func fileURL(for trackID: String) -> URL {
        folder.appending(path: "\(trackID).m4a")
    }

    /// The local file if the track is available offline.
    func localURL(for trackID: String) -> URL? {
        guard offlineIDs.contains(trackID) else { return nil }
        let url = fileURL(for: trackID)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        forget(trackID)
        return nil
    }

    /// Moves a finished download into the cache.
    func store(trackID: String, downloadedFile: URL, kind: Kind) throws {
        let target = fileURL(for: trackID)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: downloadedFile, to: target)
        let bytes = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let existingKind = tripIDs.contains(trackID) ? Kind.trip : kind
        try database.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cache_entries (track_id, kind, bytes, last_used, pinned_at) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(track_id) DO UPDATE SET bytes = excluded.bytes, kind = excluded.kind,
                      pinned_at = COALESCE(cache_entries.pinned_at, excluded.pinned_at)
                    """,
                arguments: [trackID, existingKind.rawValue, bytes, Date().timeIntervalSince1970,
                            existingKind == .trip ? Date().timeIntervalSince1970 : nil])
        }
        reload()
    }

    /// Marks a track as just played (eviction order, trip expiry).
    func touch(_ trackID: String) {
        guard offlineIDs.contains(trackID) else { return }
        try? database.pool.write { db in
            try db.execute(
                sql: "UPDATE cache_entries SET last_used = ? WHERE track_id = ?",
                arguments: [Date().timeIntervalSince1970, trackID])
        }
    }

    /// Pins tracks as a prepared trip (files already cached move from the automatic space).
    func pin(_ trackIDs: [String]) {
        let now = Date().timeIntervalSince1970
        try? database.pool.write { db in
            for id in trackIDs {
                try db.execute(
                    sql: "UPDATE cache_entries SET kind = 'trip', pinned_at = ?, last_used = ? WHERE track_id = ?",
                    arguments: [now, now, id])
            }
        }
        tripIDs.formUnion(trackIDs)
        reload()
    }

    func unpinAll() {
        try? database.pool.write { db in
            try db.execute(sql: "UPDATE cache_entries SET kind = 'auto', pinned_at = NULL WHERE kind = 'trip'")
        }
        reload()
        evict(protecting: [])
    }

    /// Trips not played for `days` go back to the automatic cache.
    func expireTrips(olderThan days: Int) {
        let limit = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970
        try? database.pool.write { db in
            try db.execute(
                sql: "UPDATE cache_entries SET kind = 'auto', pinned_at = NULL WHERE kind = 'trip' AND last_used < ?",
                arguments: [limit])
        }
        reload()
    }

    /// Keeps the automatic cache under its cap, oldest played first, never touching `protecting`.
    func evict(protecting: Set<String>) {
        guard autoBytes > limitBytes else { return }
        let rows = (try? database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT track_id, bytes FROM cache_entries WHERE kind = 'auto' ORDER BY last_used")
        }) ?? []
        var total = autoBytes
        var removed: [String] = []
        for row in rows where total > limitBytes {
            let id: String = row["track_id"]
            if protecting.contains(id) { continue }
            try? FileManager.default.removeItem(at: fileURL(for: id))
            removed.append(id)
            total -= row["bytes"] as Int64
        }
        guard !removed.isEmpty else { return }
        try? database.pool.write { db in
            for id in removed {
                try db.execute(sql: "DELETE FROM cache_entries WHERE track_id = ?", arguments: [id])
            }
        }
        reload()
    }

    func clearAutomatic() {
        let ids = (try? database.pool.read { db in
            try String.fetchAll(db, sql: "SELECT track_id FROM cache_entries WHERE kind = 'auto'")
        }) ?? []
        for id in ids {
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }
        try? database.pool.write { db in try db.execute(sql: "DELETE FROM cache_entries WHERE kind = 'auto'") }
        reload()
    }

    func clearEverything() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? database.pool.write { db in try db.execute(sql: "DELETE FROM cache_entries") }
        reload()
    }

    private func forget(_ trackID: String) {
        try? database.pool.write { db in
            try db.execute(sql: "DELETE FROM cache_entries WHERE track_id = ?", arguments: [trackID])
        }
        reload()
    }

    private func reload() {
        let rows = (try? database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT track_id, kind, bytes FROM cache_entries")
        }) ?? []
        var auto: Int64 = 0
        var trip: Int64 = 0
        var ids = Set<String>()
        var trips = Set<String>()
        for row in rows {
            let id: String = row["track_id"]
            let bytes: Int64 = row["bytes"]
            ids.insert(id)
            if (row["kind"] as String) == Kind.trip.rawValue {
                trip += bytes
                trips.insert(id)
            } else {
                auto += bytes
            }
        }
        autoBytes = auto
        tripBytes = trip
        tripIDs = trips
        if ids != offlineIDs {
            offlineIDs = ids
            onChange?(ids)
        }
    }
}
