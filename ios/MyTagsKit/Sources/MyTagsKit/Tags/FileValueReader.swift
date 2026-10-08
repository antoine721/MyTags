import Foundation

/// Values deduced from the baseline (decision 0005): they count as confirmed, source `file`.
public struct FileValues: Hashable, Sendable {
    /// Recognised values by field id (GENRE, GROUPING, COMMENT positions, RATING).
    public var values: [String: FieldValue]
    /// Unrecognised GENRE / GROUPING texts by field id, as found in the file.
    public var unknownTexts: [String: String]
    /// The COMMENT reading.
    public var comment: CommentParse

    public init(
        values: [String: FieldValue] = [:], unknownTexts: [String: String] = [:],
        comment: CommentParse = CommentParse(status: .incomplet)
    ) {
        self.values = values
        self.unknownTexts = unknownTexts
        self.comment = comment
    }
}

/// Reads field values from a baseline (`docs/modele-tags.md`, sections 3, 4 and 6).
public enum FileValueReader {
    /// Reads every managed tag of the baseline.
    public static func read(baseline: Baseline?, config: TagConfig) -> FileValues {
        let baseline = baseline ?? .empty
        var result = FileValues()
        for (tag, raw) in [(TargetTag.genre, baseline.genre), (.grouping, baseline.grouping)] {
            guard let field = config.field(for: tag), let raw, !TextNormalizer.isBlank(raw) else { continue }
            if let value = match(raw, field: field, config: config) {
                result.values[field.id] = value
            } else {
                result.unknownTexts[field.id] = raw
            }
        }
        if let field = config.field(for: .rating), let rating = baseline.rating, rating != 0 {
            result.values[field.id] = FieldValue(rating: rating)
        }
        result.comment = CommentCodec.parse(baseline.comment, config: config)
        result.values.merge(result.comment.values) { _, comment in comment }
        return result
    }

    /// Recognises a GENRE / GROUPING text for a field; `nil` when the text is blank or unknown.
    ///
    /// Single choice: the first option (display order) with an equivalent candidate. Multiple
    /// choice: every `multi.separator` piece must match an option. Text: the raw text.
    public static func match(_ text: String?, field: Field, config: TagConfig) -> FieldValue? {
        guard let text, !TextNormalizer.isBlank(text) else { return nil }
        let normalized = TextNormalizer.scalars(TextNormalizer.norm(text))
        switch field.kind {
        case .text:
            return FieldValue(text: text)
        case .multi:
            let separator = config.multiSeparatorScalars
            let pieces = separator.isEmpty ? [normalized] : split(normalized, by: separator)
            var ids: [String] = []
            for piece in pieces {
                guard let id = matchOption(trimmed(piece), field: field, config: config) else { return nil }
                ids.append(id)
            }
            return FieldValue(optionIDs: config.sortedOptionIDs(ids, forField: field.id))
        case .single, .rating:
            return matchOption(normalized, field: field, config: config).map { FieldValue(optionIDs: [$0]) }
        }
    }

    private static func matchOption(_ normalized: [Unicode.Scalar], field: Field, config: TagConfig) -> String? {
        guard !normalized.isEmpty else { return nil }
        return config.candidatesByField[field.id]?.first { $0.scalars == normalized }?.optionID
    }

    private static func split(_ text: [Unicode.Scalar], by separator: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var pieces: [[Unicode.Scalar]] = []
        var start = 0
        var index = 0
        while index <= text.count - separator.count {
            if text.hasSubsequence(separator, at: index) {
                pieces.append(Array(text[start..<index]))
                index += separator.count
                start = index
            } else {
                index += 1
            }
        }
        pieces.append(Array(text[start...]))
        return pieces
    }

    private static func trimmed(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard let first = scalars.firstIndex(where: { !TextNormalizer.isWhitespace($0) }),
            let last = scalars.lastIndex(where: { !TextNormalizer.isWhitespace($0) })
        else { return [] }
        return Array(scalars[first...last])
    }
}
