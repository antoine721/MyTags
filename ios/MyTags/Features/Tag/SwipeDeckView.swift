import MyTagsKit
import SwiftUI

/// "Actualité" sorting, like a dating app: the cover follows the finger; left archives the track
/// (keyword `ARCHIVE` added to the COMMENT), right keeps it. Buttons do the same for one-handed use.
struct SwipeDeckView: View {
    let session: TagSessionModel
    let track: Track

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragX: CGFloat = 0
    @State private var deciding = false
    @State private var pastThreshold = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let side = min(proxy.size.width, max(160, proxy.size.height - 76))
                card(side: side)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .offset(x: dragX)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(dragX / proxy.size.width) * 12), anchor: .bottom)
                    .opacity(reduceMotion ? 1 - min(0.6, abs(dragX) / proxy.size.width) : 1)
                    .gesture(drag(width: proxy.size.width))
                    .id(track.id)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in width = new }
            }
            .padding(.top, 8)
            WaveformBar(track: track)
                .padding(.top, 10)
            buttons
                .padding(.vertical, 14)
                .opacity(session.undo == nil ? 1 : 0)
                .allowsHitTesting(session.undo == nil)
                .accessibilityHidden(session.undo != nil)
                .overlay {
                    if let undo = session.undo {
                        UndoBanner(undo: undo) { session.performUndo() }
                            .transition(.opacity)
                    }
                }
        }
        .animation(Motion.spring(reduceMotion), value: track.id)
        .onChange(of: track.id) { _, _ in
            dragX = 0
            deciding = false
            pastThreshold = false
        }
    }

    @State private var width: CGFloat = 390

    private func card(side: CGFloat) -> some View {
        VStack(spacing: 10) {
            CoverImage(coverKey: track.coverKey, size: .large, side: side, cornerRadius: 18)
                .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
                .overlay(alignment: .topLeading) { stamp(archive: false).opacity(stampOpacity(1)) }
                .overlay(alignment: .topTrailing) { stamp(archive: true).opacity(stampOpacity(-1)) }
                .onTapGesture { app.player.togglePlayPause() }
            VStack(spacing: 2) {
                Text(track.title ?? "Sans titre")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(track.artist ?? "Artiste inconnu")
                    .font(.trackArtist)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: side)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Touchez la pochette pour lire ou mettre en pause")
        .accessibilityAction(named: "Archiver") { decide(archive: true) }
        .accessibilityAction(named: "D'actualité") { decide(archive: false) }
    }

    /// Neutral stamps: red and green would read as the GROUPING colors (spec 9.8).
    private func stamp(archive: Bool) -> some View {
        Label(archive ? "ARCHIVE" : "D'ACTU", systemImage: archive ? "archivebox.fill" : "checkmark")
            .font(.headline.weight(.heavy))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .rotationEffect(.degrees(archive ? 12 : -12))
            .padding(16)
            .accessibilityHidden(true)
    }

    /// 0 → 1 as the card moves towards `direction` (+1 right, −1 left).
    private func stampOpacity(_ direction: CGFloat) -> Double {
        Double(max(0, min(1, dragX * direction / (width * 0.25))))
    }

    private var buttons: some View {
        HStack(spacing: 28) {
            roundButton(symbol: "archivebox", label: "Archiver") { decide(archive: true) }
                .accessibilityIdentifier("archiveButton")
            Button {
                app.player.togglePlayPause()
            } label: {
                Image(systemName: app.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(app.player.isPlaying ? "Pause" : "Lecture")
            roundButton(symbol: "checkmark", label: "D'actualité") { decide(archive: false) }
                .accessibilityIdentifier("keepButton")
        }
        .frame(maxWidth: .infinity)
    }

    private func roundButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .frame(width: 68, height: 68)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !deciding, abs(value.translation.width) > abs(value.translation.height) || dragX != 0 else { return }
                dragX = value.translation.width
                let past = abs(dragX) > width * 0.3
                if past != pastThreshold {
                    pastThreshold = past
                    Haptics.shared.select()
                }
            }
            .onEnded { value in
                guard !deciding else { return }
                let dx = value.translation.width
                if abs(dx) > width * 0.3 || (abs(value.velocity.width) > 600 && abs(dx) > 40) {
                    decide(archive: dx < 0)
                } else {
                    pastThreshold = false
                    withAnimation(Motion.spring(reduceMotion)) { dragX = 0 }
                }
            }
    }

    /// The card leaves on its side, then the value is stored and the next track comes in.
    private func decide(archive: Bool) {
        guard !deciding else { return }
        deciding = true
        withAnimation(.easeIn(duration: reduceMotion ? 0.1 : 0.18)) { dragX = (archive ? -1 : 1) * width * 1.4 }
        Task {
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 100 : 180))
            session.swipe(archive: archive)
            // The queue may not move (last track): bring the card back.
            dragX = 0
            deciding = false
            pastThreshold = false
        }
    }
}

extension LibraryStore {
    /// Ids of the default configuration's "Actualité" field and its `ARCHIVE` value.
    static let actualiteFieldID = "fbadeb64-87dd-5b07-8f93-da92e03df7e6"
    static let archiveOptionID = "a1d69d58-a009-50d9-9611-3a5095debbab"

    /// The keyword field holding `ARCHIVE`, created as in the default configuration when missing
    /// (hidden from the Tag screen: it is sorted here, by swipe).
    func archiveField() async -> (Field, FieldOption)? {
        if let found = findArchiveField() { return found }
        guard config.field(key: "actualite") == nil else { return nil }
        let now = Timestamp.string(from: Date())
        let position = (config.fields.map(\.position).max() ?? -1) + 1
        let field = Field(
            id: Self.actualiteFieldID, key: "actualite", name: "Actualité", kind: .single, targetTag: .comment,
            targetSlot: nil, visible: false, position: position, updatedAt: now)
        let option = FieldOption(
            id: Self.archiveOptionID, fieldID: field.id, value: "ARCHIVE", label: "ARCHIVE", position: 0, updatedAt: now)
        await saveConfig(DirtyConfig(fields: [field], fieldOptions: [option]))
        return findArchiveField()
    }

    private func findArchiveField() -> (Field, FieldOption)? {
        for field in config.keywordFields {
            if let option = config.selectableOptions(forField: field.id).first(where: {
                TextNormalizer.areEquivalent($0.value, "ARCHIVE")
            }) {
                return (field, option)
            }
        }
        return nil
    }
}
