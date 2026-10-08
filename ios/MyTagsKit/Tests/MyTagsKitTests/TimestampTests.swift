import Foundation
import MyTagsKit
import Testing

@Suite("Timestamps")
struct TimestampTests {
    @Test("API format with milliseconds")
    func format() throws {
        let date = Date(timeIntervalSince1970: 1_791_460_800.1239)
        let text = Timestamp.string(from: date)
        #expect(text == "2026-10-08T12:00:00.123Z")
        let parsed = try #require(Timestamp.date(from: text))
        #expect(abs(parsed.timeIntervalSince1970 - 1_791_460_800.123) < 0.0005)
        #expect(Timestamp.string(from: Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00.000Z")
        #expect(Timestamp.date(from: "not a date") == nil)
    }
}
