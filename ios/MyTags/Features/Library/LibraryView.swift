import MyTagsKit
import SwiftUI

/// Home screen (spec 9.5): search, filters, sort, saved views, multi-selection, mini player.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var model = LibraryModel()
    @State private var showingFilters = false
    @State private var showingSettings = false
    @State private var showingTrip = false
    @State private var editMode: EditMode = .inactive
    @State private var selection = Set<String>()
    @State private var showingSetValue = false
    @State private var artistSheet: LibraryModel.ArtistRow?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List(selection: $selection) {
                headerSection
                switch model.tab {
                case .tracks:
                    ForEach(model.results, id: \.self) { id in
                        if let snapshot = app.store.snapshots[id], let track = app.store.tracks[id] {
                            row(snapshot: snapshot, track: track)
                        }
                    }
                case .artists:
                    ForEach(model.artists) { artist in
                        Button {
                            artistSheet = artist
                        } label: {
                            ArtistRowView(artist: artist)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, $editMode)
            .searchable(text: $model.searchText, prompt: "Titre, artiste, album")
            .refreshable { await app.sync.sync() }
            .navigationTitle("Bibliothèque")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .overlay { emptyState }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .onAppear { model.refresh(store: app.store) }
        .onChange(of: app.store.dataVersion) {
            // Under the Tag screen the list is invisible: recompute once it closes.
            if !app.isTagScreenPresented { model.refresh(store: app.store) }
        }
        .onChange(of: app.isTagScreenPresented) { model.refresh(store: app.store) }
        .onChange(of: model.filter) { model.refresh(store: app.store) }
        .onChange(of: model.sort) { model.refresh(store: app.store) }
        .onChange(of: model.searchText) { model.refresh(store: app.store) }
        .sheet(isPresented: $showingFilters) {
            FilterSheet(model: model).environment(app)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView().environment(app)
        }
        .sheet(isPresented: $showingTrip) {
            PrepareTripSheet(defaultIDs: model.results, title: model.queueTitle(store: app.store)).environment(app)
        }
        .sheet(isPresented: $showingSetValue) {
            SetValueSheet(trackIDs: Array(selection)) {
                selection.removeAll()
                editMode = .inactive
            }
            .environment(app)
        }
        .sheet(item: $artistSheet) { artist in
            ArtistSheet(artist: artist).environment(app)
        }
        .sheet(item: Binding(get: { app.sessionSummary }, set: { app.sessionSummary = $0 })) { summary in
            SessionSummaryView(summary: summary)
        }
    }

    // MARK: Rows

    private func row(snapshot: TrackSnapshot, track: Track) -> some View {
        Button {
            open(at: snapshot.id)
        } label: {
            TrackRowView(snapshot: snapshot, track: track)
        }
        .foregroundStyle(.primary)
        .accessibilityIdentifier("trackRow")
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .tag(snapshot.id)
        .contextMenu {
            Button { play(snapshot.id) } label: { Label("Lire", systemImage: "play") }
            Button { open(at: snapshot.id) } label: { Label("Taguer", systemImage: "tag") }
            Button {
                if let key = track.audioKey { app.downloader.prepareTrip([TripItem(trackID: snapshot.id, audioKey: key)]) }
            } label: { Label("Télécharger pour hors ligne", systemImage: "arrow.down.circle") }
            Button {
                artistSheet = model.artistRows(for: snapshot, store: app.store)
            } label: { Label("Voir l'artiste", systemImage: "person") }
        }
    }

    private func open(at id: String) {
        app.openTagScreen(
            trackIDs: model.results, title: model.queueTitle(store: app.store), startAt: id,
            skipComplete: false)
    }

    private func play(_ id: String) {
        guard let track = app.store.tracks[id] else { return }
        app.player.load(track, autoplay: true)
    }

    // MARK: Header

    @ViewBuilder private var headerSection: some View {
        @Bindable var model = model
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Affichage", selection: $model.tab) {
                    ForEach(LibraryModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                SavedViewsBar(model: model)
                let chips = model.chips(config: app.store.config)
                if !chips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(chips) { chip in
                                Button {
                                    chip.remove(model)
                                    model.selectedViewID = nil
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(chip.label)
                                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                                    }
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 10)
                                    .frame(height: 28)
                                    .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
                                }
                                .foregroundStyle(.primary)
                                .accessibilityLabel("Retirer le filtre \(chip.label)")
                            }
                        }
                    }
                }
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        }
    }

    private var countText: String {
        switch model.tab {
        case .tracks: "\(model.results.count.formatted()) morceaux"
        case .artists: "\(model.artists.count.formatted()) artistes"
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Réglages")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                sortMenu
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Trier")
            Button {
                showingFilters = true
            } label: {
                Image(systemName: model.filter.activeCount > 0
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .overlay(alignment: .topTrailing) {
                        if model.filter.activeCount > 0 {
                            Text("\(model.filter.activeCount)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color(uiColor: .systemBackground))
                                .padding(3)
                                .background(Circle().fill(Color.primary))
                                .offset(x: 8, y: -8)
                        }
                    }
            }
            .accessibilityLabel("Filtres, \(model.filter.activeCount) actifs")
            Menu {
                Button {
                    editMode = editMode.isEditing ? .inactive : .active
                    selection.removeAll()
                } label: {
                    Label(editMode.isEditing ? "Terminer la sélection" : "Sélectionner", systemImage: "checkmark.circle")
                }
                Button {
                    showingTrip = true
                } label: {
                    Label("Préparer mon trajet", systemImage: "arrow.down.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder private var sortMenu: some View {
        @Bindable var model = model
        Picker("Trier par", selection: $model.sort.key) {
            Text("Artiste").tag(LibrarySort.Key.artist)
            Text("Titre").tag(LibrarySort.Key.title)
            Text("BPM").tag(LibrarySort.Key.bpm)
            Text("Date d'ajout").tag(LibrarySort.Key.addedAt)
            Text("Note").tag(LibrarySort.Key.rating)
        }
        Toggle("Ordre croissant", isOn: $model.sort.ascending)
    }

    // MARK: Bottom

    @ViewBuilder private var bottomBar: some View {
        VStack(spacing: 8) {
            if editMode.isEditing {
                HStack {
                    Button("Définir…") { showingSetValue = true }
                        .disabled(selection.isEmpty)
                    Spacer()
                    Text("\(selection.count) sélectionnés").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Télécharger") {
                        let items = selection.compactMap { id in
                            app.store.tracks[id]?.audioKey.map { TripItem(trackID: id, audioKey: $0) }
                        }
                        app.downloader.prepareTrip(items)
                        editMode = .inactive
                        selection.removeAll()
                    }
                    .disabled(selection.isEmpty)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)
                .padding(.horizontal, 12)
            }
            SyncStatusBar()
            if app.player.currentTrackID != nil && !app.isTagScreenPresented && !editMode.isEditing {
                MiniPlayer(results: model.results, title: model.queueTitle(store: app.store))
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private var emptyState: some View {
        if app.store.isLoaded && model.tab == .tracks && model.results.isEmpty {
            if app.store.liveTracks.isEmpty {
                if let progress = app.sync.initialProgress {
                    ProgressView(value: progress) { Text("Chargement du catalogue…") }
                        .padding(40)
                } else {
                    ContentUnavailableView(
                        "Bibliothèque vide", systemImage: "music.note.list",
                        description: Text("Lancer « djtag import » sur le Mac."))
                }
            } else {
                ContentUnavailableView {
                    Label("Aucun morceau", systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Effacer les filtres") { model.clearFilters() }
                }
            }
        }
    }
}

extension LibraryModel {
    func artistRows(for snapshot: TrackSnapshot, store: LibraryStore) -> ArtistRow? {
        let key = ArtistName.key(snapshot.artist)
        let ids = store.liveSnapshots.filter { ArtistName.key($0.artist) == key }.map(\.id)
        let rows = Self.artistRows(ids.compactMap { store.snapshots[$0] })
        return rows.first
    }
}

/// 60 pt row: cover, title, artist, tag summary, status (spec 9.5 "Ligne").
struct TrackRowView: View {
    let snapshot: TrackSnapshot
    let track: Track
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(coverKey: track.coverKey, size: .small, side: Theme.thumbnailSize, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.title ?? "Sans titre")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(snapshot.artist ?? "")
                        .lineLimit(1)
                    summary
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if snapshot.isOffline {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Disponible hors ligne")
            }
            if snapshot.status != .none {
                Image(systemName: snapshot.status.symbol)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(snapshot.status.label)
            }
        }
        .frame(height: Theme.rowHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var summary: some View {
        let config = app.store.config
        if let colorField = config.field(for: .grouping),
           let optionID = snapshot.confirmedOptionIDs[colorField.id]?.first,
           let color = Color.fieldColor(named: config.option(id: optionID)?.color)
        {
            Circle().fill(color).frame(width: 8, height: 8)
        }
        if let genreField = config.field(for: .genre),
           let optionID = snapshot.confirmedOptionIDs[genreField.id]?.first,
           let genre = config.option(id: optionID)?.displayLabel
        {
            Text(genre).lineLimit(1)
        }
        if let rating = snapshot.rating, rating > 0 {
            Text(String(repeating: "★", count: rating))
        }
    }
}

struct ArtistRowView: View {
    let artist: LibraryModel.ArtistRow

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(artist.count) morceaux").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if artist.incomplete > 0 {
                Text("\(artist.incomplete) à compléter")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 52)
        .contentShape(Rectangle())
    }
}

/// Built-in and user views, as chips above the list (spec B-35).
struct SavedViewsBar: View {
    let model: LibraryModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let views = app.store.document.savedViews.filter { !$0.isDeleted }.sorted { $0.position < $1.position }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(views) { view in
                    let selected = model.selectedViewID == view.id
                    Button {
                        if selected { model.clearFilters() } else { model.apply(view) }
                    } label: {
                        Text(view.name)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .foregroundStyle(selected ? Color(uiColor: .systemBackground) : .primary)
                            .background(Capsule().fill(selected ? Color.primary : Color(uiColor: .secondarySystemFill)))
                    }
                    .contextMenu {
                        Button {
                            app.openTagScreen(
                                trackIDs: LibraryModel.results(for: view.filters, sort: view.sort, store: app.store),
                                title: view.name, skipComplete: view.skipComplete)
                        } label: { Label("Taguer cette vue", systemImage: "tag") }
                        if !view.builtin {
                            Button(role: .destructive) {
                                var deleted = view
                                deleted.deletedAt = Timestamp.string(from: Date())
                                deleted.updatedAt = deleted.deletedAt ?? deleted.updatedAt
                                Task { await app.store.saveConfig(DirtyConfig(savedViews: [deleted])) }
                                if selected { model.clearFilters() }
                            } label: { Label("Supprimer la vue", systemImage: "trash") }
                        }
                    }
                }
            }
        }
    }
}

/// "12 en attente d'envoi" when the network is missing (spec 9.5 "Synchronisation").
struct SyncStatusBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let sync = app.sync
        if app.downloader.tripRemaining > 0 {
            label("Trajet : \(app.downloader.tripTotal - app.downloader.tripRemaining) / \(app.downloader.tripTotal)",
                  symbol: "arrow.down.circle")
        } else if sync.waitingCount > 0 && !sync.isOnline {
            label("\(sync.waitingCount) en attente d'envoi", symbol: "icloud.slash")
        } else if let error = sync.lastError, sync.waitingCount > 0 {
            label(error, symbol: "exclamationmark.icloud")
        }
    }

    private func label(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .glassEffect(.regular, in: .capsule)
    }
}

/// Mini player while browsing; tap opens the Tag screen (spec B-37).
struct MiniPlayer: View {
    let results: [String]
    let title: String
    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        if let id = player.currentTrackID, let track = app.store.tracks[id] {
            HStack(spacing: 12) {
                CoverImage(coverKey: track.coverKey, size: .small, side: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(track.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
                Button {
                    if let session = app.tagSession { session.next() } else { player.onNext?() }
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Morceau suivant")
            }
            .foregroundStyle(.primary)
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .frame(height: 60)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                if app.tagSession != nil {
                    app.reopenTagScreen()
                } else {
                    app.openTagScreen(trackIDs: results, title: title, startAt: id, autoplay: player.isPlaying)
                }
            }
        }
    }
}
