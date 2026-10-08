import Foundation
import MyTagsKit

/// Keeps the next tracks of the queue downloaded (spec section 10, "Préchargement").
///
/// One download at a time, in order: the current track first and alone, then the next ones,
/// then the two previous ones. Requests share one HTTP/2 connection, so downloads started
/// together would split the bandwidth with the track being waited for. On an expensive network
/// (cellular) or in Low Data Mode, `isExpensiveNetwork` limits the look-ahead to two tracks
/// (spec section 10); trips are prepared on Wi-Fi.
@MainActor
final class Prefetcher {
    private let store: LibraryStore
    private let downloader: Downloader
    private let cache: AudioCache
    private let covers: CoverLoader
    private let sync: SyncEngine
    private let settings: DeviceSettings
    private var pipeline: Task<Void, Never>?

    init(store: LibraryStore, downloader: Downloader, cache: AudioCache, covers: CoverLoader, sync: SyncEngine,
         settings: DeviceSettings) {
        self.store = store
        self.downloader = downloader
        self.cache = cache
        self.covers = covers
        self.sync = sync
        self.settings = settings
    }

    func update(queue: TagQueue) {
        guard !queue.isEmpty else { return }
        let index = min(queue.currentIndex, queue.count - 1)
        let ahead = sync.isExpensiveNetwork ? 2 : settings.prefetchCount
        let upper = min(queue.count - 1, index + ahead)
        var ordered = Array(queue.trackIDs[index...upper])
        let previous = queue.trackIDs[max(0, index - 2)..<index]
        ordered.append(contentsOf: previous.reversed())
        let desired = Set(ordered)
        let current = queue.trackIDs[index]
        // While the current track is missing, nothing else downloads.
        downloader.cancelPrefetches(keeping: cache.localURL(for: current) == nil ? [current] : desired)
        pipeline?.cancel()
        pipeline = nil
        if sync.isOnline {
            let missing = ordered.compactMap { id -> (id: String, key: String)? in
                guard cache.localURL(for: id) == nil, let key = store.tracks[id]?.audioKey else { return nil }
                return (id, key)
            }
            let downloader = self.downloader
            pipeline = Task {
                for item in missing {
                    guard !Task.isCancelled else { return }
                    _ = await downloader.waitForFile(item.id, audioKey: item.key)
                }
            }
            let coverKeys = ordered.prefix(4).compactMap { store.tracks[$0]?.coverKey }
            let covers = self.covers
            Task.detached(priority: .utility) {
                for key in coverKeys { _ = await covers.image(coverKey: key, size: .large) }
            }
        }
        cache.limitBytes = settings.cacheLimitBytes
        cache.evict(protecting: desired)
    }
}
