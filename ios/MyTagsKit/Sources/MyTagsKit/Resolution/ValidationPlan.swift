import Foundation

/// A value to write as a confirmed `track_values` row.
public struct PlannedValue: Hashable, Sendable {
    public let fieldID: String
    public let value: FieldValue
    public let source: ValueSource

    public init(fieldID: String, value: FieldValue, source: ValueSource) {
        self.fieldID = fieldID
        self.value = value
        self.source = source
    }
}

/// What validating a track writes (decision 0005, point 4): for every field without a row, its
/// non-empty suggestion (with the suggestion's source) or its file value (source `file`).
public struct ValidationPlan: Hashable, Sendable {
    /// Values in display order.
    public let values: [PlannedValue]

    public init(values: [PlannedValue]) {
        self.values = values
    }

    public var isEmpty: Bool { values.isEmpty }

    /// Builds the plan. Check ``Completeness/isValidatable(_:config:)`` first.
    public static func make(resolved: ResolvedTrack, config: TagConfig) -> ValidationPlan {
        var values: [PlannedValue] = []
        for field in config.fields {
            guard let item = resolved[field.id], !item.hasRow, !item.value.isEmpty else { continue }
            switch item.state {
            case .suggested:
                values.append(PlannedValue(fieldID: field.id, value: item.value, source: item.source ?? .default))
            case .confirmed:
                values.append(PlannedValue(fieldID: field.id, value: item.value, source: .file))
            case .empty:
                continue
            }
        }
        return ValidationPlan(values: values)
    }

    /// The plan as journal entries. Every field had no row, so `oldValue` is `nil`.
    public func pendingChanges(trackID: String, createdAt: String, makeID: () -> String) -> [PendingChange] {
        values.map { planned in
            PendingChange(
                id: makeID(), trackID: trackID, fieldID: planned.fieldID, oldValue: nil, newValue: planned.value,
                source: planned.source, createdAt: createdAt)
        }
    }
}
