import MyTagsKit
import SwiftUI

/// Filters: "or" inside a field, "and" across fields; special filters; save as a view (spec 9.5).
struct FilterSheet: View {
    let model: LibraryModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var savingView = false
    @State private var viewName = ""

    var body: some View {
        @Bindable var model = model
        let config = app.store.config
        NavigationStack {
            Form {
                ForEach(config.visibleFields.filter { $0.kind == .single || $0.kind == .multi }) { field in
                    Section(field.name) {
                        FlowLayout(spacing: 6) {
                            ForEach(config.options(forField: field.id)) { option in
                                let on = model.filter.fields[field.id]?.options.contains(option.id) == true
                                Pill(title: option.displayLabel, state: on ? .confirmed : .empty, compact: true) {
                                    toggle(option: option.id, field: field.id)
                                }
                            }
                            let emptyOn = model.filter.fields[field.id]?.empty == true
                            Pill(title: "vide", state: emptyOn ? .confirmed : .empty, compact: true) {
                                var f = model.filter.fields[field.id] ?? FieldFilter()
                                f.empty.toggle()
                                model.filter.fields[field.id] = f.isActive ? f : nil
                                model.selectedViewID = nil
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    }
                }
                Section("Note minimale") {
                    StarRating(
                        rating: model.filter.minRating, size: 36,
                        onRate: { model.filter.minRating = model.filter.minRating == $0 ? nil : $0 },
                        onClear: { model.filter.minRating = nil })
                }
                Section("BPM") {
                    HStack {
                        TextField("Min", value: $model.filter.bpmMin, format: .number)
                            .keyboardType(.numberPad)
                        Text("–").foregroundStyle(.secondary)
                        TextField("Max", value: $model.filter.bpmMax, format: .number)
                            .keyboardType(.numberPad)
                    }
                }
                let keys = Array(Set(app.store.liveSnapshots.compactMap(\.musicalKey))).sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
                if !keys.isEmpty {
                    Section("Tonalité") {
                        FlowLayout(spacing: 6) {
                            ForEach(keys, id: \.self) { key in
                                let on = model.filter.keys.contains(key)
                                Pill(title: key, state: on ? .confirmed : .empty, compact: true) {
                                    if on { model.filter.keys.removeAll { $0 == key } } else { model.filter.keys.append(key) }
                                }
                            }
                        }
                    }
                }
                Section("Statut") {
                    ForEach([TrackStatus.modifie, .envoye, .applique, .conflit, .erreur], id: \.self) { status in
                        Toggle(isOn: Binding(
                            get: { model.filter.statuses.contains(status.rawValue) },
                            set: { on in
                                model.filter.statuses.removeAll { $0 == status.rawValue }
                                if on { model.filter.statuses.append(status.rawValue) }
                            })
                        ) {
                            Label(status.label, systemImage: status.symbol)
                        }
                    }
                }
                Section("Morceaux") {
                    ForEach(SpecialFilter.allCases, id: \.self) { special in
                        Toggle(special.label, isOn: Binding(
                            get: { model.filter.special.contains(special.rawValue) },
                            set: { on in
                                model.filter.special.removeAll { $0 == special.rawValue }
                                if on { model.filter.special.append(special.rawValue) }
                            }))
                    }
                }
                Section {
                    Button("Enregistrer la vue") { savingView = true }
                    Button("Effacer les filtres", role: .destructive) { model.clearFilters() }
                }
            }
            .navigationTitle("Filtres")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .alert("Nom de la vue", isPresented: $savingView) {
                TextField("Nom", text: $viewName)
                Button("Enregistrer") { saveView() }
                Button("Annuler", role: .cancel) {}
            }
        }
        .presentationDetents([.large])
    }

    private func toggle(option: String, field: String) {
        var f = model.filter.fields[field] ?? FieldFilter()
        if let index = f.options.firstIndex(of: option) { f.options.remove(at: index) } else { f.options.append(option) }
        model.filter.fields[field] = f.isActive ? f : nil
        model.selectedViewID = nil
    }

    private func saveView() {
        let name = viewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var filters = model.filter
        filters.search = model.searchText
        let position = (app.store.document.savedViews.map(\.position).max() ?? 0) + 1
        let view = SavedView(
            id: UUID().uuidString.lowercased(), name: name, filters: filters, sort: model.sort,
            skipComplete: model.skipComplete, position: position, updatedAt: Timestamp.string(from: Date()))
        Task {
            await app.store.saveConfig(DirtyConfig(savedViews: [view]))
            model.selectedViewID = view.id
        }
        viewName = ""
    }
}

/// "Définir…": one field, one value, for every selected track (spec B-36), as a single action.
struct SetValueSheet: View {
    let trackIDs: [String]
    let onDone: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var fieldID: String?

    var body: some View {
        let config = app.store.config
        NavigationStack {
            Form {
                Picker("Champ", selection: $fieldID) {
                    Text("—").tag(String?.none)
                    ForEach(config.visibleFields) { Text($0.name).tag(Optional($0.id)) }
                }
                if let fieldID, let field = config.field(id: fieldID) {
                    Section("\(trackIDs.count) morceaux") {
                        if field.kind == .rating {
                            StarRating(rating: nil, onRate: { set(field, .stars($0)) }, onClear: { set(field, FieldValue()) })
                        } else {
                            FlowLayout(spacing: 6) {
                                ForEach(config.selectableOptions(forField: field.id)) { option in
                                    Pill(title: option.displayLabel, state: .empty, compact: true) {
                                        set(field, .option(option.id))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Définir…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func set(_ field: Field, _ value: FieldValue) {
        let edits = trackIDs.map { ValueEdit(trackID: $0, fieldID: field.id, value: value, source: .user) }
        if app.store.apply(edits) { Haptics.shared.success() }
        onDone()
        dismiss()
    }
}

/// "Par artiste" (spec 9.4): one tap applies a value to every track of the artist.
struct ArtistSheet: View {
    let artist: LibraryModel.ArtistRow
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var replaceExisting = false
    @State private var lastAction: (label: String, restore: [ValueEdit])?

    var body: some View {
        let config = app.store.config
        let fields = config.visibleFields.filter { $0.artistLevel && $0.kind != .rating && $0.kind != .text }
        NavigationStack {
            List {
                ForEach(fields) { field in
                    Section(field.name) {
                        FlowLayout(spacing: 6) {
                            ForEach(config.selectableOptions(forField: field.id)) { option in
                                Pill(title: option.displayLabel, state: state(field: field, option: option), compact: true) {
                                    apply(option: option, field: field)
                                }
                            }
                        }
                        Text("\(targets(for: field).count) morceaux concernés")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Remplacer aussi les valeurs existantes", isOn: $replaceExisting)
                }
                Section("Morceaux") {
                    ForEach(artist.trackIDs, id: \.self) { id in
                        if let track = app.store.tracks[id], let snapshot = app.store.snapshots[id] {
                            Button {
                                app.player.load(track, autoplay: true)
                            } label: {
                                TrackRowView(snapshot: snapshot, track: track)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle(artist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    if let lastAction {
                        Button("Annuler « \(lastAction.label) »") {
                            app.store.apply(lastAction.restore)
                            Haptics.shared.undo()
                            self.lastAction = nil
                        }
                    }
                }
            }
        }
    }

    /// Tracks of the artist that would receive a value for `field`.
    private func targets(for field: Field) -> [String] {
        artist.trackIDs.filter { id in
            replaceExisting || app.store.snapshots[id]?.confirmedFieldIDs.contains(field.id) != true
        }
    }

    private func state(field: Field, option: FieldOption) -> ValueState {
        let all = artist.trackIDs.compactMap { app.store.snapshots[$0]?.confirmedOptionIDs[field.id] }
        guard !all.isEmpty else { return .empty }
        return all.count == artist.trackIDs.count && all.allSatisfy({ $0.contains(option.id) }) ? .confirmed : .empty
    }

    private func apply(option: FieldOption, field: Field) {
        let ids = targets(for: field)
        guard !ids.isEmpty else { return }
        let restore = ids.map { id -> ValueEdit in
            if let row = app.store.rows[id]?[field.id], !row.isDeleted {
                return ValueEdit(trackID: id, fieldID: field.id, value: row.value, source: row.source)
            }
            return ValueEdit(trackID: id, fieldID: field.id, value: nil, source: .file)
        }
        let edits = ids.map { ValueEdit(trackID: $0, fieldID: field.id, value: .option(option.id), source: .user) }
        if app.store.apply(edits) {
            Haptics.shared.success()
            lastAction = ("\(field.name) \(option.displayLabel)", restore)
        }
    }
}

/// "Préparer mon trajet" (spec 9.7): a view or the queue, a number of tracks, downloaded in the background.
struct PrepareTripSheet: View {
    let defaultIDs: [String]
    let title: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var source: String = "current"
    @State private var count = 50

    var body: some View {
        let ids = selectedIDs
        let missing = ids.filter { !app.cache.offlineIDs.contains($0) }
        let bytes = missing.reduce(Int64(0)) { $0 + Int64(app.store.tracks[$1]?.audioSize ?? 3_000_000) }
        NavigationStack {
            Form {
                Picker("Morceaux", selection: $source) {
                    Text(title).tag("current")
                    ForEach(app.store.document.savedViews.filter { !$0.isDeleted }) { view in
                        Text(view.name).tag(view.id)
                    }
                }
                Picker("Nombre", selection: $count) {
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("100").tag(100)
                    Text("Tous").tag(Int.max)
                }
                .pickerStyle(.segmented)
                Section {
                    LabeledContent("À télécharger", value: "\(missing.count) morceaux")
                    LabeledContent("Taille estimée", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                    LabeledContent("Espace libre", value: ByteCountFormatter.string(fromByteCount: freeSpace, countStyle: .file))
                }
                if app.downloader.tripRemaining > 0 {
                    Section {
                        ProgressView(
                            value: Double(app.downloader.tripTotal - app.downloader.tripRemaining),
                            total: Double(max(app.downloader.tripTotal, 1)))
                        Button("Arrêter", role: .destructive) { app.downloader.cancelTrip() }
                    }
                }
                Section {
                    Button("Retirer tous les trajets du téléphone", role: .destructive) { app.cache.unpinAll() }
                        .disabled(app.cache.tripIDs.isEmpty)
                }
            }
            .navigationTitle("Préparer mon trajet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Télécharger") {
                        let items = ids.compactMap { id in
                            app.store.tracks[id]?.audioKey.map { TripItem(trackID: id, audioKey: $0) }
                        }
                        app.downloader.prepareTrip(items)
                        dismiss()
                    }
                    .disabled(ids.isEmpty || !app.sync.isOnline)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var selectedIDs: [String] {
        let all: [String]
        if source == "current" {
            all = defaultIDs
        } else if let view = app.store.document.savedViews.first(where: { $0.id == source }) {
            all = LibraryModel.results(for: view.filters, sort: view.sort, store: app.store)
        } else {
            all = []
        }
        return Array(all.prefix(count))
    }

    private var freeSpace: Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
}

/// Session recap (spec 9.10).
struct SessionSummaryView: View {
    let summary: SessionSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let current = summary.current
        VStack(spacing: 20) {
            Text("Session terminée")
                .font(.title2.weight(.semibold))
            HStack(spacing: 28) {
                metric("\(current.validatedCount)", "morceaux")
                metric(String(format: "%.0f s", current.averageSeconds), "par morceau")
                metric(String(format: "%.1f", current.averageTaps), "taps")
            }
            if let previous = summary.previous, previous.validatedCount > 0 {
                let delta = current.averageSeconds - previous.averageSeconds
                Text(delta <= 0
                    ? String(format: "%.0f s plus rapide que la session précédente", -delta)
                    : String(format: "%.0f s plus lent que la session précédente", delta))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button("OK") { dismiss() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .padding(24)
        .presentationDetents([.height(300)])
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}
