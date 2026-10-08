import Foundation

/// Primary artist (`docs/modele-tags.md`, section 11).
public enum ArtistName {
    /// Separators, matched case-insensitively.
    public static let separators = [
        " feat. ", " feat ", " ft. ", " ft ", " featuring ", " & ", ", ", " x ", " vs. ", " vs ",
    ]

    private static let separatorScalars: [[Unicode.Scalar]] = separators.map { Array($0.unicodeScalars) }

    /// The text before the earliest separator, trimmed; the whole (trimmed) artist when that is empty.
    public static func primary(_ artist: String?) -> String {
        let text = TextNormalizer.trim(artist ?? "")
        let scalars = Array(text.unicodeScalars)
        var cut = scalars.count
        search: for index in scalars.indices {
            for separator in separatorScalars where matches(scalars, at: index, separator) {
                cut = index
                break search
            }
        }
        let primary = TextNormalizer.trim(String(String.UnicodeScalarView(scalars[..<cut])))
        return primary.isEmpty ? text : primary
    }

    /// Key grouping tracks by primary artist: ``TextNormalizer/norm(_:)`` of ``primary(_:)``.
    /// Empty when the artist is unknown.
    public static func key(_ artist: String?) -> String {
        TextNormalizer.norm(primary(artist))
    }

    private static func matches(_ text: [Unicode.Scalar], at index: Int, _ separator: [Unicode.Scalar]) -> Bool {
        guard index + separator.count <= text.count else { return false }
        for offset in 0..<separator.count where !equalsIgnoringCase(text[index + offset], separator[offset]) {
            return false
        }
        return true
    }

    /// `separator` is lowercase ASCII; `scalar` is compared through its lowercase mapping.
    private static func equalsIgnoringCase(_ scalar: Unicode.Scalar, _ separator: Unicode.Scalar) -> Bool {
        if scalar == separator { return true }
        if scalar.isASCII {
            guard (0x41...0x5A).contains(scalar.value) else { return false }
            return scalar.value + 0x20 == separator.value
        }
        let lowered = scalar.properties.lowercaseMapping.unicodeScalars
        return lowered.count == 1 && lowered.first == separator
    }
}
