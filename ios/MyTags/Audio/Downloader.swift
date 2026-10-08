import Foundation
import Observation

/// Downloads listening files: prioritised prefetching in the foreground, and "Préparer mon trajet"
/// in a background session that keeps going with the app closed (decision 0004).
@MainActor
@Observable
final class Downloader {
    enum Purpose: Equatable {
        case prefetch, trip
    }

    /// Bytes received / expected per track currently downloading.
    private(set) var progress: [String: Double] = [:]
    private(set) var tripRemaining = 0
    private(set) var tripTotal = 0
    private(set) var lastFailure: String?

    @ObservationIgnored var api: APIClient?
    @ObservationIgnored private let cache: AudioCache
    @ObservationIgnored private var foreground: URLSession!
    @ObservationIgnored private var background: URLSession!
    @ObservationIgnored private let delegate = DownloadDelegate()
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var purposes: [String: Purpose] = [:]
    @ObservationIgnored private var waiters: [String: [CheckedContinuation<URL?, Never>]] = [:]
    /// Tracks already retried once after a 409 or a 5xx.
    @ObservationIgnored private var retried: Set<String> = []
    /// Called when the server refuses the current device token (revoked).
    @ObservationIgnored var onUnauthorized: (() -> Void)?
    /// Completion handler iOS passes when it relaunches the app for background downloads. Static:
    /// it can arrive before this object exists, and is called once the session has delivered its events.
    static var backgroundCompletion: (() -> Void)?

    static let backgroundIdentifier = "mytags.trips"

    init(cache: AudioCache) {
        self.cache = cache
        let fg = URLSessionConfiguration.default
        fg.httpMaximumConnectionsPerHost = 3
        fg.timeoutIntervalForRequest = 30
        fg.waitsForConnectivity = false
        foreground = URLSession(configuration: fg, delegate: delegate, delegateQueue: nil)
        let bg = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        bg.isDiscretionary = false
        bg.sessionSendsLaunchEvents = true
        bg.httpMaximumConnectionsPerHost = 3
        background = URLSession(configuration: bg, delegate: delegate, delegateQueue: nil)
        delegate.owner = self
        // Trip downloads keep running while the app is closed: count them again after a relaunch.
        background.getAllTasks { [weak self] existing in
            let ids = existing.compactMap(\.taskDescription)
            Task { @MainActor [weak self] in
                guard let self else { return }
                for id in ids where self.purposes[id] == nil {
                    self.purposes[id] = .trip
                }
                self.tripRemaining = ids.count
                self.tripTotal = max(self.tripTotal, ids.count)
            }
        }
    }

    func isDownloading(_ trackID: String) -> Bool { tasks[trackID] != nil || purposes[trackID] == .trip }

    /// Starts (or re-prioritises) a prefetch download. `priority` is 0...1, higher first.
    func prefetch(_ trackID: String, audioKey: String, priority: Float) {
        guard let api, !cache.offlineIDs.contains(trackID) else { return }
        if let task = tasks[trackID] {
            task.priority = priority
            return
        }
        if purposes[trackID] == .trip { return }  // already coming through the background session
        let task = foreground.downloadTask(with: api.blobRequest(key: audioKey))
        task.taskDescription = trackID
        task.priority = priority
        tasks[trackID] = task
        purposes[trackID] = .prefetch
        progress[trackID] = 0
        task.resume()
    }

    /// Cancels prefetch downloads that are no longer useful (trip downloads are kept).
    func cancelPrefetches(keeping keep: Set<String>) {
        for (id, task) in tasks where purposes[id] == .prefetch && !keep.contains(id) {
            task.cancel()
            tasks[id] = nil
            purposes[id] = nil
            progress[id] = nil
            resume(id, with: nil)
        }
    }

    /// Waits for a track's file, downloading it at top priority if needed. Nil when unavailable.
    func waitForFile(_ trackID: String, audioKey: String?) async -> URL? {
        if let url = cache.localURL(for: trackID) { return url }
        guard let audioKey, api != nil else { return nil }
        prefetch(trackID, audioKey: audioKey, priority: URLSessionTask.highPriority)
        guard tasks[trackID] != nil || purposes[trackID] == .trip else { return cache.localURL(for: trackID) }
        return await withCheckedContinuation { continuation in
            waiters[trackID, default: []].append(continuation)
        }
    }

