import SwiftUI

/// Five 40 pt stars: tapping star n sets rating n; long press on the row clears it.
struct StarRating: View {
    let rating: Int?
    var size: CGFloat = Theme.starSize
    let onRate: (Int) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onRate(star)
                } label: {
                    Image(systemName: star <= (rating ?? 0) ? "star.fill" : "star")
                        .font(.system(size: size * 0.62, weight: .medium))
                        .foregroundStyle(star <= (rating ?? 0) ? Color.primary : Color.secondary.opacity(0.6))
                        .frame(width: size, height: max(size, Theme.minHitSize))
                        .contentShape(Rectangle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("\(star) étoile\(star > 1 ? "s" : "")")
                .accessibilityAddTraits(star == rating ? .isSelected : [])
            }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            onClear()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Note")
        .accessibilityValue(rating.map { "\($0) sur 5" } ?? "aucune")
        .accessibilityAction(named: "Effacer la note", onClear)
    }
}
