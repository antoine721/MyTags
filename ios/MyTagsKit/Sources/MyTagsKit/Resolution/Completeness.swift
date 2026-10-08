import Foundation

/// Completeness of a track (`docs/modele-tags.md`, section 8).
public enum Completeness {
    /// At least one required, visible field has no confirmed value.
    public static func isIncomplete(_ resolved: ResolvedTrack, config: TagConfig) -> Bool {
        config.fields.contains { $0.required && $0.visible && resolved[$0.id]?.state != .confirmed }
    }

    /// No field has a confirmed value.
    public static func isUntagged(_ resolved: ResolvedTrack, config: TagConfig) -> Bool {
        !config.fields.contains { resolved[$0.id]?.state == .confirmed }
    }

    /// Required, visible fields without a confirmed or suggested value, in display order.
    /// Validation is allowed when this is empty.
    public static func missingRequiredFields(_ resolved: ResolvedTrack, config: TagConfig) -> [String] {
        config.fields
            .filter { field in
                guard field.required && field.visible else { return false }
                let state = resolved[field.id]?.state ?? .empty
                return state == .empty
            }
            .map(\.id)
    }

    /// `true` when ``missingRequiredFields(_:config:)`` is empty.
    public static func isValidatable(_ resolved: ResolvedTrack, config: TagConfig) -> Bool {
        missingRequiredFields(resolved, config: config).isEmpty
    }
}
