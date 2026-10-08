import MyTagsKit
import SwiftUI

/// Settings (spec 9.6).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section {
                    NavigationLink("Champs et valeurs") { FieldListView() }
                    NavigationLink("Format du COMMENT") { CommentFormatView() }
                    NavigationLink("Règles") { RuleListView() }
                }
                Section("Lecture") {
                    Picker("Point de départ", selection: $settings.startPoint) {
                        ForEach(StartPoint.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Saut par double tap", selection: $settings.skipSeconds) {
                        ForEach(DeviceSettings.skipChoices, id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    Toggle("Passage automatique au suivant", isOn: $settings.autoAdvance)
                    Toggle("Sauter les morceaux indisponibles hors ligne", isOn: $settings.skipUnavailableOffline)
                }
                Section("Hors ligne et cache") {
                    Picker("Taille du cache", selection: $settings.cacheLimitBytes) {
                        ForEach(DeviceSettings.cacheLimits, id: \.self) {
                            Text(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)).tag($0)
                        }
                    }
                    .onChange(of: settings.cacheLimitBytes) { _, value in
                        app.cache.limitBytes = value
                        app.cache.evict(protecting: [])
                    }
                    Picker("Morceaux préchargés", selection: $settings.prefetchCount) {
                        ForEach(DeviceSettings.prefetchCounts, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Stepper("Trajets gardés \(settings.tripRetentionDays) jours sans écoute",
                            value: $settings.tripRetentionDays, in: 1...60)
                    LabeledContent("Cache", value: ByteCountFormatter.string(fromByteCount: app.cache.autoBytes, countStyle: .file))
                    LabeledContent("Trajets", value: ByteCountFormatter.string(fromByteCount: app.cache.tripBytes, countStyle: .file))
                    Button("Vider le cache", role: .destructive) { app.cache.clearAutomatic() }
                }
                Section("Retours") {
                    Toggle("Vibrations", isOn: $settings.hapticsEnabled)
                        .onChange(of: settings.hapticsEnabled) { _, on in Haptics.shared.isEnabled = on }
                    Toggle("Écran toujours allumé pendant le tag", isOn: $settings.keepScreenOn)
                }
                AccountSection()
                Section {
                    NavigationLink("Statistiques") { StatsView() }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
    }
}

private struct AccountSection: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingUnpair = false

    var body: some View {
        let sync = app.sync
        Section("Compte et synchronisation") {
            if app.isDemo {
                LabeledContent("État", value: "Démonstration")
            } else {
                LabeledContent("État", value: sync.isOnline ? "Connecté" : "Hors ligne")
                if let host = CredentialStore.load()?.baseURL.host() {
                    LabeledContent("Serveur", value: host)
                }
                LabeledContent("Dernière synchronisation") {
                    if let date = sync.lastSyncAt {
                        Text(date, style: .relative)
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("Modifications en attente", value: "\(sync.waitingCount)")
                if let error = sync.lastError {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
                Button("Synchroniser maintenant") { sync.syncNow() }
                    .disabled(sync.phase == .syncing)
            }
            Button(app.isDemo ? "Quitter la démonstration" : "Se déconnecter", role: .destructive) {
                confirmingUnpair = true
            }
            .confirmationDialog(
                app.isDemo ? "Quitter la démonstration ?" : "Se déconnecter ?", isPresented: $confirmingUnpair,
                titleVisibility: .visible
            ) {
                Button(app.isDemo ? "Quitter" : "Se déconnecter", role: .destructive) { app.unpair() }
            } message: {
                if !app.isDemo && sync.waitingCount > 0 {
                    Text("\(sync.waitingCount) modifications n'ont pas encore été envoyées et seront perdues.")
                } else {
                    Text("Les données locales et l'audio téléchargé seront effacés du téléphone.")
                }
            }
        }
    }
}

/// Tag format of the composed COMMENT, with a live preview.
struct CommentFormatView: View {
    @Environment(AppModel.self) private var app
    @State private var separator = ""
    @State private var emptyToken = ""

    var body: some View {
        let config = app.store.config
        Form {
            Section("Séparateur") {
                TextField("Espace", text: $separator)
                    .onSubmit { save() }
                Text("Une espace par défaut.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Position vide") {
                TextField("()", text: $emptyToken)
                    .onSubmit { save() }
            }
            Section("Aperçu") {
                Text(preview(config: config))
                    .font(.body.monospaced())
            }
        }
        .navigationTitle("Format du COMMENT")
        .onAppear {
            separator = config.separator
            emptyToken = config.emptyToken
        }
        .onDisappear { save() }
    }

    private func preview(config: TagConfig) -> String {
        let sep = separator.isEmpty ? " " : separator
        let empty = emptyToken.isEmpty ? "()" : emptyToken
        let parts = config.commentFields.map { field -> String in
            config.selectableOptions(forField: field.id).first?.value ?? empty
        }
        return (parts.isEmpty ? [empty] : parts).joined(separator: sep) + "\n" + parts.enumerated()
            .map { $0.offset == 0 ? empty : $0.element }.joined(separator: sep)
    }

    private func save() {
        let editor = ConfigEditor(store: app.store)
        let config = app.store.config
        Task {
            if !separator.isEmpty, separator != config.separator { await editor.setSetting("comment.separator", .string(separator)) }
            if !emptyToken.isEmpty, emptyToken != config.emptyToken {
                await editor.setSetting("comment.empty_token", .string(emptyToken))
            }
        }
    }
}

/// Last sessions and CSV export (spec 9.10).
struct StatsView: View {
    @Environment(AppModel.self) private var app
    @State private var sessions: [SessionRecord] = []
    @State private var csvURL: URL?

    var body: some View {
        List {
            if let csvURL {
                ShareLink(item: csvURL) { Label("Exporter en CSV", systemImage: "square.and.arrow.up") }
            }
            ForEach(sessions) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.startedAt, format: .dateTime.day().month().hour().minute())
                        .font(.subheadline.weight(.semibold))
                    Text("\(session.validatedCount) validés · \(String(format: "%.0f", session.averageSeconds)) s / morceau · "
                        + "\(String(format: "%.1f", session.averageTaps)) taps")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Statistiques")
        .overlay {
            if sessions.isEmpty { ContentUnavailableView("Aucune session", systemImage: "chart.bar") }
        }
        .task {
            sessions = app.sessions.history()
            let url = FileManager.default.temporaryDirectory.appending(path: "mytags-sessions.csv")
            try? app.sessions.csv().write(to: url, atomically: true, encoding: .utf8)
            csvURL = url
        }
    }
}
