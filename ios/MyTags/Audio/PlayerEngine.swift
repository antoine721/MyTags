import AVFoundation
import MediaPlayer
import MyTagsKit
import Observation
import UIKit

/// Where playback starts (spec B-02).
enum StartPoint: String, CaseIterable, Identifiable, Sendable {
    case loudest, beginning, quarter
    var id: String { rawValue }

    var label: String {
        switch self {
        case .loudest: "Partie la plus forte"
        case .beginning: "Début"
        case .quarter: "25 %"
        }
    }

    func seconds(for track: Track) -> Double {
        let duration = Double(track.durationMs ?? 0) / 1000
        switch self {
        case .beginning: return 0
        case .quarter: return duration * 0.25
        case .loudest:
            if let start = track.startMs { return Double(start) / 1000 }
            return duration * 0.25
        }
    }
}

/// Plays local listening files (decision 0004), with lock-screen and AirPods controls.
@MainActor
@Observable
final class PlayerEngine {
    enum Availability: Equatable {
        case ready
        case loading(Double)
        case unavailable
    }

    private(set) var currentTrackID: String?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var availability: Availability = .ready
    private(set) var startTime: Double = 0

    @ObservationIgnored var startPointProvider: () -> StartPoint = { .loudest }
    var startPoint: StartPoint { startPointProvider() }
    @ObservationIgnored var onNext: (() -> Void)?
    @ObservationIgnored var onPrevious: (() -> Void)?
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored var onUnavailable: ((String) -> Void)?
    @ObservationIgnored var onPlayStarted: ((String) -> Void)?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private let downloader: Downloader
    @ObservationIgnored private let cache: AudioCache
    @ObservationIgnored private let covers: CoverLoader
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    @ObservationIgnored private var prepared: (id: String, item: AVPlayerItem)?
    @ObservationIgnored private var currentTrack: Track?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var isScrubbing = false
    @ObservationIgnored private var sessionActive = false

    init(downloader: Downloader, cache: AudioCache, covers: CoverLoader) {
        self.downloader = downloader
        self.cache = cache
        self.covers = covers
        player.automaticallyWaitsToMinimizeStalling = false
        player.actionAtItemEnd = .pause
        player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = seconds }
            }
        }
        configureSession()
        observeNotifications()
        configureRemoteCommands()
    }

    // MARK: Loading

    /// Shows `track` and plays it from the start point when `autoplay` (and the file is local or arrives).
    func load(_ track: Track, autoplay: Bool) {
        loadTask?.cancel()
        currentTrack = track
        currentTrackID = track.id
        duration = Double(track.durationMs ?? 0) / 1000
        startTime = startPoint.seconds(for: track)
        currentTime = startTime
        let wantsPlay = autoplay || isPlaying
        if let url = cache.localURL(for: track.id) {
            availability = .ready
            start(track: track, url: url, play: wantsPlay)
            return
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        guard track.audioKey != nil else {
            availability = .unavailable
            return
        }
        availability = .loading(0)
        loadTask = Task { [weak self] in
            guard let self else { return }
            let progressWatch = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    if case .loading = self.availability {
                        self.availability = .loading(self.downloader.progress[track.id] ?? 0)
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            let url = await self.downloader.waitForFile(track.id, audioKey: track.audioKey)
            progressWatch.cancel()
            guard !Task.isCancelled, self.currentTrackID == track.id else { return }
            if let url {
                self.availability = .ready
                self.start(track: track, url: url, play: wantsPlay)
            } else {
                self.availability = .unavailable
                self.isPlaying = false
                self.onUnavailable?(track.id)
            }
        }
    }

    /// Prepares the next track's player item so switching is instant.
    func prepare(_ track: Track?) {
        guard let track, track.id != currentTrackID, let url = cache.localURL(for: track.id) else { return }
        if prepared?.id == track.id { return }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        prepared = (track.id, item)
    }

    func stop() {
        loadTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTrackID = nil
        currentTrack = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func start(track: Track, url: URL, play: Bool) {
        let item: AVPlayerItem
        if let prepared, prepared.id == track.id {
            item = prepared.item
        } else {
            item = AVPlayerItem(url: url)
        }
        prepared = nil
        player.replaceCurrentItem(with: item)
        cache.touch(track.id)
        let target = startTime
        Task { [weak self] in
            guard let self else { return }
            await self.waitUntilReady(item)
            guard self.player.currentItem === item else { return }
            if self.duration <= 0 {
                let seconds = item.duration.seconds
                if seconds.isFinite { self.duration = seconds }
            }
            self.seek(to: target, thenPlay: play)
            self.updateNowPlaying()
        }
    }

    private func waitUntilReady(_ item: AVPlayerItem) async {
        for _ in 0..<200 where item.status == .unknown {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard player.currentItem != nil else {
            isPlaying = true
            return
        }
        activateSession()
        isPlaying = true
        fadeIn()
        if let id = currentTrackID { onPlayStarted?(id) }
        updateNowPlaying()
    }

    func pause() {
        fadeTask?.cancel()
        player.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        seek(to: min(max(0, currentTime + seconds), max(0, duration - 0.5)), thenPlay: isPlaying)
    }

    /// Scrubbing on the waveform: the time follows the finger, the seek happens on release.
    func scrub(to seconds: Double) {
        isScrubbing = true
        currentTime = min(max(0, seconds), duration)
    }

    func endScrub() {
        isScrubbing = false
        seek(to: currentTime, thenPlay: isPlaying)
    }

    func seek(to seconds: Double, thenPlay play: Bool) {
        currentTime = seconds
        guard player.currentItem != nil else { return }
        if play { player.volume = 0 }
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if play {
                    self.activateSession()
                    self.isPlaying = true
                    self.fadeIn()
                    if let id = self.currentTrackID { self.onPlayStarted?(id) }
                }
                self.updateNowPlaying()
            }
        }
    }

    /// 80 ms fade-in at every start and after every jump, to avoid clicks (spec section 10).
    private func fadeIn() {
        fadeTask?.cancel()
        player.volume = 0
        player.play()
        fadeTask = Task { [weak self] in
            for step in 1...8 {
                try? await Task.sleep(for: .milliseconds(10))
                guard let self, !Task.isCancelled else { return }
                self.player.volume = Float(step) / 8
            }
        }
    }

    // MARK: Audio session

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    private func activateSession() {
        guard !sessionActive else { return }
        sessionActive = (try? AVAudioSession.sharedInstance().setActive(true)) != nil
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(type: type, options: options) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    self?.pause()  // headphones unplugged
                }
            }
        })
        observers.append(center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let item = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.isPlaying = false
                self.onEnded?()
            }
        })
    }

    @ObservationIgnored private var wasPlayingBeforeInterruption = false

    private func handleInterruption(type: UInt?, options: UInt?) {
        guard let type, let kind = AVAudioSession.InterruptionType(rawValue: type) else { return }
        switch kind {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            isPlaying = false
            sessionActive = false
            updateNowPlaying()
        case .ended:
            let shouldResume = options.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            if shouldResume && wasPlayingBeforeInterruption { play() }
        @unknown default:
            break
        }
    }

    // MARK: Lock screen and AirPods

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onNext?() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.onPrevious?() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            MainActor.assumeIsolated { self?.seek(to: position, thenPlay: self?.isPlaying ?? false) }
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title ?? "",
            MPMediaItemPropertyArtist: track.artist ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let image = covers.cachedImage(coverKey: track.coverKey, size: .large)
            ?? covers.cachedImage(coverKey: track.coverKey, size: .small)
        {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
