import Foundation
import MyTagsKit
import Observation
import UIKit

/// Root object: owns the store, sync, audio and the open Tag session.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching, pairing, ready
    }

    private(set) var phase: Phase = .launching
    private(set) var isDemo = false
    var tagSession: TagSessionModel?
    var isTagScreenPresented = false
    /// Recap shown after closing the Tag screen when at least 5 tracks were validated.
    var sessionSummary: SessionSummary?

    let database: AppDatabase
    let store: LibraryStore
    let sync: SyncEngine
    let cache: AudioCache
    let downloader: Downloader
    let covers: CoverLoader
    let player: PlayerEngine
    let settings: DeviceSettings
    let prefetcher: Prefetcher
    let sessions: SessionRecorder

    init() {
        do {
            database = try AppDatabase(url: AppDatabase.defaultURL())
        } catch {
            // The database is mandatory; failing here means the device storage is unusable.
            fatalError("Base locale illisible : \(error)")
        }
        let deviceID: String = {
            if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
            let id = UUID().uuidString.lowercased()
            UserDefaults.standard.set(id, forKey: "deviceID")
            return id
        }()
        settings = DeviceSettings()
        store = LibraryStore(database: database, deviceID: deviceID)
        sync = SyncEngine(store: store)
        do {
            cache = try AudioCache(database: database)
        } catch {
            fatalError("Dossier audio inaccessible : \(error)")
        }
        downloader = Downloader(cache: cache)
        covers = CoverLoader()
        player = PlayerEngine(downloader: downloader, cache: cache, covers: covers)
        prefetcher = Prefetcher(
            store: store, downloader: downloader, cache: cache, covers: covers, sync: sync, settings: settings)
        sessions = SessionRecorder(database: database)
        cache.onChange = { [weak self] ids in self?.store.offlineTrackIDs = ids }
        store.offlineTrackIDs = cache.offlineIDs
        sync.onUnauthorized = { [weak self] in self?.handleUnauthorized() }
        Haptics.shared.isEnabled = settings.hapticsEnabled
        player.startPointProvider = { [weak settings] in settings?.startPoint ?? .loudest }
        isDemo = UserDefaults.standard.bool(forKey: "demoMode")
    }

    // MARK: Lifecycle

    func start() async {
        if ProcessInfo.processInfo.arguments.contains("-uitest-demo") {
            await startDemo()
            return
        }
        await store.load()
        cache.limitBytes = settings.cacheLimitBytes
        cache.expireTrips(olderThan: settings.tripRetentionDays)
        if let credentials = CredentialStore.load() {
            await configure(credentials)
            phase = .ready
            restoreSession()
            await sync.sync()
            prefetchThumbnails()
        } else if isDemo {
            phase = .ready
            restoreSession()
        } else {
            phase = .pairing
        }
    }

    private func configure(_ credentials: Credentials) async {
        let api = APIClient(credentials: credentials)
        sync.configure(api: api)
        downloader.api = api
        await covers.configure(api: api)
    }

    /// Validates the pairing payload with the Worker, then downloads the catalogue.
    func pair(with credentials: Credentials) async throws {
        let api = APIClient(credentials: credentials)
        let me = try await api.me()
        guard me.role == "device" || me.role == "admin" else { throw APIError.unauthorized }
        if isDemo {
            leaveDemo()
        }
        try CredentialStore.save(credentials)
        await configure(credentials)
        phase = .ready
        await sync.sync()
        prefetchThumbnails()
    }

    func handleOpenURL(_ url: URL) {
        guard let credentials = Credentials(pairingText: url.absoluteString) else { return }
        Task { try? await pair(with: credentials) }
    }

    /// Forgets the device token and every local copy (tags already sent stay in the cloud).
    func unpair() {
        player.stop()
        closeTagScreen()
        CredentialStore.delete()
        sync.configure(api: nil)
        downloader.api = nil
        downloader.cancelTrip()
        cache.clearEverything()
        try? database.reset()
        UserDefaults.standard.set(false, forKey: "demoMode")
        isDemo = false
        Task {
            await covers.configure(api: nil)
            await store.load()
        }
        phase = .pairing
    }

    private func handleUnauthorized() {
        // Keep local data: unsent edits must not be lost (R7). Only the token is dropped.
        CredentialStore.delete()
        sync.configure(api: nil)
        downloader.api = nil
        phase = .pairing
    }

    func sceneBecameActive() {
        sync.syncNow()
    }

    func sceneEnteredBackground() {
        let application = UIApplication.shared
        let box = BackgroundTaskBox()
        box.id = application.beginBackgroundTask(withName: "mytags.push") {
            application.endBackgroundTask(box.id)
        }
        Task {
            await sync.sync(pull: false)
            application.endBackgroundTask(box.id)
        }
    }

    private func prefetchThumbnails() {
        guard sync.isOnline, !sync.isExpensiveNetwork else { return }
        let keys = store.liveTracks.compactMap(\.coverKey)
        let covers = self.covers
        Task.detached(priority: .background) { await covers.prefetchThumbnails(keys) }
    }

    // MARK: Demo

    func startDemo() async {
        try? database.reset()
        cache.clearEverything()
        DemoData.install(into: database)
        UserDefaults.standard.set(true, forKey: "demoMode")
        isDemo = true
        await store.load()
        phase = .ready
        let cache = self.cache
        let tracks = store.liveTracks
        Task { await DemoAudio.generate(for: tracks, cache: cache) }
    }

    private func leaveDemo() {
        try? database.reset()
        cache.clearEverything()
        UserDefaults.standard.set(false, forKey: "demoMode")
        isDemo = false
    }

    // MARK: Tag screen

    /// Opens the Tag screen on `trackIDs` (frozen queue), starting at `startID`.
    func openTagScreen(trackIDs: [String], title: String, startAt startID: String? = nil, skipComplete: Bool = false,
                       autoplay: Bool = true) {
        guard !trackIDs.isEmpty else { return }
        var queue = TagQueue(trackIDs: trackIDs)
        if let startID, let index = queue.index(of: startID) { queue.move(to: index) }
        let session = TagSessionModel(app: self, queue: queue, title: title, skipComplete: skipComplete)
        tagSession = session
        isTagScreenPresented = true
        session.begin(autoplay: autoplay)
    }

    /// Reopens the Tag screen (mini player tap).
    func reopenTagScreen() {
        guard tagSession != nil else { return }
        isTagScreenPresented = true
    }

    func closeTagScreen() {
        tagSession?.end()
        isTagScreenPresented = false
    }

    private func restoreSession() {
        guard let saved = database.value(SavedSession.self, forKey: SavedSession.key), !saved.queue.isEmpty else { return }
        let ids = saved.queue.trackIDs.filter { store.tracks[$0] != nil }
        guard !ids.isEmpty else { return }
        var queue = TagQueue(trackIDs: ids)
        if let current = saved.queue.currentTrackID, let index = queue.index(of: current) { queue.move(to: index) }
        let session = TagSessionModel(app: self, queue: queue, title: saved.title, skipComplete: saved.skipComplete)
        tagSession = session
        isTagScreenPresented = true
        session.begin(autoplay: false)
    }
}

private final class BackgroundTaskBox: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid
}

/// The Tag session to reopen at launch (spec 9.1).
struct SavedSession: Codable, Sendable {
    static let key = "openSession"
    var queue: TagQueue
    var title: String
    var skipComplete: Bool
}
