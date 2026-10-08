import Foundation
import MyTagsKit
import Observation

/// One value change requested by the UI. `value == nil` removes the app's value: the track goes
/// back to the value read in its file.
struct ValueEdit: Sendable {
    let trackID: String
    let fieldID: String
    let value: FieldValue?
    let source: ValueSource
}

/// In-memory state of the whole library, mirrored from the local database.
///
/// Every edit is committed to SQLite (with its journal entry) before memory is updated, so
/// nothing shown as done can be lost (rule R7).
@MainActor
@Observable
final class LibraryStore {
    let database: AppDatabase
    let deviceID: String

    private(set) var isLoaded = false
    private(set) var config: TagConfig
    private(set) var document: ConfigDocument
    private(set) var tracks: [String: Track] = [:]
    /// Rows by track, then field (soft-deleted rows included).
    private(set) var rows: [String: [String: TrackValue]] = [:]
    private(set) var snapshots: [String: TrackSnapshot] = [:]
    private(set) var artistStats = ArtistStats()
    private(set) var pendingTrackIDs: Set<String> = []
    private(set) var pendingCount = 0
    /// Bumped on every data change; views and queries key their caches on it.
    private(set) var dataVersion = 0
    private(set) var lastWriteError: String?

    /// Tracks whose audio is on the phone (maintained by the audio cache).
    var offlineTrackIDs: Set<String> = [] {
        didSet { refreshOfflineFlags(old: oldValue) }
    }

    /// Called after each local edit (the sync engine schedules a push).
    @ObservationIgnored var onLocalEdit: (() -> Void)?

    init(database: AppDatabase, deviceID: String) {
        self.database = database
        self.deviceID = deviceID
        let empty = ConfigDocument(fields: [], fieldOptions: [], rules: [], savedViews: [], settings: [])
        self.document = empty
        self.config = TagConfig(document: empty)
    }

    // MARK: Loading

