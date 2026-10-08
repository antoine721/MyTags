import Foundation
import MyTagsKit
import Testing

@Suite("Tag queue")
struct TagQueueTests {
    @Test("Next and previous up to the end of the queue")
    func navigation() {
        var queue = TagQueue(trackIDs: ["a", "b", "c"])
        #expect(queue.currentTrackID == "a")
        #expect(queue.displayPosition == 1)
        #expect(!queue.hasPrevious)
        #expect(queue.previous() == "a")
        #expect(queue.next() == "b")
        #expect(queue.next() == "c")
        #expect(queue.next() == nil)
        #expect(queue.isAtEnd)
        #expect(queue.displayPosition == nil)
        #expect(queue.next() == nil)
        #expect(queue.previous() == "c")
        #expect(queue.hasPrevious)
    }

    @Test("Start on a track; clamped positions")
    func start() {
        #expect(TagQueue(trackIDs: ["a", "b", "c"], startingAt: "b").currentIndex == 1)
        #expect(TagQueue(trackIDs: ["a", "b"], startingAt: "zzz").currentIndex == 0)
        #expect(TagQueue(trackIDs: ["a"], currentIndex: 9).isAtEnd)
        #expect(TagQueue(trackIDs: [], currentIndex: 0).isAtEnd)
        var queue = TagQueue(trackIDs: ["a", "b"])
        queue.move(to: -4)
        #expect(queue.currentTrackID == "a")
        #expect(queue.index(of: "b") == 1)
    }

    @Test("Skip complete tracks or tracks unavailable offline")
    func skipping() {
        let complete: Set<String> = ["b", "c", "e"]
        var queue = TagQueue(trackIDs: ["a", "b", "c", "d", "e"])
        #expect(queue.nextIndex(after: 0, where: { !complete.contains($0) }) == 3)
        #expect(queue.nextIndex(after: 3, where: { !complete.contains($0) }) == nil)
        #expect(queue.nextIndex(after: -5, where: { _ in true }) == 0)
        #expect(queue.previousIndex(before: 3, where: { !complete.contains($0) }) == 0)
        #expect(queue.previousIndex(before: 99, where: { $0 == "e" }) == 4)
        #expect(queue.next(where: { !complete.contains($0) }) == "d")
        #expect(queue.previous(where: { $0 == "zzz" }) == "d")
        #expect(queue.previous(where: { !complete.contains($0) }) == "a")
        queue.move(to: 3)
        #expect(queue.next(where: { !complete.contains($0) }) == nil)
        #expect(queue.isAtEnd)
        // A track no longer matching the view stays in the frozen list.
        #expect(queue.trackIDs == ["a", "b", "c", "d", "e"])
    }

    @Test("Codable")
    func codable() throws {
        var queue = TagQueue(trackIDs: ["a", "b"])
        queue.next()
        let decoded = try JSONDecoder().decode(TagQueue.self, from: JSONEncoder().encode(queue))
        #expect(decoded == queue)
    }
}
