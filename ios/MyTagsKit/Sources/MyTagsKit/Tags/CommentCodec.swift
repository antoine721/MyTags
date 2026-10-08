import Foundation

/// Result of reading a composed COMMENT.
public struct CommentParse: Hashable, Sendable {
    public var status: CommentStatus
    /// Values read, by field id (options in display order).
    public var values: [String: FieldValue]
    /// Fields read as the empty token while having no option equal to it.
    public var explicitEmpty: Set<String>

    public init(status: CommentStatus, values: [String: FieldValue] = [:], explicitEmpty: Set<String> = []) {
        self.status = status
        self.values = values
        self.explicitEmpty = explicitEmpty
    }

    /// `false` for a non-conforming COMMENT, whose values are never used.
    public var isReadable: Bool { status != .nonConforme }
}

/// Reading and composition of the COMMENT (`docs/modele-tags.md`, sections 4 and 5).
public enum CommentCodec {
    /// Reads a COMMENT by exhaustive search over the positions (``TagConfig/commentFields``).
    ///
    /// Each position is read (a candidate of the field, a `multi.separator`-joined sequence of
    /// candidates for a multiple-choice field, or the empty token) or skipped. A read must be followed
    /// by the end of the text or by the separator with at least one character after it. Among the
    /// readings that consume the whole text, the best has the most positions read, then the earliest
    /// read positions, then the longest text at the first position where lengths differ. On a full
    /// tie the first reading found wins; the search tries candidates in option order (value, then
    /// aliases), then the empty token, then skipping.
    public static func parse(_ comment: String?, config: TagConfig) -> CommentParse {
        let text = TextNormalizer.scalars(TextNormalizer.norm(comment))
        guard !text.isEmpty else { return CommentParse(status: .incomplet) }
        var search = Search(text: text, config: config)
        search.visit(slot: 0, position: 0)
        guard let best = search.best else { return CommentParse(status: .nonConforme) }

        var values: [String: FieldValue] = [:]
        var explicitEmpty = Set<String>()
        for (field, read) in zip(config.commentFields, best.reads) {
            guard let read else { continue }
            if !read.optionIDs.isEmpty {
                values[field.id] = FieldValue(optionIDs: config.sortedOptionIDs(read.optionIDs, forField: field.id))
            } else if read.explicitEmpty {
                explicitEmpty.insert(field.id)
            }
        }
        let complete = best.reads.allSatisfy { $0 != nil }
        return CommentParse(status: complete ? .conforme : .incomplet, values: values, explicitEmpty: explicitEmpty)
    }

    /// Composes the COMMENT: slots 1 to ``TagConfig/commentSlotCount`` joined by the separator.
    ///
    /// A single-choice slot writes its option's `value`, a multiple-choice slot the values in
    /// display order joined by `multi.separator`; an empty slot, a slot without field and a
    /// field without options write the empty token.
    public static func compose(values: [String: FieldValue], config: TagConfig) -> String {
        guard config.commentSlotCount > 0 else { return "" }
        var parts: [String] = []
        parts.reserveCapacity(config.commentSlotCount)
        for slot in 1...config.commentSlotCount {
            guard let field = config.commentField(atSlot: slot), let value = values[field.id] else {
                parts.append(config.emptyToken)
                continue
            }
            parts.append(slotText(value, field: field, config: config) ?? config.emptyToken)
        }
        return parts.joined(separator: config.separator)
    }

    /// Text of one slot, or `nil` when the value has no option of the field.
    static func slotText(_ value: FieldValue, field: Field, config: TagConfig) -> String? {
        let texts = config.sortedOptionIDs(value.optionIDs, forField: field.id).compactMap { config.option(id: $0)?.value }
        guard let first = texts.first else { return nil }
        return field.kind == .multi ? texts.joined(separator: config.multiSeparator) : first
    }
}

private struct SlotRead {
    let optionIDs: [String]
    let explicitEmpty: Bool
    let length: Int
}

private struct Reading {
    let reads: [SlotRead?]
    let count: Int
    let flags: [Int]
    let lengths: [Int]

