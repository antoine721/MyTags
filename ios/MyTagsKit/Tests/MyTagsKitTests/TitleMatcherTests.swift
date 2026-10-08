import Foundation
import MyTagsKit
import Testing

@Suite("Title patterns")
struct TitleMatcherTests {
    @Test("Shared vectors: title_contains", arguments: Vectors.titleContains)
    func vector(_ vector: TitleCase) {
        #expect(TitleMatcher.contains(title: vector.title, pattern: vector.pattern) == vector.match)
    }

    @Test("Shared vectors load")
    func vectorsLoad() {
        #expect(!Vectors.titleContains.isEmpty)
    }

    @Test("Edge cases")
    func edgeCases() {
        #expect(!TitleMatcher.contains(title: "Song", pattern: ""))
        #expect(!TitleMatcher.contains(title: "Song", pattern: "()"))
        #expect(!TitleMatcher.contains(title: nil, pattern: "song"))
        #expect(TitleMatcher.contains(title: "Track_Extended", pattern: "extended"))
        #expect(TitleMatcher.contains(title: "A (Radio Edit) B", pattern: "Radio-Edit"))
        #expect(!TitleMatcher.contains(title: "Radio Mix Edit", pattern: "radio edit"))
        #expect(TitleMatcher.containsAny(title: "Song (RMX)", patterns: ["remix", "rmx"]))
        #expect(!TitleMatcher.containsAny(title: "Song", patterns: []))
    }
}
