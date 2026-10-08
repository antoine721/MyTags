import MyTagsKit
import Testing

@Suite struct SmokeTests {
    @Test func defaultSeparatorIsSpace() {
        #expect(TextNormalizer.norm("  fr  extend ") == "FR EXTEND")
    }
}
