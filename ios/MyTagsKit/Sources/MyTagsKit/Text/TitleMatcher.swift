import Foundation

/// Pattern search in titles for `title_contains` rules (`docs/modele-tags.md`, section 10).
public enum TitleMatcher {
    /// `true` when the pattern's word sequence appears consecutively in the title's words.
    ///
    /// A word is a run of Unicode letters or numbers; everything else separates words.
    /// Case is ignored. A pattern without any word never matches.
    public static func contains(title: String?, pattern: String) -> Bool {
        let needle = words(pattern)
        guard !needle.isEmpty else { return false }
        return contains(titleWords: words(title ?? ""), needle: needle)
    }

    /// `true` when any of the patterns matches.
    public static func containsAny(title: String?, patterns: [String]) -> Bool {
        containsAny(titleWords: words(title ?? ""), patterns: patterns)
    }

    static func containsAny(titleWords: [[Unicode.Scalar]], patterns: [String]) -> Bool {
        patterns.contains { pattern in
            let needle = words(pattern)
            return !needle.isEmpty && contains(titleWords: titleWords, needle: needle)
        }
    }

    /// The words of a text, uppercased, as scalar arrays.
    static func words(_ text: String) -> [[Unicode.Scalar]] {
        var result: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            if isWordScalar(scalar) {
                appendUppercased(scalar, to: &current)
            } else if !current.isEmpty {
                result.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Full uppercase mapping, as `String.uppercased()`, with an ASCII fast path.
    private static func appendUppercased(_ scalar: Unicode.Scalar, to word: inout [Unicode.Scalar]) {
        if scalar.isASCII {
            if (0x61...0x7A).contains(scalar.value), let upper = Unicode.Scalar(scalar.value - 0x20) {
                word.append(upper)
            } else {
                word.append(scalar)
            }
        } else {
            word.append(contentsOf: scalar.properties.uppercaseMapping.unicodeScalars)
        }
    }

    private static func contains(titleWords: [[Unicode.Scalar]], needle: [[Unicode.Scalar]]) -> Bool {
        guard needle.count <= titleWords.count else { return false }
        for start in 0...(titleWords.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where titleWords[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    /// Letters (L*) and numbers (N*), like Python's `[^\W_]`.
    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            let value = scalar.value
            return (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }
}
