import Foundation
import MyTagsKit

/// Keeps the next tracks of the queue downloaded (spec section 10, "Préchargement").
///
/// The current track first, then the next ones in order; the two previous ones are kept.
/// On a constrained or expensive network only two tracks ahead are fetched.
@MainActor
final class Prefetcher {
    private let store: LibraryStore
    private let downloader: Downloader
    private let cache: AudioCache
    private let covers: CoverLoader
    private let sync: SyncEngine
    private let settings: DeviceSettings
    private var lastDesired: [String] = []

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
        downloader.cancelPrefetches(keeping: desired)
        if sync.isOnline {
            for (offset, id) in ordered.enumerated() {
                guard let track = store.tracks[id], let key = track.audioKey else { continue }
                let priority = max(0.1, 1 - Float(offset) * 0.08)
                downloader.prefetch(id, audioKey: key, priority: priority)
            }
            let coverKeys = ordered.prefix(4).compactMap { store.tracks[$0]?.coverKey }
            let covers = self.covers
            Task.detached(priority: .utility) {
                for key in coverKeys { _ = await covers.image(coverKey: key, size: .large) }
            }
        }
        cache.limitBytes = settings.cacheLimitBytes
        cache.evict(protecting: desired)
        lastDesired = ordered
    }
}
