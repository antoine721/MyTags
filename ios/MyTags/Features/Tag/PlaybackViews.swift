import MyTagsKit
import SwiftUI

/// Waveform over the full width, played part in the primary color, start point marker;
/// tap to jump, drag to scrub with a tick when crossing the start point (spec 9.2).
struct WaveformBar: View {
    let track: Track

    @Environment(AppModel.self) private var app
    @State private var samples: [UInt8] = []
    @State private var lastSide: Bool?

    var body: some View {
        let player = app.player
        let duration = max(player.duration, Double(track.durationMs ?? 0) / 1000, 0.001)
        let progress = player.currentTrackID == track.id ? min(1, player.currentTime / duration) : 0
        let marker = min(1, app.settings.startPoint.seconds(for: track) / duration)
        HStack(spacing: 10) {
            ZStack {
                if case .unavailable = player.availability, player.currentTrackID == track.id {
                    Text(app.sync.isOnline ? "Audio indisponible" : "Audio indisponible hors ligne")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    GeometryReader { proxy in
                        Canvas { context, size in
                            draw(in: context, size: size, progress: progress)
                        }
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Color.primary.opacity(0.55))
                                .frame(width: 1.5, height: proxy.size.height)
                                .offset(x: proxy.size.width * marker)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                        .gesture(scrub(width: proxy.size.width, duration: duration, marker: marker))
                    }
                }
            }
            .frame(height: 40)
            Text("\(format(player.currentTrackID == track.id ? player.currentTime : 0)) / \(format(duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .frame(height: 48)
        .task(id: track.id) {
            samples = Array(Data(base64Encoded: track.waveform ?? "") ?? Data())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position de lecture")
        .accessibilityValue("\(format(player.currentTime)) sur \(format(duration))")
        .accessibilityAdjustableAction { direction in
            let step = app.settings.skipSeconds
            player.skip(by: direction == .increment ? step : -step)
        }
    }

    private func draw(in context: GraphicsContext, size: CGSize, progress: Double) {
        let barWidth: CGFloat = 2
        let gap: CGFloat = 1
        let count = max(1, Int(size.width / (barWidth + gap)))
        let source = samples.isEmpty ? Array(repeating: UInt8(40), count: count) : samples
        let played = size.width * progress
        for i in 0..<count {
            let lower = i * source.count / count
            let upper = max(lower + 1, (i + 1) * source.count / count)
            let value = source[lower..<min(upper, source.count)].max() ?? 0
            let height = max(2, CGFloat(value) / 255 * size.height)
            let x = CGFloat(i) * (barWidth + gap)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: barWidth, height: height)
            let color: Color = x < played ? .primary : .secondary.opacity(0.35)
            context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
        }
    }

    private func scrub(width: CGFloat, duration: Double, marker: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = min(1, max(0, value.location.x / max(width, 1)))
                app.player.scrub(to: fraction * duration)
                let side = fraction >= marker
                if let lastSide, lastSide != side { Haptics.shared.select() }
                lastSide = side
            }
            .onEnded { _ in
                lastSide = nil
                app.player.endScrub()
            }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        return Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond))
    }
}

/// Previous / play-pause / next. "Previous" always goes to the previous track (spec 9.2).
struct TransportControls: View {
    let onPrevious: () -> Void
    let onNext: () -> Void
    let canGoBack: Bool

    @Environment(AppModel.self) private var app

    var body: some View {
        let player = app.player
        HStack {
            Spacer()
            Button(action: onPrevious) {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .frame(width: 60, height: 52)
            }
            .disabled(!canGoBack)
            .accessibilityLabel("Morceau précédent")
            Spacer()
            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    if case let .loading(progress) = player.availability {
                        Circle()
                            .trim(from: 0, to: max(0.04, progress))
                            .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 50, height: 50)
                            .animation(.linear(duration: 0.15), value: progress)
                    }
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34))
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 72, height: 52)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Lecture")
            Spacer()
            Button(action: onNext) {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .frame(width: 60, height: 52)
            }
            .accessibilityLabel("Morceau suivant")
            Spacer()
        }
        .buttonStyle(PressScaleStyle())
        .foregroundStyle(.primary)
        .frame(height: 52)
    }
}
