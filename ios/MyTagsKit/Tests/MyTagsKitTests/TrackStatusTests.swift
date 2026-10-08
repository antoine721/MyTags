import Foundation
import MyTagsKit
import Testing

@Suite("Track status")
struct TrackStatusTests {
    struct Case: Sendable, CustomStringConvertible {
        let pending: Bool
        let apply: ApplyStatus
        let toApply: Bool
        let expected: TrackStatus
        var description: String { "\(pending) \(apply.rawValue) \(toApply) → \(expected.rawValue)" }
    }

    static let cases: [Case] = [
        Case(pending: true, apply: .conflit, toApply: true, expected: .modifie),
        Case(pending: true, apply: .aucun, toApply: false, expected: .modifie),
        Case(pending: false, apply: .conflit, toApply: true, expected: .conflit),
        Case(pending: false, apply: .erreur, toApply: false, expected: .erreur),
        Case(pending: false, apply: .applique, toApply: true, expected: .envoye),
        Case(pending: false, apply: .aucun, toApply: true, expected: .envoye),
        Case(pending: false, apply: .applique, toApply: false, expected: .applique),
        Case(pending: false, apply: .aucun, toApply: false, expected: .none),
        Case(pending: false, apply: .aAppliquer, toApply: false, expected: .none),
    ]

    @Test("First matching case wins", arguments: cases)
    func compute(_ item: Case) {
        #expect(
            TrackStatus.compute(hasPendingLocalChanges: item.pending, applyStatus: item.apply, isToApply: item.toApply)
                == item.expected)
    }
}
