import Foundation

/// Target tags and "to apply" (`docs/modele-tags.md`, section 7).
public enum TargetCalculator {
    /// The managed tags the file should carry.
    ///
    /// - Parameters:
    ///   - format: `tracks.file_format`, matched exactly against `rating.write_formats`.
    ///   - rows: values of the non-deleted `track_values` rows, by field id.
    public static func targets(
        format: String, baseline: Baseline?, rows: [String: FieldValue], config: TagConfig
    ) -> Baseline {
        targets(format: format, baseline: baseline, rows: rows, commentParse: nil, config: config)
    }

    /// `true` when at least one target tag differs from the baseline.
    public static func isToApply(
        format: String, baseline: Baseline?, rows: [String: FieldValue], config: TagConfig
    ) -> Bool {
        !differingTags(targets(format: format, baseline: baseline, rows: rows, config: config), from: baseline).isEmpty
    }

    /// Tags whose target differs from the baseline (exact text, `nil` ≡ `""`).
    public static func differingTags(_ target: Baseline, from baseline: Baseline?) -> [TargetTag] {
        let baseline = baseline ?? .empty
        var result: [TargetTag] = []
        if !TextNormalizer.tagsEqual(target.genre, baseline.genre) { result.append(.genre) }
        if !TextNormalizer.tagsEqual(target.grouping, baseline.grouping) { result.append(.grouping) }
        if !TextNormalizer.tagsEqual(target.comment, baseline.comment) { result.append(.comment) }
        if target.rating != baseline.rating { result.append(.rating) }
        return result
    }

    /// Text written to GENRE / GROUPING for a value; `nil` removes the tag.
    public static func tagText(_ value: FieldValue, field: Field, config: TagConfig) -> String? {
        switch field.kind {
        case .rating:
            return value.rating.map(String.init)
        case .text:
            guard let text = value.text, !text.isEmpty else { return nil }
            return text
        case .single, .multi:
            return CommentCodec.slotText(value, field: field, config: config)
        }
    }

    static func targets(
        format: String, baseline: Baseline?, rows: [String: FieldValue], commentParse: CommentParse?,
        config: TagConfig
    ) -> Baseline {
        let baseline = baseline ?? .empty
        var target = baseline
        if let field = config.field(for: .genre), let value = rows[field.id] {
            target.genre = tagText(value, field: field, config: config)
        }
        if let field = config.field(for: .grouping), let value = rows[field.id] {
            target.grouping = tagText(value, field: field, config: config)
        }
        if let field = config.field(for: .rating), let value = rows[field.id], config.writesRating(format: format) {
            target.rating = value.rating
        }
        let commentFields = config.commentFields
        if commentFields.contains(where: { rows[$0.id] != nil }) {
            let parse = commentParse ?? CommentCodec.parse(baseline.comment, config: config)
            var slotValues: [String: FieldValue] = [:]
            for field in commentFields {
                if let row = rows[field.id] {
                    slotValues[field.id] = row
                } else if parse.isReadable, let value = parse.values[field.id] {
                    slotValues[field.id] = value
                }
            }
            target.comment = CommentCodec.compose(values: slotValues, config: config)
        }
        return target
    }
}
