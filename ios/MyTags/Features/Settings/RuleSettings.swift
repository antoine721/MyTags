import MyTagsKit
import SwiftUI

/// Automatic rules (spec B-22): "If [field] = [value]" or "If the title contains [pattern]",
/// then suggest or apply [field] = [value].
struct RuleListView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let config = app.store.config
        let editor = ConfigEditor(store: app.store)
        let rules = config.rules.filter { !$0.isDeleted }.sorted { $0.position < $1.position }
        List {
            ForEach(rules) { rule in
                NavigationLink {
                    RuleEditorView(rule: rule)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? describe(rule, config: config) : rule.name)
                            Text(rule.mode == .apply ? "Appliquer" : "Suggérer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !rule.enabled { Image(systemName: "pause.circle").foregroundStyle(.secondary) }
                    }
                }
            }
            .onMove { from, to in
                var ordered = rules
                ordered.move(fromOffsets: from, toOffset: to)
                let updated = ordered.enumerated().map { index, rule in
                    var r = rule
                    r.position = index
                    return r
                }
                Task { await editor.save(rules: updated) }
            }
        }
        .navigationTitle("Règles")
        .toolbar {
            EditButton()
            NavigationLink {
                RuleEditorView(rule: nil)
            } label: {
                Image(systemName: "plus")
            }
        }
    }
}

func describe(_ rule: Rule, config: TagConfig) -> String {
    let target = "\(config.field(id: rule.action.fieldID)?.name ?? "?") = \(config.option(id: rule.action.optionID)?.displayLabel ?? "?")"
    switch rule.condition {
    case let .fieldEquals(fieldID, optionID):
        return "Si \(config.field(id: fieldID)?.name ?? "?") = \(config.option(id: optionID)?.displayLabel ?? "?") → \(target)"
    case let .titleContains(patterns):
        return "Si le titre contient « \(patterns.joined(separator: " », « ")) » → \(target)"
    case .unknown:
        return "Règle inconnue → \(target)"
    }
}

struct RuleEditorView: View {
    let rule: Rule?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var conditionKind = 0
    @State private var conditionField: String?
    @State private var conditionOption: String?
    @State private var patterns = ""
    @State private var actionField: String?
    @State private var actionOption: String?
    @State private var mode: RuleMode = .suggest
    @State private var enabled = true

    var body: some View {
        let config = app.store.config
        let choiceFields = config.fields.filter { $0.kind == .single || $0.kind == .multi }
        Form {
            Section {
                TextField("Nom (facultatif)", text: $name)
                Toggle("Active", isOn: $enabled)
                Picker("Mode", selection: $mode) {
                    Text("Suggérer").tag(RuleMode.suggest)
                    Text("Appliquer").tag(RuleMode.apply)
                }
            }
            Section("Si") {
                Picker("Condition", selection: $conditionKind) {
                    Text("Un champ vaut").tag(0)
                    Text("Le titre contient").tag(1)
                }
                .pickerStyle(.segmented)
                if conditionKind == 0 {
                    fieldPicker("Champ", fields: choiceFields, selection: $conditionField)
                    optionPicker(fieldID: conditionField, selection: $conditionOption)
                } else {
                    TextField("extended, extend", text: $patterns)
                        .textInputAutocapitalization(.never)
                }
            }
            Section("Alors") {
                fieldPicker("Champ", fields: choiceFields, selection: $actionField)
                optionPicker(fieldID: actionField, selection: $actionOption)
            }
            Section("Test sur 20 morceaux") {
                ForEach(preview(config: config), id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let rule {
                Section {
                    Button("Supprimer la règle", role: .destructive) {
                        var r = rule
                        r.deletedAt = Timestamp.string(from: Date())
                        let editor = ConfigEditor(store: app.store)
                        Task { await editor.save(rule: r) }
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(rule == nil ? "Nouvelle règle" : "Règle")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Enregistrer") { save() }
                    .disabled(builtRule == nil)
            }
        }
        .onAppear(perform: load)
    }

    private func fieldPicker(_ title: String, fields: [Field], selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("—").tag(String?.none)
            ForEach(fields) { Text($0.name).tag(Optional($0.id)) }
        }
    }

    @ViewBuilder
    private func optionPicker(fieldID: String?, selection: Binding<String?>) -> some View {
        if let fieldID {
            Picker("Valeur", selection: selection) {
                Text("—").tag(String?.none)
                ForEach(app.store.config.selectableOptions(forField: fieldID)) { Text($0.displayLabel).tag(Optional($0.id)) }
            }
        }
    }

    private var condition: RuleCondition? {
        if conditionKind == 0 {
            guard let conditionField, let conditionOption else { return nil }
            return .fieldEquals(fieldID: conditionField, optionID: conditionOption)
        }
        let list = patterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return list.isEmpty ? nil : .titleContains(patterns: list)
    }

    private var builtRule: Rule? {
        guard let condition, let actionField, let actionOption else { return nil }
        let position = rule?.position ?? ((app.store.config.rules.map(\.position).max() ?? -1) + 1)
        return Rule(
            id: rule?.id ?? UUID().uuidString.lowercased(), name: name, enabled: enabled, position: position,
            condition: condition, action: RuleAction(fieldID: actionField, optionID: actionOption), mode: mode)
    }

    /// What the rule would suggest on the first 20 tracks of the library.
    private func preview(config: TagConfig) -> [String] {
        guard let built = builtRule else { return ["Règle incomplète."] }
        let sample = app.store.liveTracks.sorted { ($0.title ?? "") < ($1.title ?? "") }.prefix(20)
        let target = config.option(id: built.action.optionID)?.displayLabel ?? "?"
        return sample.map { track in
            let matches: Bool
            switch built.condition {
            case let .fieldEquals(fieldID, optionID):
                matches = app.store.snapshots[track.id]?.confirmedOptionIDs[fieldID]?.contains(optionID) == true
            case let .titleContains(list):
                matches = TitleMatcher.containsAny(title: track.title, patterns: list)
            case .unknown:
                matches = false
            }
            return "\(matches ? "✓ \(target)" : "–") \(track.title ?? "")"
        }
    }

    private func load() {
        guard let rule else { return }
        name = rule.name
        enabled = rule.enabled
        mode = rule.mode
        actionField = rule.action.fieldID
        actionOption = rule.action.optionID
        switch rule.condition {
        case let .fieldEquals(fieldID, optionID):
            conditionKind = 0
            conditionField = fieldID
            conditionOption = optionID
        case let .titleContains(list):
            conditionKind = 1
            patterns = list.joined(separator: ", ")
        case .unknown:
            break
        }
    }

    private func save() {
        guard let built = builtRule else { return }
        let editor = ConfigEditor(store: app.store)
        Task { await editor.save(rule: built) }
        dismiss()
    }
}