    /// "Préparer mon trajet": downloads in a background session and pins the files.
    func prepareTrip(_ items: [TripItem]) {
        guard let api else { return }
        let missing = items.filter { !cache.offlineIDs.contains($0.trackID) }
        cache.pin(items.map(\.trackID).filter { cache.offlineIDs.contains($0) })
        tripTotal = missing.count
        tripRemaining = missing.count
        for item in missing {
            if let existing = tasks[item.trackID], purposes[item.trackID] == .prefetch {
                existing.cancel()
            }
            let task = background.downloadTask(with: api.blobRequest(key: item.audioKey))
            task.taskDescription = item.trackID
            tasks[item.trackID] = task
            purposes[item.trackID] = .trip
            task.resume()
        }
    }

    func cancelTrip() {
        for (id, task) in tasks where purposes[id] == .trip {
            task.cancel()
            tasks[id] = nil
        }
        for (id, purpose) in purposes where purpose == .trip {
            purposes[id] = nil
        }
        background.getAllTasks { all in all.forEach { $0.cancel() } }
        tripRemaining = 0
        tripTotal = 0
    }

    // MARK: Delegate callbacks (main actor)

    fileprivate func didProgress(_ trackID: String, written: Int64, expected: Int64) {
        guard expected > 0 else { return }
        progress[trackID] = Double(written) / Double(expected)
    }

    fileprivate func didFinish(_ trackID: String, file: URL?, status: Int, error: String?, request: URLRequest?) {
        let tracked = tasks[trackID] != nil || purposes[trackID] != nil
        let purpose = purposes[trackID] ?? .prefetch
        tasks[trackID] = nil
        purposes[trackID] = nil
        progress[trackID] = nil
        // 409: the file was being replaced; 5xx: a passing Worker failure. One more try.
        if status == 409 || (500..<600).contains(status), tracked, api != nil, let request,
           retried.insert(trackID).inserted {
            restart(trackID, request: request, purpose: purpose)
            return
        }
        retried.remove(trackID)
        if purpose == .trip { tripRemaining = max(0, tripRemaining - 1) }
        // Only a refusal of the current token: a download started before a new pairing does not count.
        if status == 401, let api, request?.value(forHTTPHeaderField: "Authorization") == api.authorization {
            onUnauthorized?()
        }
        guard let file, (200..<300).contains(status) else {
            if let error { lastFailure = error }
            resume(trackID, with: nil)
            return
        }
        do {
            try cache.store(trackID: trackID, downloadedFile: file, kind: purpose == .trip ? .trip : .auto)
            resume(trackID, with: cache.localURL(for: trackID))
        } catch {
            try? FileManager.default.removeItem(at: file)
            lastFailure = error.localizedDescription
            resume(trackID, with: nil)
        }
    }

    private func restart(_ trackID: String, request: URLRequest, purpose: Purpose) {
        let task = (purpose == .trip ? background : foreground).downloadTask(with: request)
        task.taskDescription = trackID
        if waiters[trackID] != nil { task.priority = URLSessionTask.highPriority }
        tasks[trackID] = task
        purposes[trackID] = purpose
        progress[trackID] = 0
        task.resume()
    }

    fileprivate static func backgroundEventsFinished() {
        backgroundCompletion?()
        backgroundCompletion = nil
    }

    private func resume(_ trackID: String, with url: URL?) {
        for waiter in waiters.removeValue(forKey: trackID) ?? [] {
            waiter.resume(returning: url)
        }
    }
}

struct TripItem: Sendable {
    let trackID: String
    let audioKey: String
}

/// URLSession delegate; moves the file synchronously (it is deleted when the callback returns),
/// then hands over to the main actor.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var owner: Downloader?

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor [weak owner] in
            owner?.didProgress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let request = downloadTask.originalRequest
        guard (200..<300).contains(status) else {
            // An error body, not audio: never keep it.
            try? FileManager.default.removeItem(at: location)
            Task { @MainActor [weak owner] in
                owner?.didFinish(id, file: nil, status: status, error: "HTTP \(status)", request: request)
            }
            return
        }
        let kept = FileManager.default.temporaryDirectory.appending(path: "\(id)-\(UUID().uuidString).m4a")
        let moved = (try? FileManager.default.moveItem(at: location, to: kept)) != nil
        Task { @MainActor [weak owner] in
            owner?.didFinish(
                id, file: moved ? kept : nil, status: status, error: moved ? nil : "Fichier illisible", request: request)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as? URLError)?.code == .cancelled { return }
        let message = error.localizedDescription
        Task { @MainActor [weak owner] in
            owner?.didFinish(id, file: nil, status: 0, error: message, request: nil)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Downloader.backgroundEventsFinished()
        }
    }
}
