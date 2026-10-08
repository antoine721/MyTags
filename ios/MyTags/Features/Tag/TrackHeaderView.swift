import MyTagsKit
import SwiftUI

/// Cover and track information (spec 9.2 "Bloc morceau"), with the playback gestures:
/// tap = play/pause, double tap on a half = ±15 s, horizontal swipe = previous/next.
struct TrackHeaderView: View {
    let track: Track
    let resolved: ResolvedTrack?
    let compact: Bool
    let onSwipe: (Int) -> Void
    /// Pulling the cover down closes the screen: translation while dragging, then (translation, velocity).
    var onPullDown: (CGFloat) -> Void = { _ in }
    var onPullDownEnded: (CGFloat, CGFloat) -> Void = { _, _ in }

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragX: CGFloat = 0
    @State private var dragAxis: Axis?
    @State private var feedback: SkipFeedback?

    private struct SkipFeedback: Equatable {
        let id = UUID()
        let forward: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, alignment: .leading)
                .offset(x: dragX)
                .opacity(reduceMotion ? 1 - min(0.5, abs(dragX) / proxy.size.width) : 1)
                .contentShape(Rectangle())
                .gesture(swipe(width: proxy.size.width))
        }
        .frame(height: coverSide)
    }

    private var coverSide: CGFloat { compact ? Theme.compactCoverSize : Theme.coverSize }

    private var content: some View {
        HStack(alignment: .top, spacing: 14) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text(track.title ?? "Sans titre")
                    .font(.trackTitle)
                    .lineLimit(2)
                Text(track.artist ?? "Artiste inconnu")
                    .font(.trackArtist)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(meta)
                    .font(.trackMeta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                StatusLine(track: track, resolved: resolved)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cover: some View {
        CoverImage(coverKey: track.coverKey, size: .large, side: coverSide)
            .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
            .overlay {
                if let feedback {
                    Image(systemName: feedback.forward ? "goforward.15" : "gobackward.15")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                        .frame(maxWidth: .infinity, alignment: feedback.forward ? .trailing : .leading)
                        .padding(.horizontal, 10)
                        .transition(.opacity)
                        .id(feedback.id)
                }
            }
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        let forward = value.location.x > coverSide / 2
                        app.player.skip(by: forward ? app.settings.skipSeconds : -app.settings.skipSeconds)
                        withAnimation(.easeOut(duration: 0.15)) { feedback = SkipFeedback(forward: forward) }
                        Task {
                            try? await Task.sleep(for: .milliseconds(450))
                            withAnimation(.easeOut(duration: 0.2)) { feedback = nil }
                        }
                    }
                    .exclusively(before: TapGesture().onEnded {
                        app.player.togglePlayPause()
                    })
            )
            .accessibilityElement()
            .accessibilityLabel("Pochette")
            .accessibilityHint("Touchez pour lire ou mettre en pause")
            .accessibilityAction(named: "Reculer de \(Int(app.settings.skipSeconds)) secondes") {
                app.player.skip(by: -app.settings.skipSeconds)
            }
            .accessibilityAction(named: "Avancer de \(Int(app.settings.skipSeconds)) secondes") {
                app.player.skip(by: app.settings.skipSeconds)
            }
    }

    private var meta: String {
        var parts: [String] = []
        if let bpm = track.bpm { parts.append("\(Int(bpm.rounded())) BPM") }
        if let key = track.musicalKey, !key.isEmpty { parts.append(key) }
        if let ms = track.durationMs { parts.append(Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond))) }
        return parts.joined(separator: " · ")
    }

    /// The content follows the finger, springs back, and can be cancelled midway (spec 9.2).
    private func swipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                if dragAxis == nil {
                    dragAxis = abs(value.translation.width) >= abs(value.translation.height) ? .horizontal : .vertical
                }
                if dragAxis == .vertical {
                    onPullDown(max(0, value.translation.height))
                } else {
                    dragX = value.translation.width
                }
            }
            .onEnded { value in
                defer { dragAxis = nil }
                if dragAxis == .vertical {
                    onPullDownEnded(value.translation.height, value.velocity.height)
                    return
                }
                let dx = value.translation.width
                let velocity = value.velocity.width
                let passed = abs(dx) > width * 0.3 || abs(velocity) > 500
                guard passed else {
                    withAnimation(Motion.spring(reduceMotion)) { dragX = 0 }
                    return
                }
                let forward = dx < 0
                withAnimation(Motion.spring(reduceMotion)) { dragX = forward ? -width : width }
                Task {
                    try? await Task.sleep(for: .milliseconds(reduceMotion ? 60 : 140))
                    onSwipe(forward ? 1 : -1)
                    dragX = forward ? width * 0.6 : -width * 0.6
                    withAnimation(Motion.spring(reduceMotion)) { dragX = 0 }
                }
            }
    }
}

/// Status of a track: SF Symbols only, never colors that could be mistaken for GROUPING (spec 9.8).
struct StatusLine: View {
    let track: Track
    let resolved: ResolvedTrack?

    @Environment(AppModel.self) private var app

    var body: some View {
        let status = app.store.status(of: track.id)
        HStack(spacing: 5) {
            if !app.cache.offlineIDs.contains(track.id) && !app.sync.isOnline {
                Image(systemName: "icloud.slash")
                    .accessibilityLabel("Audio indisponible hors ligne")
            }
            if let text = detail {
                Text(text).lineLimit(1)
            } else if status != .none {
                Label(status.label, systemImage: status.symbol)
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var detail: String? {
        if track.applyStatus == .conflit || track.applyStatus == .erreur, let message = track.applyMessage {
            return message
        }
        if resolved?.commentStatus == .nonConforme, let comment = resolved?.commentText, !comment.isEmpty {
            return "COMMENT actuel : \(comment)"
        }
        if let unknown = resolved?.fields.values.compactMap(\.unknownFileText).first {
            return "Actuel : \(unknown)"
        }
        return nil
    }
}

extension TrackStatus {
    var symbol: String {
        switch self {
        case .modifie: "pencil.circle"
        case .envoye: "arrow.up.circle"
        case .applique: "checkmark.circle"
        case .conflit: "exclamationmark.triangle"
        case .erreur: "xmark.octagon"
        case .none: "circle"
        }
    }

    var label: String {
        switch self {
        case .modifie: "Modifié"
        case .envoye: "Envoyé"
        case .applique: "Appliqué"
        case .conflit: "Conflit"
        case .erreur: "Erreur"
        case .none: ""
        }
    }
}
