import Foundation
import MyTagsKit
import Testing

@Suite("Change coalescing")
struct ChangeCoalescerTests {
    private func change(
        _ id: String, _ track: String, _ field: String, old: String?, new: String?, at time: String,
        source: ValueSource = .user
    ) -> PendingChange {
        PendingChange(
            id: id, trackID: track, fieldID: field, oldValue: old.map(FieldValue.option), newValue: new.map(FieldValue.option),
            source: source, createdAt: "2026-10-08T12:00:\(time).000Z")
    }

    @Test("One change per track and field: latest new value, earliest old value")
    func coalesce() {
        let changes = [
            change("1", "t1", "genre", old: nil, new: "pop", at: "01"),
            change("2", "t1", "pays", old: "fr", new: "us", at: "02"),
            change("3", "t1", "genre", old: "pop", new: "rap", at: "03", source: .rule),
            change("4", "t2", "genre", old: "x", new: nil, at: "04"),
            change("5", "t1", "genre", old: "rap", new: nil, at: "05"),
        ]
        let result = ChangeCoalescer.coalesce(changes)
        #expect(
            result == [
                change("2", "t1", "pays", old: "fr", new: "us", at: "02"),
                change("4", "t2", "genre", old: "x", new: nil, at: "04"),
                change("5", "t1", "genre", old: nil, new: nil, at: "05"),
            ])
    }

    @Test("Out-of-order input uses timestamps; equal timestamps keep the last one")
    func ordering() {
        let changes = [
            change("late", "t", "f", old: "b", new: "c", at: "09"),
            change("early", "t", "f", old: "a", new: "b", at: "01"),
            change("same1", "u", "f", old: "a", new: "b", at: "05"),
            change("same2", "u", "f", old: "b", new: "c", at: "05"),
        ]
        let result = ChangeCoalescer.coalesce(changes)
        #expect(result.map(\.id) == ["same2", "late"])
        #expect(result[0].oldValue == .option("a"))
        #expect(result[1].oldValue == .option("a"))
        #expect(result[1].newValue == .option("c"))
        #expect(ChangeCoalescer.coalesce([]).isEmpty)
    }
}
