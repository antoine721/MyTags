import Foundation
import MyTagsKit
import Observation

/// Search, filters, sort and saved views of the Library (spec 9.5).
@MainActor
@Observable
final class LibraryModel {
    enum Tab: String, CaseIterable, Identifiable {
        case tracks = "Morceaux"
        case artists = "Artistes"
        var id: String { rawValue }
    }

    struct ArtistRow: Identifiable, Hashable {
        let key: String
        let name: String
        let count: Int
        let incomplete: Int
        let trackIDs: [String]
        var id: String { key }
    }

    var tab: Tab = .tracks
    var searchText = ""
    var filter = LibraryFilter()
    var sort = LibrarySort.default
    var selectedViewID: String? {
        didSet { if let selectedViewID { defaults.set(selectedViewID, forKey: Self.lastViewKey) } }
    }
    var skipComplete = false
    private(set) var results: [String] = []
    private(set) var artists: [ArtistRow] = []
    @ObservationIgnored private var lastKey: Int?
    @ObservationIgnored private var restoredView = false
    @ObservationIgnored private let defaults: UserDefaults

    private static let lastViewKey = "libraryLastViewID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Opens on the last chosen view, else on "À compléter": the list worth tagging.
    /// Waits for the saved views, which arrive with the first sync after pairing.
    func restoreView(store: LibraryStore) {
        guard !restoredView else { return }
        let views = store.document.savedViews.filter { !$0.isDeleted }
        guard !views.isEmpty else { return }
        restoredView = true
        guard selectedViewID == nil, filter.activeCount == 0, searchText.isEmpty else { return }
        let lastID = defaults.string(forKey: Self.lastViewKey)
        let view = views.first { $0.id == lastID }
            ?? views.first { $0.builtin && $0.filters.special.contains(SpecialFilter.incomplete.rawValue) }
        if let view { apply(view) }
    }

    func selectedView(store: LibraryStore) -> SavedView? {
        guard let selectedViewID else { return nil }
        return store.document.savedViews.first { $0.id == selectedViewID && !$0.isDeleted }
    }

    /// Title used for the Tag screen queue.
    func queueTitle(store: LibraryStore) -> String {
        if let id = selectedViewID, let view = store.document.savedViews.first(where: { $0.id == id }) {
            return view.name
        }
        return filter.activeCount > 0 || !searchText.isEmpty ? "Sélection" : "Bibliothèque"
    }

    /// Recomputes the list when the data, the filters, the search or the sort changed.
    func refresh(store: LibraryStore) {
        var effective = filter
        effective.search = searchText
        var hasher = Hasher()
        hasher.combine(store.dataVersion)
        hasher.combine(effective)
        hasher.combine(sort)
        let key = hasher.finalize()
        guard key != lastKey else { return }
        lastKey = key
        let snapshots = store.liveSnapshots
        results = LibraryQuery.run(filter: effective, sort: sort, snapshots: snapshots)
        artists = Self.artistRows(results.compactMap { store.snapshots[$0] })
    }

    static func results(for filter: LibraryFilter, sort: LibrarySort, store: LibraryStore) -> [String] {
        LibraryQuery.run(filter: filter, sort: sort, snapshots: store.liveSnapshots)
    }

    /// Artists with the most incomplete tracks first (spec 9.4).
    static func artistRows(_ snapshots: [TrackSnapshot]) -> [ArtistRow] {
        var groups: [String: (name: String, ids: [String], incomplete: Int)] = [:]
        for s in snapshots {
            let key = ArtistName.key(s.artist)
            guard !key.isEmpty else { continue }
            var entry = groups[key] ?? (s.primaryArtist, [], 0)
            entry.ids.append(s.id)
            if s.isIncomplete { entry.incomplete += 1 }
            groups[key] = entry
        }
        return groups
            .map { ArtistRow(key: $0.key, name: $0.value.name, count: $0.value.ids.count, incomplete: $0.value.incomplete,
                             trackIDs: $0.value.ids) }
            .sorted { lhs, rhs in
                if lhs.incomplete != rhs.incomplete { return lhs.incomplete > rhs.incomplete }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func apply(_ view: SavedView) {
        selectedViewID = view.id
        filter = view.filters
        sort = view.sort
        skipComplete = view.skipComplete
        searchText = filter.search
    }

    func clearFilters() {
        selectedViewID = nil
        filter = LibraryFilter()
        searchText = ""
        skipComplete = false
    }

    /// Chips under the search field: one per active criterion, removable.
    func chips(config: TagConfig) -> [FilterChip] {
        var chips: [FilterChip] = []
        for (fieldID, fieldFilter) in filter.fields.sorted(by: { $0.key < $1.key }) {
            let fieldName = config.field(id: fieldID)?.name ?? ""
            for optionID in fieldFilter.options {
                let label = config.option(id: optionID)?.displayLabel ?? "?"
                chips.append(FilterChip(id: "f:\(fieldID):\(optionID)", label: "\(fieldName) : \(label)") { model in
                    model.filter.fields[fieldID]?.options.removeAll { $0 == optionID }
                    if model.filter.fields[fieldID]?.isActive == false { model.filter.fields[fieldID] = nil }
                })
            }
            if fieldFilter.empty {
                chips.append(FilterChip(id: "f:\(fieldID):empty", label: "\(fieldName) : vide") { model in
                    model.filter.fields[fieldID]?.empty = false
                    if model.filter.fields[fieldID]?.isActive == false { model.filter.fields[fieldID] = nil }
                })
            }
        }
        if let rating = filter.minRating {
            chips.append(FilterChip(id: "rating", label: "≥ \(rating) ★") { $0.filter.minRating = nil })
        }
        if filter.bpmMin != nil || filter.bpmMax != nil {
            let low = filter.bpmMin.map { "\(Int($0))" } ?? "…"
            let high = filter.bpmMax.map { "\(Int($0))" } ?? "…"
            chips.append(FilterChip(id: "bpm", label: "BPM \(low)–\(high)") {
                $0.filter.bpmMin = nil
                $0.filter.bpmMax = nil
            })
        }
        for key in filter.keys {
            chips.append(FilterChip(id: "key:\(key)", label: key) { $0.filter.keys.removeAll { $0 == key } })
        }
        for status in filter.statuses {
            let label = TrackStatus(rawValue: status)?.label ?? status
            chips.append(FilterChip(id: "status:\(status)", label: label) { $0.filter.statuses.removeAll { $0 == status } })
        }
        for special in filter.special {
            let label = SpecialFilter(rawValue: special)?.label ?? special
            chips.append(FilterChip(id: "special:\(special)", label: label) { $0.filter.special.removeAll { $0 == special } })
        }
        return chips
    }
}

struct FilterChip: Identifiable {
    let id: String
    let label: String
    let remove: @MainActor (LibraryModel) -> Void
}

extension SpecialFilter {
    var label: String {
        switch self {
        case .untagged: "Non tagués"
        case .incomplete: "Incomplets"
        case .commentNonConforme: "COMMENT non conforme"
        case .toApply: "À appliquer"
        case .offline: "Disponibles hors ligne"
        case .suggestionsAccepted: "Suggestions acceptées"
        case .conflictOrError: "Conflits et erreurs"
        }
    }
}
