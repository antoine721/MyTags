import SwiftUI
import UIKit

/// Layout constants of the spec (sections 9.2 and 15).
enum Theme {
    static let spacing: CGFloat = 8
    static let labelWidth: CGFloat = 60
    static let pillHeight: CGFloat = 38
    static let compactPillHeight: CGFloat = 34
    static let minHitSize: CGFloat = 44
    static let colorDotSize: CGFloat = 34
    static let starSize: CGFloat = 40
    static let coverSize: CGFloat = 112
    static let compactCoverSize: CGFloat = 88
    static let coverCornerRadius: CGFloat = 10
    static let rowHeight: CGFloat = 60
    static let thumbnailSize: CGFloat = 44
    static let quickPassButtonHeight: CGFloat = 64
}

extension Color {
    /// Colors of the "Couleur" field: system colors, which adapt to dark mode.
    static func fieldColor(named name: String?) -> Color? {
        guard let name else { return nil }
        switch name {
        case "systemGreen": return Color(uiColor: .systemGreen)
        case "systemYellow": return Color(uiColor: .systemYellow)
        case "systemRed": return Color(uiColor: .systemRed)
        case "systemBlue": return Color(uiColor: .systemBlue)
        case "systemPurple": return Color(uiColor: .systemPurple)
        case "systemOrange": return Color(uiColor: .systemOrange)
        case "systemPink": return Color(uiColor: .systemPink)
        case "systemTeal": return Color(uiColor: .systemTeal)
        case "systemIndigo": return Color(uiColor: .systemIndigo)
        case "systemBrown": return Color(uiColor: .systemBrown)
        case "systemMint": return Color(uiColor: .systemMint)
        case "systemCyan": return Color(uiColor: .systemCyan)
        case "systemGray": return Color(uiColor: .systemGray)
        default: return nil
        }
    }

    static let fieldColorNames = [
        "systemGreen", "systemYellow", "systemRed", "systemBlue", "systemPurple", "systemOrange",
        "systemPink", "systemTeal", "systemIndigo", "systemBrown", "systemMint", "systemCyan", "systemGray",
    ]
}

extension Font {
    static let trackTitle = Font.headline
    static let trackArtist = Font.subheadline
    static let trackMeta = Font.footnote.monospacedDigit()
    static let fieldLabel = Font.caption2.weight(.semibold)
    static let pill = Font.subheadline.weight(.semibold)
}

/// Spring presets: short, interruptible, never delaying an action (spec section 15).
enum Motion {
    static let snappy = Animation.spring(response: 0.25, dampingFraction: 0.86)
    static let gentle = Animation.spring(response: 0.32, dampingFraction: 0.9)
    static let stateFade = Animation.easeOut(duration: 0.12)

    static func spring(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : snappy
    }
}
