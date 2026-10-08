import Foundation
import GRDB
import MyTagsKit

/// Local copy of the cloud data plus the change journal (spec sections 6 and 11).
///
/// Rows are stored as the JSON shape of the API (MyTagsKit models), keyed by their ids. Every
/// edit is written together with its journal entry in one transaction, before the UI reports it
/// as done (rule R7). The class is thread-safe; its methods can be called from any actor.
final class AppDatabase: Sendable {
    let pool: DatabasePool

    init(url: URL) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // An edit must survive a crash or a power loss right after the tap.
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        try Self.migrator.migrate(pool)
    }

    static func defaultURL() throws -> URL {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "MyTags", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return folder.appending(path: "mytags.sqlite")
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE tracks (id TEXT PRIMARY KEY NOT NULL, json BLOB NOT NULL);
                CREATE TABLE track_values (
                  track_id TEXT NOT NULL, field_id TEXT NOT NULL, json BLOB NOT NULL,
                  PRIMARY KEY (track_id, field_id));
                CREATE TABLE config_rows (
                  kind TEXT NOT NULL, id TEXT NOT NULL, json BLOB NOT NULL, dirty INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY (kind, id));
                CREATE TABLE journal (
                  id TEXT PRIMARY KEY NOT NULL, track_id TEXT NOT NULL, field_id TEXT NOT NULL,
                  json BLOB NOT NULL, status TEXT NOT NULL DEFAULT 'pending', created_at TEXT NOT NULL,
                  sent_at TEXT);
                CREATE INDEX journal_status ON journal (status, track_id, field_id);
                CREATE TABLE cursors (name TEXT PRIMARY KEY NOT NULL, rev INTEGER NOT NULL, rowid INTEGER NOT NULL);
                CREATE TABLE cache_entries (
                  track_id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, bytes INTEGER NOT NULL,
                  last_used REAL NOT NULL, pinned_at REAL);
                CREATE TABLE sessions (id TEXT PRIMARY KEY NOT NULL, started_at TEXT NOT NULL, json BLOB NOT NULL);
                CREATE TABLE kv (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);
                """)
        }
        return migrator
    }
}

// MARK: - Loading

enum ConfigKind: String, CaseIterable, Sendable {
    case fields
    case fieldOptions = "field_options"
    case rules
    case savedViews = "saved_views"
    case settings
}

struct LoadedState: Sendable {
    var tracks: [Track] = []
    var values: [TrackValue] = []
    var document = ConfigDocument(fields: [], fieldOptions: [], rules: [], savedViews: [], settings: [])
    var pendingTrackIDs: Set<String> = []
    var pendingCount = 0
}

extension AppDatabase {
    func loadAll() throws -> LoadedState {
        try pool.read { db in
            let decoder = JSONDecoder()
            var state = LoadedState()
            state.tracks = try Row.fetchAll(db, sql: "SELECT json FROM tracks").compactMap {
                try? decoder.decode(Track.self, from: $0["json"] as Data)
            }
            state.values = try Row.fetchAll(db, sql: "SELECT json FROM track_values").compactMap {
                try? decoder.decode(TrackValue.self, from: $0["json"] as Data)
            }
            state.document = try Self.document(db, decoder: decoder)
            let pending = try String.fetchAll(db, sql: "SELECT DISTINCT track_id FROM journal WHERE status = 'pending'")
            state.pendingTrackIDs = Set(pending)
            state.pendingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal WHERE status = 'pending'") ?? 0
            return state
        }
    }

    func loadConfigDocument() throws -> ConfigDocument {
        try pool.read { db in try Self.document(db, decoder: JSONDecoder()) }
    }

    var isEmpty: Bool {
        (try? pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM config_rows") ?? 0 }) == 0
    }

    private static func document(_ db: Database, decoder: JSONDecoder) throws -> ConfigDocument {
        var document = ConfigDocument(fields: [], fieldOptions: [], rules: [], savedViews: [], settings: [])
        for row in try Row.fetchAll(db, sql: "SELECT kind, json FROM config_rows") {
            let data: Data = row["json"]
            switch ConfigKind(rawValue: row["kind"]) {
            case .fields: if let v = try? decoder.decode(Field.self, from: data) { document.fields.append(v) }
            case .fieldOptions: if let v = try? decoder.decode(FieldOption.self, from: data) { document.fieldOptions.append(v) }
            case .rules: if let v = try? decoder.decode(Rule.self, from: data) { document.rules.append(v) }
            case .savedViews: if let v = try? decoder.decode(SavedView.self, from: data) { document.savedViews.append(v) }
            case .settings: if let v = try? decoder.decode(SettingRow.self, from: data) { document.settings.append(v) }
            case nil: break
            }
        }
        return document
    }
}

// MARK: - Edits and journal

extension AppDatabase {
    /// Stores rows and their journal entries atomically (rule R7).
    func record(rows: [TrackValue], changes: [PendingChange]) throws {
        let encoder = AppDatabase.makeEncoder()
        try pool.write { db in
            for row in rows {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO track_values (track_id, field_id, json) VALUES (?, ?, ?)",
                    arguments: [row.trackID, row.fieldID, try encoder.encode(row)])
            }
            for change in changes {
                try db.execute(
                    sql: "INSERT INTO journal (id, track_id, field_id, json, created_at) VALUES (?, ?, ?, ?, ?)",
                    arguments: [change.id, change.trackID, change.fieldID, try encoder.encode(change), change.createdAt])
            }
        }
    }

    func pendingChanges(limit: Int = 5_000) throws -> [PendingChange] {
        try pool.read { db in
            let decoder = JSONDecoder()
            return try Row.fetchAll(
                db, sql: "SELECT json FROM journal WHERE status = 'pending' ORDER BY created_at, rowid LIMIT ?",
                arguments: [limit]
            ).compactMap { try? decoder.decode(PendingChange.self, from: $0["json"] as Data) }
        }
    }

    func markSent(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let now = Timestamp.string(from: Date())
        try pool.write { db in
            for chunk in ids.chunked(into: 500) {
                let marks = databaseQuestionMarks(count: chunk.count)
                try db.execute(
                    sql: "UPDATE journal SET status = 'sent', sent_at = ? WHERE id IN (\(marks))",
                    arguments: StatementArguments([now] + chunk))
            }
            // Keep a month of history; older sent entries are only noise.
            let limit = Timestamp.string(from: Date().addingTimeInterval(-30 * 86_400))
            try db.execute(sql: "DELETE FROM journal WHERE status = 'sent' AND created_at < ?", arguments: [limit])
        }
    }

    func pendingSummary() throws -> (trackIDs: Set<String>, count: Int) {
        try pool.read { db in
            let ids = try String.fetchAll(db, sql: "SELECT DISTINCT track_id FROM journal WHERE status = 'pending'")
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal WHERE status = 'pending'") ?? 0
            return (Set(ids), count)
        }
    }
}

// MARK: - Pull

struct PullBatch: Sendable {
    var tracks: [Track] = []
    var values: [TrackValue] = []
    var fields: [Field] = []
    var fieldOptions: [FieldOption] = []
    var rules: [Rule] = []
    var savedViews: [SavedView] = []
    var settings: [SettingRow] = []
    var cursors: [String: SyncCursor] = [:]

    var isEmpty: Bool {
        tracks.isEmpty && values.isEmpty && fields.isEmpty && fieldOptions.isEmpty && rules.isEmpty
            && savedViews.isEmpty && settings.isEmpty
    }
}

/// What a pull actually changed locally (rows skipped because of local edits are left out).
struct AppliedPull: Sendable {
    var tracks: [Track] = []
    var values: [TrackValue] = []
    var configChanged = false
}

extension AppDatabase {
    func cursors() throws -> [String: SyncCursor] {
        try pool.read { db in
            var out: [String: SyncCursor] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT name, rev, rowid FROM cursors") {
                out[row["name"]] = SyncCursor(rev: row["rev"], rowid: row["rowid"])
            }
            return out
        }
    }

    /// Stores a pulled page. Values with a pending local edit and config rows edited locally
    /// after the server version are kept (the local edit is pushed next).
    func apply(_ batch: PullBatch) throws -> AppliedPull {
        let encoder = AppDatabase.makeEncoder()
        let decoder = JSONDecoder()
        return try pool.write { db in
            var applied = AppliedPull()
            for track in batch.tracks {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO tracks (id, json) VALUES (?, ?)",
                    arguments: [track.id, try encoder.encode(track)])
                applied.tracks.append(track)
            }
            for value in batch.values {
                let pending = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM journal WHERE status = 'pending' AND track_id = ? AND field_id = ?)",
                    arguments: [value.trackID, value.fieldID]) ?? false
                if pending { continue }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO track_values (track_id, field_id, json) VALUES (?, ?, ?)",
                    arguments: [value.trackID, value.fieldID, try encoder.encode(value)])
                applied.values.append(value)
            }
            func upsertConfig<T: Encodable>(_ kind: ConfigKind, _ id: String, _ row: T, updatedAt: String) throws {
                if let local = try Row.fetchOne(
                    db, sql: "SELECT json, dirty FROM config_rows WHERE kind = ? AND id = ?", arguments: [kind.rawValue, id]),
                    (local["dirty"] as Int) == 1,
                    let localUpdated = Self.updatedAt(of: local["json"] as Data, decoder: decoder),
                    localUpdated > updatedAt
                {
                    return
                }
                try db.execute(
                    sql: "INSERT OR REPLACE INTO config_rows (kind, id, json, dirty) VALUES (?, ?, ?, 0)",
                    arguments: [kind.rawValue, id, try encoder.encode(row)])
                applied.configChanged = true
            }
            for row in batch.fields { try upsertConfig(.fields, row.id, row, updatedAt: row.updatedAt) }
            for row in batch.fieldOptions { try upsertConfig(.fieldOptions, row.id, row, updatedAt: row.updatedAt) }
            for row in batch.rules { try upsertConfig(.rules, row.id, row, updatedAt: row.updatedAt) }
            for row in batch.savedViews { try upsertConfig(.savedViews, row.id, row, updatedAt: row.updatedAt) }
            for row in batch.settings { try upsertConfig(.settings, row.key, row, updatedAt: row.updatedAt) }
            for (name, cursor) in batch.cursors {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO cursors (name, rev, rowid) VALUES (?, ?, ?)",
                    arguments: [name, cursor.rev, cursor.rowid])
            }
            return applied
        }
    }

    private static func updatedAt(of json: Data, decoder: JSONDecoder) -> String? {
        struct Stamp: Decodable {
            let updatedAt: String?
            enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
        }
        return (try? decoder.decode(Stamp.self, from: json))?.updatedAt
    }
}

// MARK: - Configuration edits

struct DirtyConfig: Sendable {
    var fields: [Field] = []
    var fieldOptions: [FieldOption] = []
    var rules: [Rule] = []
    var savedViews: [SavedView] = []
    var settings: [SettingRow] = []

    var isEmpty: Bool {
        fields.isEmpty && fieldOptions.isEmpty && rules.isEmpty && savedViews.isEmpty && settings.isEmpty
    }
}

extension AppDatabase {
    /// Sorted keys: a row encoded twice gives the same bytes (Foundation's key order is unspecified),
    /// which `markConfigPushed` relies on to spot rows edited again since their push.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension AppDatabase {
    /// Stores locally edited configuration rows, flagged for the next push.
    func saveConfig(_ config: DirtyConfig, dirty: Bool = true) throws {
        let encoder = AppDatabase.makeEncoder()
        try pool.write { db in
            func save<T: Encodable>(_ kind: ConfigKind, _ id: String, _ row: T) throws {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO config_rows (kind, id, json, dirty) VALUES (?, ?, ?, ?)",
                    arguments: [kind.rawValue, id, try encoder.encode(row), dirty ? 1 : 0])
            }
            for row in config.fields { try save(.fields, row.id, row) }
            for row in config.fieldOptions { try save(.fieldOptions, row.id, row) }
            for row in config.rules { try save(.rules, row.id, row) }
            for row in config.savedViews { try save(.savedViews, row.id, row) }
            for row in config.settings { try save(.settings, row.key, row) }
        }
    }

    func dirtyConfig() throws -> DirtyConfig {
        try pool.read { db in
            let decoder = JSONDecoder()
            var out = DirtyConfig()
            for row in try Row.fetchAll(db, sql: "SELECT kind, json FROM config_rows WHERE dirty = 1") {
                let data: Data = row["json"]
                switch ConfigKind(rawValue: row["kind"]) {
                case .fields: if let v = try? decoder.decode(Field.self, from: data) { out.fields.append(v) }
                case .fieldOptions: if let v = try? decoder.decode(FieldOption.self, from: data) { out.fieldOptions.append(v) }
                case .rules: if let v = try? decoder.decode(Rule.self, from: data) { out.rules.append(v) }
                case .savedViews: if let v = try? decoder.decode(SavedView.self, from: data) { out.savedViews.append(v) }
                case .settings: if let v = try? decoder.decode(SettingRow.self, from: data) { out.settings.append(v) }
                case nil: break
                }
            }
            return out
        }
    }

    /// Clears the dirty flag of rows that were not edited again since they were pushed.
    func markConfigPushed(_ pushed: DirtyConfig) throws {
        let encoder = AppDatabase.makeEncoder()
        try pool.write { db in
            func clean<T: Encodable>(_ kind: ConfigKind, _ id: String, _ row: T) throws {
                try db.execute(
                    sql: "UPDATE config_rows SET dirty = 0 WHERE kind = ? AND id = ? AND json = ?",
                    arguments: [kind.rawValue, id, try encoder.encode(row)])
            }
            for row in pushed.fields { try clean(.fields, row.id, row) }
            for row in pushed.fieldOptions { try clean(.fieldOptions, row.id, row) }
            for row in pushed.rules { try clean(.rules, row.id, row) }
            for row in pushed.savedViews { try clean(.savedViews, row.id, row) }
            for row in pushed.settings { try clean(.settings, row.key, row) }
        }
    }
}

// MARK: - Key-value state (last queue, session, device id)

extension AppDatabase {
    func value<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = try? pool.read({ db in try Data.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key]) })
        else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setValue<T: Encodable>(_ value: T?, forKey key: String) {
        try? pool.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)", arguments: [key, try AppDatabase.makeEncoder().encode(value)])
            } else {
                try db.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
            }
        }
    }

    /// Removes every local row (after unpairing, or before loading the demo).
    func reset() throws {
        try pool.write { db in
            for table in ["tracks", "track_values", "config_rows", "journal", "cursors", "cache_entries", "sessions", "kv"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
