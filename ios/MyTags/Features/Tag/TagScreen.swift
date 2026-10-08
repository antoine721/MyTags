import MyTagsKit
import SwiftUI
import UIKit

/// Full-screen Tag screen (spec 9.2): everything on one screen, thumb controls in the lower half.
struct TagScreen: View {
    let session: TagSessionModel

    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dismissOffset: CGFloat = 0
    @State private var newValueText = ""
    @State private var showingTrip = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .gesture(dismissDrag)
                if let track = session.currentTrack {
                    content(track: track)
                } else {
                    EndOfQueueView(session: session)
                }
            }
            .padding(.horizontal, 16)
            if let undo = session.undo {
                UndoBanner(undo: undo) { session.performUndo() }
                    .padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.spring(reduceMotion), value: session.undo)
        .offset(y: dismissOffset)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = app.settings.keepScreenOn
            Haptics.shared.prepare()
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .alert(
            "Nouvelle valeur",
            isPresented: Binding(get: { session.addingValueTo != nil }, set: { if !$0 { session.addingValueTo = nil } })
        ) {
            TextField("Valeur", text: $newValueText)
                .textInputAutocapitalization(.characters)
            Button("Ajouter") {
                if let field = session.addingValueTo {
                    let text = newValueText
                    Task { await session.addOption(text, to: field) }
                }
                newValueText = ""
            }
            Button("Annuler", role: .cancel) { newValueText = "" }
        } message: {
            Text(session.addingValueTo?.name ?? "")
        }
        .sheet(isPresented: $showingTrip) {
            PrepareTripSheet(defaultIDs: Array(session.queue.trackIDs.dropFirst(session.queue.currentIndex)), title: session.title)
        }
    }

    @ViewBuilder
    private func content(track: Track) -> some View {
        let resolved = session.resolved
        let large = dynamicTypeSize >= .accessibility1
        ViewThatFits(in: .vertical) {
            if !large { layout(track: track, resolved: resolved, compact: false) }
            if !large { layout(track: track, resolved: resolved, compact: true) }
            ScrollView {
                layout(track: track, resolved: resolved, compact: true)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func layout(track: Track, resolved: ResolvedTrack?, compact: Bool) -> some View {
        VStack(spacing: 0) {
            TrackHeaderView(
                track: track, resolved: resolved, compact: compact,
                onSwipe: { direction in direction > 0 ? session.next() : session.previous() },
                onPullDown: { dismissOffset = $0 },
                onPullDownEnded: { translation, velocity in finishPull(translation: translation, velocity: velocity) })
            .id(track.id)
            .transition(trackTransition)
            .padding(.top, 8)
            WaveformBar(track: track)
                .padding(.top, 8)
            TransportControls(
                onPrevious: { session.previous() }, onNext: { session.next() },
                canGoBack: session.queue.hasPrevious)
                .padding(.bottom, 8)
            Divider()
            Group {
                if case let .quickPass(fieldID) = session.mode, let field = session.config.field(id: fieldID) {
                    QuickPassView(session: session, field: field, resolved: resolved)
                } else if let resolved {
                    TagPanelView(session: session, resolved: resolved, compact: compact)
                }
            }
            .padding(.top, 10)
            Spacer(minLength: 56)
        }
        .animation(Motion.stateFade, value: session.queue.currentIndex)
    }

    private var trackTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let edgeIn: Edge = session.direction >= 0 ? .trailing : .leading
        let edgeOut: Edge = session.direction >= 0 ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: edgeIn).combined(with: .opacity),
                           removal: .move(edge: edgeOut).combined(with: .opacity))
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button {
                app.closeTagScreen()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Fermer")
            Spacer()
            Menu {
                QueuePickerMenu(session: session)
            } label: {
                VStack(spacing: 1) {
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(session.positionText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .frame(minHeight: 44)
            }
            .accessibilityLabel("File \(session.title), \(session.positionText)")
            Spacer()
            Menu {
                optionsMenu
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Options")
        }
        .foregroundStyle(.primary)
        .frame(height: 44)
    }

    @ViewBuilder private var optionsMenu: some View {
        @Bindable var settings = app.settings
        Section("Mode") {
            Button {
                session.stopQuickPass()
            } label: {
                if session.mode == .full {
                    Label("Complet", systemImage: "checkmark")
                } else {
                    Text("Complet")
                }
            }
            Menu("Passe rapide") {
                ForEach(session.config.visibleFields.filter { $0.kind == .single }) { field in
                    Button(field.name) { session.startQuickPass(fieldID: field.id) }
                }
            }
        }
        Section {
            Toggle("Passage automatique", isOn: $settings.autoAdvance)
            Toggle("Sauter les morceaux complets", isOn: Binding(
                get: { session.skipComplete }, set: { session.skipComplete = $0 }))
            Picker("Point de départ", selection: $settings.startPoint) {
                ForEach(StartPoint.allCases) { Text($0.label).tag($0) }
            }
        }
        Section {
            Button {
                showingTrip = true
            } label: {
                Label("Préparer mon trajet", systemImage: "arrow.down.circle")
            }
        }
    }

    /// Pull the header or the cover down to close (spec 9.1).
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard value.translation.height > 0, value.translation.height > abs(value.translation.width) else { return }
                dismissOffset = value.translation.height
            }
            .onEnded { value in
                finishPull(translation: value.translation.height, velocity: value.velocity.height)
            }
    }

    private func finishPull(translation: CGFloat, velocity: CGFloat) {
        if translation > 140 || velocity > 900 {
            app.closeTagScreen()
        }
        withAnimation(Motion.spring(reduceMotion)) { dismissOffset = 0 }
    }
}

/// Header menu: change the queue without leaving the screen.
struct QueuePickerMenu: View {
    let session: TagSessionModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let views = app.store.document.savedViews.filter { !$0.isDeleted }.sorted { $0.position < $1.position }
        ForEach(views) { view in
            Button(view.name) {
                let ids = LibraryModel.results(for: view.filters, sort: view.sort, store: app.store)
                session.replaceQueue(with: ids, title: view.name, skipComplete: view.skipComplete)
            }
        }
    }
}

/// End of the queue: a button to pick another view (spec 9.2 "File").
struct EndOfQueueView: View {
    let session: TagSessionModel
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Fin de la file")
                .font(.title3.weight(.semibold))
            Menu {
                QueuePickerMenu(session: session)
            } label: {
                Text("Choisir une autre vue")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .frame(height: 50)
            }
            .buttonStyle(.glassProminent)
            Button("Fermer") { app.closeTagScreen() }
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
