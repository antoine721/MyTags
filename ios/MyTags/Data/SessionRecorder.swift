import Foundation
import GRDB

/// Time and taps per track (spec 9.10). Everything stays on the phone; exported as CSV.
struct TrackMetric: Codable, Sendable, Hashable {
    var trackID: String
    var milliseconds: Int = 0
    var taps: Int = 0
    var validated = false
    var acceptedSuggestions = 0
    var manualValues = 0
}

struct SessionRecord: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var tracks: [TrackMetric] = []

    var validated: [TrackMetric] { tracks.filter(\.validated) }
    var validatedCount: Int { validated.count }

    var averageSeconds: Double {
        let list = validated
        guard !list.isEmpty else { return 0 }
        return Double(list.reduce(0) { $0 + $1.milliseconds }) / Double(list.count) / 1000
    }

    var averageTaps: Double {
        let list = validated
        guard !list.isEmpty else { return 0 }
        return Double(list.reduce(0) { $0 + $1.taps }) / Double(list.count)
    }

    var totalSeconds: Double { Double(tracks.reduce(0) { $0 + $1.milliseconds }) / 1000 }
}

@MainActor
final class SessionRecorder {
    private let database: AppDatabase
    private(set) var current: SessionRecord?
    private var metric: TrackMetric?
    private var trackStartedAt: Date?
    private var lastActivity = Date()
    private static let idleLimit: TimeInterval = 600

    init(database: AppDatabase) {
        self.database = database
    }

    /// Any play or tag action; starts a session, or a new one after 10 minutes idle.
    func activity() {
        let now = Date()
        if current != nil, now.timeIntervalSince(lastActivity) > Self.idleLimit {
            _ = end()
        }
        if current == nil {
            current = SessionRecord(id: UUID().uuidString.lowercased(), startedAt: now)
            if let id = metric?.trackID {
                trackStartedAt = now
                metric = TrackMetric(trackID: id)
            }
        }
        lastActivity = now
    }

    func beginTrack(_ trackID: String) {
        closeTrack()
        metric = TrackMetric(trackID: trackID)
        trackStartedAt = Date()
    }

    func tap() {
        activity()
        metric?.taps += 1
    }

    func validated(accepted: Int, manual: Int) {
        metric?.validated = true
        metric?.acceptedSuggestions += accepted
        metric?.manualValues += manual
    }

    func manualValue() {
        metric?.manualValues += 1
    }

    private func closeTrack() {
        guard var metric, let started = trackStartedAt, current != nil else { return }
        let idleCut = min(Date(), lastActivity.addingTimeInterval(60))
        metric.milliseconds = max(0, Int(idleCut.timeIntervalSince(started) * 1000))
        if metric.taps > 0 || metric.validated {
            current?.tracks.append(metric)
        }
        self.metric = nil
        trackStartedAt = nil
    }

    /// Ends the session and stores it. Returns it when something was tagged.
    @discardableResult
    func end() -> SessionRecord? {
        closeTrack()
        guard var session = current else { return nil }
        current = nil
        session.endedAt = Date()
        guard !session.tracks.isEmpty else { return nil }
        if let data = try? JSONEncoder().encode(session) {
            try? database.pool.write { db in
                try db.execute(
                    sql: "INSERT OR REPLACE INTO sessions (id, started_at, json) VALUES (?, ?, ?)",
                    arguments: [session.id, ISO8601DateFormatter().string(from: session.startedAt), data])
            }
        }
        return session
    }

    func history(limit: Int = 50) -> [SessionRecord] {
        let rows = (try? database.pool.read { db in
            try Data.fetchAll(db, sql: "SELECT json FROM sessions ORDER BY started_at DESC LIMIT ?", arguments: [limit])
        }) ?? []
        return rows.compactMap { try? JSONDecoder().decode(SessionRecord.self, from: $0) }
    }

    func csv() -> String {
        var lines = ["session;debut;morceau;secondes;taps;valide;suggestions_acceptees;valeurs_manuelles"]
        let formatter = ISO8601DateFormatter()
        for session in history(limit: 10_000) {
            for t in session.tracks {
                lines.append([
                    session.id, formatter.string(from: session.startedAt), t.trackID,
                    String(format: "%.1f", Double(t.milliseconds) / 1000), "\(t.taps)", t.validated ? "1" : "0",
                    "\(t.acceptedSuggestions)", "\(t.manualValues)",
                ].joined(separator: ";"))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
