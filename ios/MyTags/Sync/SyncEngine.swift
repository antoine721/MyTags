import Foundation
import MyTagsKit
import Network
import Observation

/// Sends the journal and pulls what changed (spec section 11).
///
/// Triggers: network back, app to background or foreground, every 30 s while changes wait,
/// pull to refresh, and the Settings button. Nothing here ever blocks the UI.
@MainActor
@Observable
final class SyncEngine {
    enum Phase: Equatable {
        case idle, syncing
    }

    private(set) var phase: Phase = .idle
    private(set) var isOnline = true
    private(set) var isExpensiveNetwork = false
    private(set) var lastSyncAt: Date?
    private(set) var lastError: String?
    /// Progress of the very first catalogue download (nil once done).
    private(set) var initialProgress: Double?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Called when the server refuses the device token (revoked).
    @ObservationIgnored var onUnauthorized: (() -> Void)?

    static let pullTables = ["tracks", "fields", "field_options", "track_values", "rules", "saved_views", "settings"]

    init(store: LibraryStore) {
        self.store = store
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                let cameBack = online && !self.isOnline
                self.isOnline = online
                self.isExpensiveNetwork = expensive
                if cameBack { self.syncNow() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "mytags.network"))
        store.onLocalEdit = { [weak self] in self?.schedulePush() }
    }

    func configure(api: APIClient?) {
        self.api = api
        timer?.cancel()
        guard api != nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.store.pendingCount > 0 else { continue }
                self.syncNow()
            }
        }
    }

    var waitingCount: Int { store.pendingCount }

    /// Pushes shortly after an edit (edits made in a burst go together).
    func schedulePush() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.syncNow(pull: false)
        }
    }

    func syncNow(pull: Bool = true) {
        guard api != nil else { return }
        if phase == .syncing {
            rerunRequested = true
            return
        }
        Task { await run(pull: pull) }
    }

    /// Awaitable variant (pull to refresh, background task).
    func sync(pull: Bool = true) async {
        guard api != nil else { return }
        if phase == .syncing {
            rerunRequested = true
            return
        }
        await run(pull: pull)
    }

    private func run(pull: Bool) async {
        guard let api else { return }
        phase = .syncing
        defer { phase = .idle }
        repeat {
            rerunRequested = false
            do {
                try await push(api)
                if pull { try await self.pull(api) }
                lastSyncAt = Date()
                lastError = nil
            } catch APIError.offline {
                isOnline = false
                return
            } catch APIError.unauthorized {
                lastError = APIError.unauthorized.errorDescription
                onUnauthorized?()
                return
            } catch {
                lastError = error.localizedDescription
                return
            }
        } while rerunRequested
    }

    // MARK: Push

    private func push(_ api: APIClient) async throws {
        let database = store.database
        while true {
            let pending = try await Task.detached { try database.pendingChanges(limit: 2_000) }.value
            let config = try await Task.detached { try database.dirtyConfig() }.value
            if pending.isEmpty && config.isEmpty { break }
            let coalesced = ChangeCoalescer.coalesce(pending)
            let batch = Array(coalesced.prefix(500))
            let batchKeys = Set(batch.map { "\($0.trackID)|\($0.fieldID)" })
            // Every raw entry folded into a sent change is sent too.
            let sentIDs = pending.filter { batchKeys.contains("\($0.trackID)|\($0.fieldID)") }.map(\.id)
            var body = PushBody()
            body.changes = batch.map {
                PushChange(
                    id: $0.id, trackID: $0.trackID, fieldID: $0.fieldID, oldValue: $0.oldValue,
                    newValue: $0.newValue, source: $0.source.rawValue, createdAt: $0.createdAt)
            }
            body.fields = config.fields
            body.fieldOptions = config.fieldOptions
            body.rules = config.rules
            body.savedViews = config.savedViews
            body.settings = config.settings
            _ = try await api.push(body)
            try await Task.detached {
                try database.markSent(ids: sentIDs)
                try database.markConfigPushed(config)
            }.value
            store.refreshPending()
            if coalesced.count <= 500 && pending.count < 2_000 { break }
        }
    }

    // MARK: Pull

    private func pull(_ api: APIClient) async throws {
        let database = store.database
        var cursors = try await Task.detached { try database.cursors() }.value
        let firstSync = cursors["tracks"] == nil
        var pending = Set(Self.pullTables)
        var received = 0
        while !pending.isEmpty {
            let request = Dictionary(uniqueKeysWithValues: pending.map { ($0, cursors[$0] ?? .zero) })
            let response = try await api.pull(cursors: request, limit: 1_000)
            var batch = PullBatch()
            let t = response.tables
            if let page = t.tracks { batch.tracks = page.rows; Self.advance(&cursors, &pending, "tracks", page) }
            if let page = t.fields { batch.fields = page.rows; Self.advance(&cursors, &pending, "fields", page) }
            if let page = t.fieldOptions {
                batch.fieldOptions = page.rows
                Self.advance(&cursors, &pending, "field_options", page)
            }
            if let page = t.trackValues {
                batch.values = page.rows
                Self.advance(&cursors, &pending, "track_values", page)
            }
            if let page = t.rules { batch.rules = page.rows; Self.advance(&cursors, &pending, "rules", page) }
            if let page = t.savedViews { batch.savedViews = page.rows; Self.advance(&cursors, &pending, "saved_views", page) }
            if let page = t.settings { batch.settings = page.rows; Self.advance(&cursors, &pending, "settings", page) }
            // Tables absent from the response have nothing more.
            for name in request.keys where !Self.isPresent(name, in: t) {
                pending.remove(name)
            }
            batch.cursors = cursors
            received += batch.tracks.count
            if firstSync {
                initialProgress = min(0.95, Double(received) / Double(max(received + (pending.contains("tracks") ? 1_000 : 0), 1)))
            }
            let toApply = batch
            let applied = try await Task.detached { try database.apply(toApply) }.value
            await store.applyPulled(applied)
        }
        initialProgress = nil
    }

    private static func advance<Row>(
        _ cursors: inout [String: SyncCursor], _ pending: inout Set<String>, _ name: String, _ page: PullPage<Row>
    ) {
        cursors[name] = page.cursor
        if !page.hasMore { pending.remove(name) }
    }

    private static func isPresent(_ name: String, in tables: PullTables) -> Bool {
        switch name {
        case "tracks": tables.tracks != nil
        case "fields": tables.fields != nil
        case "field_options": tables.fieldOptions != nil
        case "track_values": tables.trackValues != nil
        case "rules": tables.rules != nil
        case "saved_views": tables.savedViews != nil
        case "settings": tables.settings != nil
        default: false
        }
    }
}
