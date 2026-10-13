import Foundation

/// Text normalisation (`docs/modele-tags.md`, section 1).
///
/// Comparisons in this package are made on Unicode scalars (code points), not with Swift's
/// canonical-equivalence `==`, so that results match the Python implementation exactly.
public enum TextNormalizer {
    /// Collapses every whitespace run into one space, trims, then uppercases.
    public static func norm(_ text: String?) -> String {
        guard let text else { return "" }
        return collapseWhitespace(text, trim: true).uppercased()
    }

    /// Collapses every whitespace run into one space, without trimming (COMMENT separator).
    public static func compact(_ text: String) -> String {
        collapseWhitespace(text, trim: false)
    }

    /// `true` when both texts have the same ``norm(_:)``.
    public static func areEquivalent(_ lhs: String?, _ rhs: String?) -> Bool {
        norm(lhs).unicodeScalars.elementsEqual(norm(rhs).unicodeScalars)
    }

    /// `true` when the text is absent or empty after ``norm(_:)``.
    public static func isBlank(_ text: String?) -> Bool {
        guard let text else { return true }
        return text.unicodeScalars.allSatisfy(isWhitespace)
    }

    /// Exact comparison where `nil` and `""` are equivalent (section 7).
    public static func tagsEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = lhs ?? ""
        let right = rhs ?? ""
        return left.unicodeScalars.elementsEqual(right.unicodeScalars)
    }

    /// Whitespace as Python's `str.isspace()`: the Unicode White_Space property plus U+001C–U+001F.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    /// Removes leading and trailing whitespace.
    static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }),
            let last = scalars.lastIndex(where: { !isWhitespace($0) })
        else { return "" }
        return String(scalars[first...last])
    }

    /// Whitespace-separated words, like Python's `str.split()`.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                if !current.isEmpty { result.append(String(current)) }
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    /// Removes trailing whitespace, like Python's `str.rstrip()`.
    static func trimEnd(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let last = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
        return String(scalars[...last])
    }

    static func scalars(_ text: String) -> [Unicode.Scalar] {
        Array(text.unicodeScalars)
    }

    private static func collapseWhitespace(_ text: String, trim: Bool) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        var started = false
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                pendingSpace = true
                continue
            }
            if pendingSpace && (started || !trim) { result.append(" ") }
            pendingSpace = false
            started = true
            result.append(scalar)
        }
        if pendingSpace && !trim { result.append(" ") }
        return String(result)
    }
}

extension Array where Element == Unicode.Scalar {
    /// `true` when `needle` occurs at `index` (code point comparison).
    func hasSubsequence(_ needle: [Unicode.Scalar], at index: Int) -> Bool {
        guard !needle.isEmpty, index >= 0, index + needle.count <= count else { return false }
        for offset in 0..<needle.count where self[index + offset] != needle[offset] {
            return false
        }
        return true
    }
}
