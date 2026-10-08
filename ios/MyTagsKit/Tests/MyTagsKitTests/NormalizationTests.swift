import Foundation
import MyTagsKit
import Testing

@Suite("Normalisation")
struct NormalizationTests {
    @Test("norm collapses whitespace, trims and uppercases")
    func norm() {
        #expect(TextNormalizer.norm("  fr \t extend\n sexy ") == "FR EXTEND SEXY")
        #expect(TextNormalizer.norm("été") == "ÉTÉ")
        #expect(TextNormalizer.norm("straße") == "STRASSE")
        #expect(TextNormalizer.norm(nil) == "")
        #expect(TextNormalizer.norm(" \u{A0}\u{2003} ") == "")
    }

    @Test("Accents count in equivalence")
    func equivalence() {
        #expect(TextNormalizer.areEquivalent("rap  fr", "RAP FR"))
        #expect(!TextNormalizer.areEquivalent("É", "E"))
        // Code point comparison, like Python: precomposed and decomposed forms differ.
        #expect(!TextNormalizer.areEquivalent("\u{E9}", "e\u{301}"))
    }

    @Test("The separator is compacted, not trimmed")
    func compact() {
        #expect(TextNormalizer.compact(" ") == " ")
        #expect(TextNormalizer.compact("  -\t ") == " - ")
        #expect(TextNormalizer.compact("a  b") == "a b")
    }

    @Test("Tag comparison treats nil and empty as equal")
    func tagsEqual() {
        #expect(TextNormalizer.tagsEqual(nil, ""))
        #expect(!TextNormalizer.tagsEqual("A", "a"))
        #expect(TextNormalizer.isBlank(" \n"))
        #expect(!TextNormalizer.isBlank(" x "))
    }
}