    init(reads: [SlotRead?]) {
        self.reads = reads
        flags = reads.map { $0 == nil ? 0 : 1 }
        lengths = reads.map { $0?.length ?? 0 }
        count = flags.reduce(0, +)
    }

    /// Lexicographic comparison of (positions read, read flags, lengths).
    func isBetter(than other: Reading) -> Bool {
        if count != other.count { return count > other.count }
        if flags != other.flags { return other.flags.lexicographicallyPrecedes(flags) }
        if lengths != other.lengths { return other.lengths.lexicographicallyPrecedes(lengths) }
        return false
    }
}

private struct Search {
    let text: [Unicode.Scalar]
    let fields: [Field]
    let candidates: [[Candidate]]
    let emptyIsOption: [Bool]
    let separator: [Unicode.Scalar]
    let multiSeparator: [Unicode.Scalar]
    let emptyToken: [Unicode.Scalar]
    var path: [SlotRead?] = []
    var best: Reading?

    init(text: [Unicode.Scalar], config: TagConfig) {
        self.text = text
        fields = config.commentFields
        separator = config.separatorScalars
        multiSeparator = config.multiSeparatorScalars
        emptyToken = config.emptyTokenScalars
        candidates = config.commentCandidates
        emptyIsOption = config.commentEmptyIsOption
    }

    mutating func visit(slot: Int, position: Int) {
        if slot == fields.count {
            if position == text.count {
                let reading = Reading(reads: path)
                if best.map({ reading.isBetter(than: $0) }) ?? true { best = reading }
            }
            return
        }
        for (next, read) in reads(slot: slot, at: position) {
            path.append(read)
            visit(slot: slot + 1, position: next)
            path.removeLast()
        }
        path.append(nil)
        visit(slot: slot + 1, position: position)
        path.removeLast()
    }

    /// Position after a read ending at `end`, or `nil` when neither the end nor a separator
    /// followed by at least one character comes next.
    private func boundary(_ end: Int) -> Int? {
        if end == text.count { return end }
        if text.hasSubsequence(separator, at: end) && end + separator.count < text.count {
            return end + separator.count
        }
        return nil
    }

    /// Every way to read `slot` at `position`, in search order.
    private func reads(slot: Int, at position: Int) -> [(Int, SlotRead)] {
        guard position < text.count else { return [] }
        var result: [(Int, SlotRead)] = []
        if fields[slot].kind == .multi {
            for (end, ids) in multiReads(from: position, candidates: candidates[slot]) {
                if let next = boundary(end) {
                    result.append((next, SlotRead(optionIDs: ids, explicitEmpty: false, length: end - position)))
                }
            }
        } else {
            for candidate in candidates[slot] where text.hasSubsequence(candidate.scalars, at: position) {
                if let next = boundary(position + candidate.scalars.count) {
                    let read = SlotRead(optionIDs: [candidate.optionID], explicitEmpty: false, length: candidate.scalars.count)
                    result.append((next, read))
                }
            }
        }
        if !emptyToken.isEmpty && !emptyIsOption[slot] && text.hasSubsequence(emptyToken, at: position),
            let next = boundary(position + emptyToken.count)
        {
            result.append((next, SlotRead(optionIDs: [], explicitEmpty: true, length: emptyToken.count)))
        }
        return result
    }

    /// Sequences of candidates joined by the multiple separator, in depth-first order.
    private func multiReads(from position: Int, candidates: [Candidate]) -> [(Int, [String])] {
        var result: [(Int, [String])] = []
        func extend(_ start: Int, _ ids: [String]) {
            for candidate in candidates where text.hasSubsequence(candidate.scalars, at: start) {
                let end = start + candidate.scalars.count
                let sequence = ids + [candidate.optionID]
                result.append((end, sequence))
                if text.hasSubsequence(multiSeparator, at: end) {
                    extend(end + multiSeparator.count, sequence)
                }
            }
        }
        extend(position, [])
        return result
    }
}
