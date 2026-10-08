import SwiftUI

/// Visual state of a value (spec 9.2 "États").
enum ValueState: Equatable {
    case empty, suggested, confirmed
}

/// Shrinks slightly while pressed; the state change itself is immediate.
struct PressScaleStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// Capsule-shaped value button: empty (gray), suggested (outline), confirmed (filled, inverted text).
struct Pill: View {
    let title: String
    let state: ValueState
    var compact = false
    var expands = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.pill)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(state == .confirmed ? Color(uiColor: .systemBackground) : Color.primary)
                .padding(.horizontal, compact ? 10 : 12)
                .frame(maxWidth: expands ? .infinity : nil)
                .frame(height: compact ? Theme.compactPillHeight : Theme.pillHeight)
                .background {
                    Capsule().fill(fill)
                }
                .overlay {
                    if state == .suggested {
                        Capsule().strokeBorder(Color.primary.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                .frame(minHeight: Theme.minHitSize)
                .contentShape(Rectangle())
                .animation(Motion.stateFade, value: state)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(title)
        .accessibilityValue(state.accessibilityDescription)
        .accessibilityAddTraits(state == .confirmed ? .isSelected : [])
    }

    private var fill: Color {
        switch state {
        case .empty: Color(uiColor: .systemGray5)
        case .suggested: .clear
        case .confirmed: .primary
        }
    }
}

/// A value of the "Couleur" field: the color itself; ring + check when confirmed, dashed ring when suggested.
struct ColorDot: View {
    let color: Color
    let label: String
    let state: ValueState
    var size: CGFloat = Theme.colorDotSize
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay {
                    if state == .confirmed {
                        Image(systemName: "checkmark")
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(4)
                .overlay {
                    switch state {
                    case .confirmed:
                        Circle().strokeBorder(Color.primary, lineWidth: 2.5)
                    case .suggested:
                        Circle().strokeBorder(Color.primary.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                    case .empty:
                        EmptyView()
                    }
                }
                .frame(minWidth: Theme.minHitSize, minHeight: Theme.minHitSize)
                .contentShape(Rectangle())
                .animation(Motion.stateFade, value: state)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(label)
        .accessibilityValue(state.accessibilityDescription)
        .accessibilityAddTraits(state == .confirmed ? .isSelected : [])
    }
}

extension ValueState {
    var accessibilityDescription: String {
        switch self {
        case .empty: ""
        case .suggested: "suggérée"
        case .confirmed: "choisie"
        }
    }
}
