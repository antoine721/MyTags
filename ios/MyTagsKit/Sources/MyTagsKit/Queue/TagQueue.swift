import Foundation

/// The tagging queue: a list of track ids frozen when the Tag screen opens, and a cursor.
///
/// The cursor ranges over `0...count`; `count` is the "end of queue" position.
public struct TagQueue: Codable, Hashable, Sendable {
    public let trackIDs: [String]
    public private(set) var currentIndex: Int

    /// A queue positioned at `currentIndex` (clamped to `0...count`).
    public init(trackIDs: [String], currentIndex: Int = 0) {
        self.trackIDs = trackIDs
        self.currentIndex = min(max(currentIndex, 0), trackIDs.count)
    }

    /// A queue positioned on `trackID`, or at the start when it is not in the list.
    public init(trackIDs: [String], startingAt trackID: String) {
        self.init(trackIDs: trackIDs, currentIndex: trackIDs.firstIndex(of: trackID) ?? 0)
    }

    public var count: Int { trackIDs.count }
    public var isEmpty: Bool { trackIDs.isEmpty }
    /// Past the last track ("Fin de la file").
    public var isAtEnd: Bool { currentIndex >= trackIDs.count }
    public var currentTrackID: String? { isAtEnd ? nil : trackIDs[currentIndex] }
    /// 1-based position for display ("312 / 1 240"); `nil` at the end.
    public var displayPosition: Int? { isAtEnd ? nil : currentIndex + 1 }
    public var hasPrevious: Bool { currentIndex > 0 }

    public func index(of trackID: String) -> Int? {
        trackIDs.firstIndex(of: trackID)
    }

    /// Moves to `index`, clamped to `0...count`.
    public mutating func move(to index: Int) {
        currentIndex = min(max(index, 0), trackIDs.count)
    }

    /// Moves one track forward (possibly to the end). Returns the new current track.
    @discardableResult
    public mutating func next() -> String? {
        if currentIndex < trackIDs.count { currentIndex += 1 }
        return currentTrackID
    }

    /// Moves one track back. Returns the new current track.
    @discardableResult
    public mutating func previous() -> String? {
        if currentIndex > 0 { currentIndex -= 1 }
        return currentTrackID
    }

    /// Moves to the next track satisfying `predicate`, or to the end. Returns the new current track.
    @discardableResult
    public mutating func next(where predicate: (String) -> Bool) -> String? {
        currentIndex = nextIndex(after: currentIndex, where: predicate) ?? trackIDs.count
        return currentTrackID
    }

    /// Moves to the previous track satisfying `predicate`; stays put when there is none.
    @discardableResult
    public mutating func previous(where predicate: (String) -> Bool) -> String? {
        if let index = previousIndex(before: currentIndex, where: predicate) { currentIndex = index }
        return currentTrackID
    }

    /// First index after `index` whose track satisfies `predicate` (for example "not complete"
    /// or "available offline").
    public func nextIndex(after index: Int, where predicate: (String) -> Bool) -> Int? {
        var candidate = max(index + 1, 0)
        while candidate < trackIDs.count {
            if predicate(trackIDs[candidate]) { return candidate }
            candidate += 1
        }
        return nil
    }

    /// Last index before `index` whose track satisfies `predicate`.
    public func previousIndex(before index: Int, where predicate: (String) -> Bool) -> Int? {
        var candidate = min(index, trackIDs.count) - 1
        while candidate >= 0 {
            if predicate(trackIDs[candidate]) { return candidate }
            candidate -= 1
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case trackIDs = "track_ids"
        case currentIndex = "current_index"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            trackIDs: try c.decode([String].self, forKey: .trackIDs),
            currentIndex: try c.decode(Int.self, forKey: .currentIndex, default: 0))
    }
}
