import Foundation

/// Status of a track on the phone (`docs/modele-tags.md`, section 12).
public enum TrackStatus: String, Codable, Hashable, Sendable, CaseIterable {
    /// A local change has not been sent yet.
    case modifie
    case conflit
    case erreur
    /// Sent and still to apply on the Mac.
    case envoye
    case applique
    /// No status.
    case none

    /// The first matching case wins: modifié, conflit / erreur, envoyé, appliqué, none.
    public static func compute(hasPendingLocalChanges: Bool, applyStatus: ApplyStatus, isToApply: Bool) -> TrackStatus {
        if hasPendingLocalChanges { return .modifie }
        if applyStatus == .conflit { return .conflit }
        if applyStatus == .erreur { return .erreur }
        if isToApply { return .envoye }
        if applyStatus == .applique { return .applique }
        return .none
    }
}
