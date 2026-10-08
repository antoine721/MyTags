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
    /// Edits the server refused: kept on the phone, left out of pushes, offered again at each launch.
    private(set) var rejectedCount = 0
    /// Progress of the very first catalogue download (nil once done).
    private(set) var initialProgress: Double?

    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private var api: (any SyncAPI)?
    /// Bumped by `configure`: a sync started with an older token must not act for the new one.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let monitor = NWPathMonitor()
    /// The running sync: one at a time.
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// Asked for while a run was going: the run goes once more (with a pull if one asked for it).
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var rerunPull = false
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Called when the server refuses the device token (revoked).
    @ObservationIgnored var onUnauthorized: (() -> Void)?
    /// Called when the network comes back.
    @ObservationIgnored var onNetworkBack: (() -> Void)?

    static let pullTables = ["tracks", "fields", "field_options", "track_values", "rules", "saved_views", "settings"]
    /// Worker limits per push: 500 changes (MAX_CHANGES) and 500 rows per configuration table (MAX_CONFIG_ROWS).
    static let maxRowsPerPush = 500
    /// Rows per table and pull page: a page of tracks must stay well within the Worker's CPU budget.
    static let pullPageSize = 300
    /// Journal entries read per push round.
    static let journalWindow = 2_000

    init(store: LibraryStore) {
        self.store = store
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isExpensiveNetwork = expensive
                self.setOnline(online, sync: true)
            }
        }
        monitor.start(queue: DispatchQueue(label: "mytags.network"))
        store.onLocalEdit = { [weak self] in self?.schedulePush() }
    }

    func configure(api: (any SyncAPI)?) {
        self.api = api
        generation += 1
        timer?.cancel()
        guard api != nil else { return }
        // Refused rows get another chance at each launch or pairing (server or app fixed since).
        try? store.database.requeueRejected()
        store.refreshPending()
        refreshRejected()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                self.retryIfNeeded()
            }
        }
    }

    /// The 30 s retry: re-checks the network, then syncs if edits or configuration rows wait.
    private func retryIfNeeded() {
        if !isOnline && monitor.currentPath.status == .satisfied { setOnline(true, sync: false) }
        let waiting = store.pendingCount > 0 || ((try? store.database.hasPendingPush()) ?? false)
        if waiting { syncNow() }
    }

    private func setOnline(_ online: Bool, sync: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        guard cameBack else { return }
        onNetworkBack?()
        if sync { syncNow() }
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
        startRun(pull: pull)
    }

    /// Awaitable variant (pull to refresh, background task): waits for a run already going, then
    /// runs once more, so that edits made during that run are sent before this returns.
    func sync(pull: Bool = true) async {
        guard api != nil else { return }
        if let runTask { await runTask.value }
        guard api != nil else { return }
        await startRun(pull: pull).value
    }

    /// Starts a run, or asks the running one to go once more. Set synchronously: two calls in a
    /// row never start two runs.
    @discardableResult
    private func startRun(pull: Bool) -> Task<Void, Never> {
        if let runTask {
            rerunRequested = true
            rerunPull = rerunPull || pull
            return runTask
        }
        phase = .syncing
        let task = Task { await run(pull: pull) }
        runTask = task
        return task
    }

    private func run(pull firstPull: Bool) async {
        defer {
            phase = .idle
            runTask = nil
        }
        var pull = firstPull
        while true {
            rerunRequested = false
            rerunPull = false
            guard let api else { return }
            let generation = self.generation
            do {
                // A refused push must not stop the pull: pulled rows never replace a value that has a
                // pending local edit, so pulling after a failed push loses nothing.
                var pushError: (any Error)?
                do {
                    try await push(api)
                } catch {
                    switch error {
                    case APIError.offline, APIError.unauthorized: throw error  // the pull would fail the same way
                    default: pushError = error
                    }
                }
                if pull { try await self.pull(api, generation: generation) }
                if let pushError { throw pushError }
                lastSyncAt = Date()
                lastError = nil
            } catch APIError.offline {
                // A timeout in a tunnel is not "offline" while the path is up: trust the monitor.
                if monitor.currentPath.status != .satisfied { isOnline = false }
                return
            } catch APIError.unauthorized {
                guard generation == self.generation else { return }
                lastError = APIError.unauthorized.errorDescription
                onUnauthorized?()
                return
            } catch {
                lastError = error.localizedDescription
                return
            }
            guard rerunRequested else { return }
            pull = rerunPull
        }
    }

    // MARK: Push

    private func push(_ api: any SyncAPI) async throws {
        let database = store.database
        let window = Self.journalWindow
        defer {
            store.refreshPending()
            refreshRejected()
        }
        while true {
            let pending = try await Task.detached { try database.pendingChanges(limit: window) }.value
            let config = try await Task.detached { try database.dirtyConfig() }.value
            if pending.isEmpty && config.isEmpty { break }
            // Configuration first: changes may refer to a field or an option created on the phone.
            let items = PushItem.items(config: config) + PushItem.items(changes: pending)
            for chunk in items.chunked(into: Self.maxRowsPerPush) {
                try await send(chunk, api: api)
            }
            if pending.count < window { break }
        }
    }

    /// Sends `items` in one request. When the server refuses a row (400 naming it) or the size
    /// (413), halves it until the refused rows are isolated: those are flagged rejected (kept on the
    /// phone), the rest is sent. A 400 about the request itself stops the push, like a server error.
    private func send(_ items: [PushItem], api: any SyncAPI) async throws {
        guard !items.isEmpty else { return }
        let database = store.database
        let ids = items.flatMap(\.journalIDs)
        let config = PushItem.config(of: items)
        do {
            _ = try await api.push(PushBody(items: items))
        } catch APIError.http(let code, let message) where code == 413 || (code == 400 && Self.namesRow(message)) {
            setOnline(true, sync: false)
            guard items.count == 1 else {
                let half = items.count / 2
                try await send(Array(items[..<half]), api: api)
                try await send(Array(items[half...]), api: api)
                return
            }
            syncLogger.error("Push refused (\(code)): \(message, privacy: .public)")
            try await Task.detached {
                try database.markRejected(ids: ids)
                try database.markConfigRejected(config)
            }.value
            return
        }
        setOnline(true, sync: false)
        try await Task.detached {
            try database.markSent(ids: ids)
            try database.markConfigPushed(config)
        }.value
    }

    /// Whether a Worker 400 message is about one row (`changes[3].new_value …`, `fields[0].kind …`).
    /// Any other 400 (body, cursors…) is not caused by the rows: none of them is refused for it.
    nonisolated static func namesRow(_ message: String) -> Bool {
        ["changes", "fields", "field_options", "rules", "saved_views", "settings"]
            .contains { message.hasPrefix($0 + "[") }
    }

    private func refreshRejected() {
        if let count = try? store.database.rejectedCount() { rejectedCount = count }
    }

    // MARK: Pull

    private func pull(_ api: any SyncAPI, generation: Int) async throws {
        let database = store.database
        let pageSize = Self.pullPageSize
        var cursors = try await Task.detached { try database.cursors() }.value
        let firstSync = cursors["tracks"] == nil
        var pending = Set(Self.pullTables)
        var received = 0
        while !pending.isEmpty {
            let request = Dictionary(uniqueKeysWithValues: pending.map { ($0, cursors[$0] ?? .zero) })
            let response = try await api.pull(cursors: request, limit: pageSize)
            // Unpaired or paired again meanwhile: these rows belong to the previous setup.
            guard generation == self.generation else {
                initialProgress = nil
                return
            }
            setOnline(true, sync: false)
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
                initialProgress = min(0.95, Double(received) / Double(max(received + (pending.contains("tracks") ? pageSize : 0), 1)))
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

/// One row of a push and the local entries it stands for.
struct PushItem: Sendable {
    var change: PushChange?
    /// Journal entries folded into `change`: marked sent or rejected with it.
    var journalIDs: [String] = []
    /// One configuration row (empty for a change).
    var config = DirtyConfig()

    /// One item per configuration row, so that a refused row can be isolated.
    static func items(config: DirtyConfig) -> [PushItem] {
        var items: [PushItem] = []
        items += config.fields.map { PushItem(config: DirtyConfig(fields: [$0])) }
        items += config.fieldOptions.map { PushItem(config: DirtyConfig(fieldOptions: [$0])) }
        items += config.rules.map { PushItem(config: DirtyConfig(rules: [$0])) }
        items += config.savedViews.map { PushItem(config: DirtyConfig(savedViews: [$0])) }
        items += config.settings.map { PushItem(config: DirtyConfig(settings: [$0])) }
        return items
    }

    /// One item per (track, field): the coalesced change, with every journal entry it folds.
    static func items(changes pending: [PendingChange]) -> [PushItem] {
        var folded: [String: [String]] = [:]
        for change in pending {
            folded["\(change.trackID)|\(change.fieldID)", default: []].append(change.id)
        }
        return ChangeCoalescer.coalesce(pending).map { change in
            PushItem(
                change: PushChange(
                    id: change.id, trackID: change.trackID, fieldID: change.fieldID, oldValue: change.oldValue,
                    newValue: change.newValue, source: change.source.rawValue, createdAt: change.createdAt),
                journalIDs: folded["\(change.trackID)|\(change.fieldID)"] ?? [change.id])
        }
    }

    static func config(of items: [PushItem]) -> DirtyConfig {
        var config = DirtyConfig()
        for item in items { config.append(item.config) }
        return config
    }
}

extension PushBody {
    init(items: [PushItem]) {
        let config = PushItem.config(of: items)
        self.init(
            changes: items.compactMap(\.change), fields: config.fields, fieldOptions: config.fieldOptions,
            rules: config.rules, savedViews: config.savedViews, settings: config.settings)
    }
}
