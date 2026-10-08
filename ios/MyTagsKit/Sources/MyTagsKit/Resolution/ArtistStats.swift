import Foundation

/// Confirmed values per primary artist, for artist suggestions (`docs/modele-tags.md`, section 9).
///
/// Each track contributes at most one value per field. Lookups exclude the asking track in
/// O(number of distinct values), and tracks can be updated incrementally.
public struct ArtistStats: Sendable {
    private struct Contribution: Sendable {
        var artistKey: String
        var values: [String: FieldValue]
    }

    private var trackCounts: [String: Int] = [:]
    private var valueCounts: [String: [String: [FieldValue: Int]]] = [:]
    private var contributions: [String: Contribution] = [:]

    /// Empty statistics.
    public init() {}

    /// Statistics over the confirmed values (rows, then file) of every non-deleted track.
    ///
    /// - Parameter rowsByTrack: all `track_values` rows, by track id.
    public init(tracks: [Track], rowsByTrack: [String: [TrackValue]], config: TagConfig) {
        for track in tracks where track.deletedAt == nil {
            let confirmed = ValueResolver.confirmedValues(track: track, rows: rowsByTrack[track.id] ?? [], config: config)
            setTrack(id: track.id, artist: track.artist, confirmedValues: confirmed)
        }
    }

    /// Grouping key of an artist: ``ArtistName/key(_:)``.
    public static func artistKey(for artist: String?) -> String {
        ArtistName.key(artist)
    }

    /// Number of tracks of a primary artist.
    public func trackCount(artistKey: String) -> Int {
        trackCounts[artistKey] ?? 0
    }

    /// All primary artist keys with at least one track.
    public var artistKeys: [String] {
        Array(trackCounts.keys)
    }

    /// Adds or replaces a track's contribution. Rating-only values are ignored.
    public mutating func setTrack(id: String, artist: String?, confirmedValues: [String: FieldValue]) {
        removeTrack(id: id)
        let key = Self.artistKey(for: artist)
        var values: [String: FieldValue] = [:]
        for (fieldID, value) in confirmedValues where !value.optionIDs.isEmpty || !(value.text ?? "").isEmpty {
            values[fieldID] = FieldValue(optionIDs: value.optionIDs.sorted(), text: value.text)
        }
        contributions[id] = Contribution(artistKey: key, values: values)
        guard !key.isEmpty else { return }
        trackCounts[key, default: 0] += 1
        for (fieldID, value) in values {
            valueCounts[key, default: [:]][fieldID, default: [:]][value, default: 0] += 1
        }
    }

    /// Removes a track's contribution.
    public mutating func removeTrack(id: String) {
        guard let old = contributions.removeValue(forKey: id), !old.artistKey.isEmpty else { return }
        let key = old.artistKey
        trackCounts[key, default: 1] -= 1
        if trackCounts[key] == 0 { trackCounts[key] = nil }
        for (fieldID, value) in old.values {
            let count = (valueCounts[key]?[fieldID]?[value] ?? 1) - 1
            valueCounts[key]?[fieldID]?[value] = count > 0 ? count : nil
        }
        if trackCounts[key] == nil { valueCounts[key] = nil }
    }

    /// The most frequent confirmed value of the field among the other tracks of the artist,
    /// when it covers at least half of those tracks.
    ///
    /// Ties go to the value whose options come first in display order. Values with an archived
    /// or unknown option are never suggested.
    public func suggestion(
        fieldID: String, artistKey: String, excludingTrackID trackID: String?, config: TagConfig
    ) -> FieldValue? {
        guard !artistKey.isEmpty, let field = config.field(id: fieldID), let total = trackCounts[artistKey],
            let counts = valueCounts[artistKey]?[fieldID]
        else { return nil }
        let own = trackID.flatMap { contributions[$0] }.flatMap { $0.artistKey == artistKey ? $0 : nil }
        let others = total - (own == nil ? 0 : 1)
        guard others > 0 else { return nil }
        let ownValue = own?.values[fieldID]

        var best: (value: FieldValue, count: Int)?
        for (stored, storedCount) in counts {
            let count = storedCount - (stored == ownValue ? 1 : 0)
            guard count > 0 else { continue }
            let value = config.normalized(stored, for: field)
            guard !value.isEmpty, value.optionIDs.count == stored.optionIDs.count,
                value.optionIDs.allSatisfy({ config.option(id: $0)?.archived == false })
            else { continue }
            if let current = best, count < current.count || (count == current.count && !config.precedes(value, current.value)) {
                continue
            }
            best = (value, count)
        }
        guard let best, best.count * 2 >= others else { return nil }
        return best.value
    }
}
