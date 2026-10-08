import Foundation
import Observation

/// Settings that stay on the phone (spec section 6: cache, playback, haptics, screen).
@MainActor
@Observable
final class DeviceSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var startPoint: StartPoint { didSet { defaults.set(startPoint.rawValue, forKey: "startPoint") } }
    var skipSeconds: Double { didSet { defaults.set(skipSeconds, forKey: "skipSeconds") } }
    var autoAdvance: Bool { didSet { defaults.set(autoAdvance, forKey: "autoAdvance") } }
    var skipUnavailableOffline: Bool { didSet { defaults.set(skipUnavailableOffline, forKey: "skipUnavailableOffline") } }
    var cacheLimitBytes: Int64 { didSet { defaults.set(cacheLimitBytes, forKey: "cacheLimitBytes") } }
    var prefetchCount: Int { didSet { defaults.set(prefetchCount, forKey: "prefetchCount") } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: "hapticsEnabled") } }
    var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: "keepScreenOn") } }
    var tripRetentionDays: Int { didSet { defaults.set(tripRetentionDays, forKey: "tripRetentionDays") } }

    static let cacheLimits: [Int64] = [500_000_000, 1_000_000_000, 2_000_000_000, 5_000_000_000]
    static let prefetchCounts = [5, 10, 20]
    static let skipChoices: [Double] = [10, 15, 30]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "startPoint": StartPoint.loudest.rawValue,
            "skipSeconds": 15.0,
            "autoAdvance": true,
            "skipUnavailableOffline": true,
            "cacheLimitBytes": Int64(1_000_000_000),
            "prefetchCount": 10,
            "hapticsEnabled": true,
            "keepScreenOn": true,
            "tripRetentionDays": 14,
        ])
        startPoint = StartPoint(rawValue: defaults.string(forKey: "startPoint") ?? "") ?? .loudest
        skipSeconds = defaults.double(forKey: "skipSeconds")
        autoAdvance = defaults.bool(forKey: "autoAdvance")
        skipUnavailableOffline = defaults.bool(forKey: "skipUnavailableOffline")
        cacheLimitBytes = (defaults.object(forKey: "cacheLimitBytes") as? NSNumber)?.int64Value ?? 1_000_000_000
        prefetchCount = defaults.integer(forKey: "prefetchCount")
        hapticsEnabled = defaults.bool(forKey: "hapticsEnabled")
        keepScreenOn = defaults.bool(forKey: "keepScreenOn")
        tripRetentionDays = defaults.integer(forKey: "tripRetentionDays")
    }
}
