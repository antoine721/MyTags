import Foundation
import MyTagsKit

/// Builds configuration edits (rows stamped with a fresh `updated_at`) and saves them.
@MainActor
struct ConfigEditor {
    let store: LibraryStore

    private var now: String { Timestamp.string(from: Date()) }

    func save(field: Field) async {
        var row = field
        row.updatedAt = now
        await store.saveConfig(DirtyConfig(fields: [row]))
    }

    func save(fields: [Field]) async {
        let stamp = now
        await store.saveConfig(DirtyConfig(fields: fields.map { var f = $0; f.updatedAt = stamp; return f }))
    }

    func save(option: FieldOption) async {
        var row = option
        row.updatedAt = now
        await store.saveConfig(DirtyConfig(fieldOptions: [row]))
    }

    func save(options: [FieldOption]) async {
        let stamp = now
        await store.saveConfig(DirtyConfig(fieldOptions: options.map { var o = $0; o.updatedAt = stamp; return o }))
    }

    func save(rule: Rule) async {
        var row = rule
        row.updatedAt = now
        await store.saveConfig(DirtyConfig(rules: [row]))
    }

    func save(rules: [Rule]) async {
        let stamp = now
        await store.saveConfig(DirtyConfig(rules: rules.map { var r = $0; r.updatedAt = stamp; return r }))
    }

    func setSetting(_ key: String, _ value: JSONValue) async {
        await store.saveConfig(DirtyConfig(settings: [SettingRow(key: key, value: value, updatedAt: now)]))
    }

    /// Tracks whose confirmed value uses `optionID` (shown before renaming or deleting).
    func tracksUsing(optionID: String, fieldID: String) -> [String] {
        store.snapshots.values
            .filter { store.tracks[$0.id]?.isDeleted == false && $0.confirmedOptionIDs[fieldID]?.contains(optionID) == true }
            .map(\.id)
    }

    /// Renames a value; the old text becomes an alias so files written before still read back.
    func rename(option: FieldOption, to newValue: String, label: String?) async {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var row = option
        if value != option.value, !row.aliases.contains(option.value) {
            row.aliases.append(option.value)
        }
        row.value = value
        row.label = (label?.isEmpty == false) ? label : value
        await save(option: row)
    }

    /// Deletes a value, replacing it on every track that uses it (or emptying the field).
    func delete(option: FieldOption, replacement: FieldOption?) async {
        let ids = tracksUsing(optionID: option.id, fieldID: option.fieldID)
        let edits = ids.map { id -> ValueEdit in
            var current = store.resolve(id, suggestions: false)?[option.fieldID]?.value ?? FieldValue()
            current.optionIDs.removeAll { $0 == option.id }
            if let replacement, !current.optionIDs.contains(replacement.id) { current.optionIDs.append(replacement.id) }
            current.optionIDs = store.config.sortedOptionIDs(current.optionIDs, forField: option.fieldID)
            return ValueEdit(trackID: id, fieldID: option.fieldID, value: current, source: .user)
        }
        store.apply(edits)
        var row = option
        row.deletedAt = now
        await save(option: row)
    }

    /// Positions of the COMMENT must be 1…n, without gaps nor duplicates.
    static func commentSlotsProblem(_ fields: [Field]) -> String? {
        let slots = fields.filter { !$0.isDeleted && $0.targetTag == .comment }.compactMap(\.targetSlot).sorted()
        guard !slots.isEmpty else { return nil }
        if Set(slots).count != slots.count { return "Deux champs occupent la même position du COMMENT." }
        if slots != Array(1...slots.count) { return "Les positions du COMMENT doivent se suivre à partir de 1." }
        return nil
    }

    /// GENRE, GROUPING and the rating can each be the target of one field only.
    static func targetProblem(_ fields: [Field]) -> String? {
        for tag in [TargetTag.genre, .grouping, .rating] where fields.filter({ !$0.isDeleted && $0.targetTag == tag }).count > 1 {
            return "Un seul champ peut être écrit dans \(tag.rawValue)."
        }
        return nil
    }
}
