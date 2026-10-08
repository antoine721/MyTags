import Foundation

/// Filters and sorts library snapshots.
public enum LibraryQuery {
    /// Ids of the snapshots matching the filter, sorted.
    ///
    /// Sorting is deterministic: the requested key first (missing values last in both
    /// directions), then artist, title and id ascending.
    public static func run(filter: LibraryFilter, sort: LibrarySort, snapshots: [TrackSnapshot]) -> [String] {
        let compiled = CompiledFilter(filter)
        var matched: [Int] = []
        matched.reserveCapacity(snapshots.count)
        for index in snapshots.indices where compiled.matches(snapshots[index]) {
            matched.append(index)
        }
        matched.sort { lhs, rhs in
            precedes(snapshots[lhs], snapshots[rhs], sort: sort)
        }
        return matched.map { snapshots[$0].id }
    }

    /// `true` when the snapshot matches the filter.
    public static func matches(_ snapshot: TrackSnapshot, filter: LibraryFilter) -> Bool {
        CompiledFilter(filter).matches(snapshot)
    }

    /// Case- and diacritic-insensitive folding used for search and sorting.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func precedes(_ lhs: TrackSnapshot, _ rhs: TrackSnapshot, sort: LibrarySort) -> Bool {
        let primary: Bool?
        switch sort.key {
        case .artist: primary = compare(lhs.artistSortKey, rhs.artistSortKey, ascending: sort.ascending)
        case .title: primary = compare(lhs.titleSortKey, rhs.titleSortKey, ascending: sort.ascending)
        case .bpm: primary = compare(lhs.bpm, rhs.bpm, ascending: sort.ascending)
        case .addedAt: primary = compare(lhs.addedAt, rhs.addedAt, ascending: sort.ascending)
        case .rating: primary = compare(lhs.rating, rhs.rating, ascending: sort.ascending)
        }
        if let primary { return primary }
        if sort.key != .artist, let result = compare(lhs.artistSortKey, rhs.artistSortKey, ascending: true) {
            return result
        }
        if sort.key != .title, let result = compare(lhs.titleSortKey, rhs.titleSortKey, ascending: true) {
            return result
        }
        return lhs.id < rhs.id
    }

    /// Ordering of two texts (empty last), or `nil` when equal.
    private static func compare(_ lhs: String, _ rhs: String, ascending: Bool) -> Bool? {
        if lhs == rhs { return nil }
        if lhs.isEmpty { return false }
        if rhs.isEmpty { return true }
        return ascending ? lhs < rhs : rhs < lhs
    }

    /// Ordering of two optional values (missing last), or `nil` when equal.
    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?, ascending: Bool) -> Bool? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, _): return false
        case (_, nil): return true
        case (let left?, let right?):
            if left == right { return nil }
            return ascending ? left < right : right < left
        }
    }
}

/// A filter prepared once per query.
private struct CompiledFilter {
    let fields: [(fieldID: String, options: Set<String>, empty: Bool)]
    let minRating: Int?
    let bpmMin: Double?
    let bpmMax: Double?
    let keys: Set<String>
    let statuses: Set<String>
    let special: [SpecialFilter]
    let terms: [[UInt8]]

    init(_ filter: LibraryFilter) {
        fields = filter.fields
            .filter { $0.value.isActive }
            .sorted { $0.key < $1.key }
            .map { (fieldID: $0.key, options: Set($0.value.options), empty: $0.value.empty) }
        minRating = filter.minRating
        bpmMin = filter.bpmMin
        bpmMax = filter.bpmMax
        keys = Set(filter.keys)
        statuses = Set(filter.statuses)
        special = filter.specialFilters
        terms = LibraryQuery.fold(filter.search)
            .split(whereSeparator: { $0.isWhitespace })
            .map { Array($0.utf8) }
    }

    func matches(_ snapshot: TrackSnapshot) -> Bool {
        for field in fields {
            let selected = snapshot.confirmedOptionIDs[field.fieldID]
            let hasOption = selected.map { !$0.isDisjoint(with: field.options) } ?? false
            let isEmpty = !snapshot.confirmedFieldIDs.contains(field.fieldID)
            if !(hasOption || (field.empty && isEmpty)) { return false }
        }
        if let minRating {
            guard let rating = snapshot.rating, rating >= minRating else { return false }
        }
        if bpmMin != nil || bpmMax != nil {
            guard let bpm = snapshot.bpm else { return false }
            if let bpmMin, bpm < bpmMin { return false }
            if let bpmMax, bpm > bpmMax { return false }
        }
        if !keys.isEmpty {
            guard let key = snapshot.musicalKey, keys.contains(key) else { return false }
        }
        if !statuses.isEmpty && !statuses.contains(snapshot.status.rawValue) { return false }
        for flag in special where !Self.holds(flag, snapshot) {
            return false
        }
        for term in terms where !Self.contains(snapshot.searchBytes, term) {
            return false
        }
        return true
    }

    private static func holds(_ flag: SpecialFilter, _ snapshot: TrackSnapshot) -> Bool {
        switch flag {
        case .untagged: snapshot.isUntagged
        case .incomplete: snapshot.isIncomplete
        case .commentNonConforme: snapshot.commentStatus == .nonConforme
        case .toApply: snapshot.isToApply
        case .offline: snapshot.isOffline
        case .suggestionsAccepted: snapshot.hasAcceptedSuggestions
        case .conflictOrError: snapshot.applyStatus == .conflit || snapshot.applyStatus == .erreur
        }
    }

    /// Substring search on UTF-8 bytes (both sides folded the same way).
    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= haystack.count else { return false }
        let first = needle[0]
        var index = 0
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first {
                var offset = 1
                while offset < needle.count && haystack[index + offset] == needle[offset] { offset += 1 }
                if offset == needle.count { return true }
            }
            index += 1
        }
        return false
    }
}