    func load() async {
        let database = self.database
        let offline = offlineTrackIDs
        let loaded = await Task.detached(priority: .userInitiated) { () -> (LoadedState, Derived)? in
            guard let state = try? database.loadAll() else { return nil }
            let config = TagConfig(document: state.document)
            let derived = Derived.build(
                tracks: state.tracks, values: state.values, config: config,
                pending: state.pendingTrackIDs, offline: offline)
            return (state, derived)
        }.value
        guard let (state, derived) = loaded else {
            isLoaded = true
            return
        }
        document = state.document
        config = TagConfig(document: state.document)
        tracks = Dictionary(state.tracks.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        rows = derived.rows
        snapshots = derived.snapshots
        artistStats = derived.artistStats
        pendingTrackIDs = state.pendingTrackIDs
        pendingCount = state.pendingCount
        dataVersion += 1
        isLoaded = true
    }

    /// Recomputes every snapshot (after a configuration change).
    func rebuildAll() async {
        let tracks = Array(self.tracks.values)
        let values = rows.values.flatMap { $0.values }
        let config = self.config
        let pending = pendingTrackIDs
        let offline = offlineTrackIDs
        let derived = await Task.detached(priority: .userInitiated) {
            Derived.build(tracks: tracks, values: values, config: config, pending: pending, offline: offline)
        }.value
        snapshots = derived.snapshots
        artistStats = derived.artistStats
        dataVersion += 1
    }

    // MARK: Reading

    var liveTracks: [Track] { tracks.values.filter { !$0.isDeleted } }

    var liveSnapshots: [TrackSnapshot] {
        snapshots.values.filter { tracks[$0.id]?.isDeleted == false }
    }

    func rowList(for trackID: String) -> [TrackValue] {
        rows[trackID].map { Array($0.values) } ?? []
    }

    /// Effective values of a track, with suggestions (rules, artist, default) unless disabled.
    func resolve(_ trackID: String, suggestions: Bool = true) -> ResolvedTrack? {
        guard let track = tracks[trackID] else { return nil }
        return ValueResolver.resolve(
            track: track, rows: rowList(for: trackID), config: config,
            suggestionContext: suggestions ? SuggestionContext(artistStats: artistStats) : nil)
    }

    func status(of trackID: String) -> TrackStatus {
        snapshots[trackID]?.status ?? .none
    }

    // MARK: Writing values

    /// Commits edits to the database, then to memory. Returns false if nothing could be saved.
    @discardableResult
    func apply(_ edits: [ValueEdit]) -> Bool {
        guard !edits.isEmpty else { return true }
        let now = Timestamp.string(from: Date())
        var newRows: [TrackValue] = []
        var changes: [PendingChange] = []
        for edit in edits {
            let old = rows[edit.trackID]?[edit.fieldID].flatMap { $0.isDeleted ? nil : $0.value }
            let row: TrackValue
            if let value = edit.value {
                row = TrackValue(
                    trackID: edit.trackID, fieldID: edit.fieldID, value: value, source: edit.source,
                    updatedAt: now, deviceID: deviceID)
            } else {
                row = TrackValue(
                    trackID: edit.trackID, fieldID: edit.fieldID, source: .file, updatedAt: now,
                    deviceID: deviceID, deletedAt: now)
            }
            newRows.append(row)
            changes.append(PendingChange(
                id: UUID().uuidString.lowercased(), trackID: edit.trackID, fieldID: edit.fieldID,
                oldValue: old, newValue: edit.value, source: edit.source, createdAt: now))
        }
        do {
            try database.record(rows: newRows, changes: changes)
        } catch {
            lastWriteError = error.localizedDescription
            return false
        }
        lastWriteError = nil
        for row in newRows {
            rows[row.trackID, default: [:]][row.fieldID] = row
        }
        let touched = Set(edits.map(\.trackID))
        pendingTrackIDs.formUnion(touched)
        pendingCount += changes.count
        refresh(trackIDs: touched)
        onLocalEdit?()
        return true
    }

    // MARK: Sync results

    func applyPulled(_ applied: AppliedPull) async {
        for track in applied.tracks {
            tracks[track.id] = track
        }
        for value in applied.values {
            rows[value.trackID, default: [:]][value.fieldID] = value
        }
        if applied.configChanged {
            reloadConfig()
            await rebuildAll()
        } else {
            refresh(trackIDs: Set(applied.tracks.map(\.id)).union(applied.values.map(\.trackID)))
        }
    }

    func refreshPending() {
        guard let summary = try? database.pendingSummary() else { return }
        let changed = pendingTrackIDs.symmetricDifference(summary.trackIDs)
        pendingTrackIDs = summary.trackIDs
        pendingCount = summary.count
        refresh(trackIDs: changed)
    }

    // MARK: Configuration

    /// Saves configuration rows edited in Settings (flagged for the next push) and recomputes.
    func saveConfig(_ edits: DirtyConfig) async {
        do {
            try database.saveConfig(edits)
        } catch {
            lastWriteError = error.localizedDescription
            return
        }
        reloadConfig()
        await rebuildAll()
        onLocalEdit?()
    }

    func reloadConfig() {
        guard let state = try? database.loadConfigDocument() else { return }
        document = state
        config = TagConfig(document: state)
    }

    // MARK: Derived state

    private func refresh(trackIDs: Set<String>) {
        guard !trackIDs.isEmpty else { return }
        for id in trackIDs {
            guard let track = tracks[id] else {
                snapshots[id] = nil
                artistStats.removeTrack(id: id)
                continue
            }
            let resolved = ValueResolver.resolve(track: track, rows: rowList(for: id), config: config, suggestionContext: nil)
            snapshots[id] = TrackSnapshot(
                track: track, resolved: resolved, config: config,
                hasPendingLocalChanges: pendingTrackIDs.contains(id), isOffline: offlineTrackIDs.contains(id))
            if track.isDeleted {
                artistStats.removeTrack(id: id)
            } else {
                artistStats.setTrack(id: id, artist: track.artist, confirmedValues: resolved.confirmedValues)
            }
        }
        dataVersion += 1
    }

    private func refreshOfflineFlags(old: Set<String>) {
        let changed = old.symmetricDifference(offlineTrackIDs)
        guard !changed.isEmpty else { return }
        for id in changed {
            snapshots[id]?.isOffline = offlineTrackIDs.contains(id)
        }
        dataVersion += 1
    }
}

/// Snapshots and artist statistics, computed off the main thread.
struct Derived: Sendable {
    var rows: [String: [String: TrackValue]]
    var snapshots: [String: TrackSnapshot]
    var artistStats: ArtistStats

    static func build(
        tracks: [Track], values: [TrackValue], config: TagConfig, pending: Set<String>, offline: Set<String>
    ) -> Derived {
        var rows: [String: [String: TrackValue]] = [:]
        for value in values {
            rows[value.trackID, default: [:]][value.fieldID] = value
        }
        var snapshots: [String: TrackSnapshot] = [:]
        snapshots.reserveCapacity(tracks.count)
        var stats = ArtistStats()
        for track in tracks {
            let trackRows = rows[track.id].map { Array($0.values) } ?? []
            let resolved = ValueResolver.resolve(track: track, rows: trackRows, config: config, suggestionContext: nil)
            snapshots[track.id] = TrackSnapshot(
                track: track, resolved: resolved, config: config,
                hasPendingLocalChanges: pending.contains(track.id), isOffline: offline.contains(track.id))
            if !track.isDeleted {
                stats.setTrack(id: track.id, artist: track.artist, confirmedValues: resolved.confirmedValues)
            }
        }
        return Derived(rows: rows, snapshots: snapshots, artistStats: stats)
    }
}
