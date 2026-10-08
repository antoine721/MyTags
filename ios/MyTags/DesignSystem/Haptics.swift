import UIKit

/// Distinct haptic per action (spec section 15). Disabled from the settings.
@MainActor
final class Haptics {
    static let shared = Haptics()

    var isEnabled = true
    private let selection = UISelectionFeedbackGenerator()
    private let notification = UINotificationFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)

    private init() {}

    func prepare() {
        guard isEnabled else { return }
        selection.prepare()
        notification.prepare()
    }

    /// Choosing or removing a value; crossing the start point while scrubbing.
    func select() {
        guard isEnabled else { return }
        selection.selectionChanged()
        selection.prepare()
    }

    /// Track validated, moving on.
    func success() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
        notification.prepare()
    }

    /// A required field is missing.
    func error() {
        guard isEnabled else { return }
        notification.notificationOccurred(.error)
        notification.prepare()
    }

    /// Undo.
    func undo() {
        guard isEnabled else { return }
        light.impactOccurred()
    }
}
