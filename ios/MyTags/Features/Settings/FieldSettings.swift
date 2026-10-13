import MyTagsKit
import SwiftUI

/// Fields: reorderable list (spec B-40, B-42).
struct FieldListView: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        let fields = app.store.config.fields
        let editor = ConfigEditor(store: app.store)
        List {
            if let problem = ConfigEditor.commentSlotsProblem(fields) ?? ConfigEditor.targetProblem(fields) {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
            }
            ForEach(fields) { field in
                NavigationLink {
                    FieldEditorView(fieldID: field.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(field.name)
                            Text(targetDescription(field))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !field.visible { Image(systemName: "eye.slash").foregroundStyle(.secondary) }
                        if field.required { Image(systemName: "asterisk").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .onMove { from, to in
                var ordered = fields
                ordered.move(fromOffsets: from, toOffset: to)
                let updated = ordered.enumerated().map { index, field in
                    var f = field
                    f.position = index
                    return f
                }
                Task { await editor.save(fields: updated) }
            }
        }
        .navigationTitle("Champs")
        .toolbar {
            EditButton()
            Button { adding = true } label: { Image(systemName: "plus") }
        }
        .alert("Nouveau champ", isPresented: $adding) {
            TextField("Nom", text: $newName)
            Button("Créer") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                newName = ""
                guard !name.isEmpty else { return }
                let slot = (app.store.config.commentFields.compactMap(\.targetSlot).max() ?? 0) + 1
                let field = Field(
                    id: UUID().uuidString.lowercased(), key: name.lowercased(), name: name, kind: .single,
                    targetTag: .comment, targetSlot: slot, position: fields.count)
                Task { await editor.save(field: field) }
            }
            Button("Annuler", role: .cancel) { newName = "" }
        }
    }
}

func targetDescription(_ field: Field) -> String {
    switch field.targetTag {
    case .comment: field.targetSlot.map { "COMMENT, position \($0)" } ?? "COMMENT, mot-clé"
    case .rating: "Note"
    default: field.targetTag.rawValue
    }
}

/// One field: name, type, target, flags, default value, and its values (spec B-41 – B-43).
struct FieldEditorView: View {
    let fieldID: String
    @Environment(AppModel.self) private var app
    @State private var name = ""
    @State private var addingValue = false
    @State private var newValue = ""
    @State private var confirmingDelete = false

    var body: some View {
        let config = app.store.config
        let editor = ConfigEditor(store: app.store)
        if let field = config.field(id: fieldID) {
            Form {
                Section {
                    TextField("Nom", text: $name)
                        .onSubmit { update(field) { $0.name = name } }
                    Picker("Type", selection: binding(field, \.kind)) {
                        Text("Choix unique").tag(FieldKind.single)
                        Text("Choix multiple").tag(FieldKind.multi)
                        Text("Note").tag(FieldKind.rating)
                        Text("Texte").tag(FieldKind.text)
                    }
                    Picker("Écrit dans", selection: targetBinding(field)) {
                        Text("GENRE").tag("GENRE")
                        Text("GROUPING").tag("GROUPING")
                        ForEach(1...max(3, config.commentSlotCount + 1), id: \.self) { slot in
                            Text("COMMENT, position \(slot)").tag("COMMENT:\(slot)")
                        }
                        Text("COMMENT, mot-clé").tag("COMMENT:")
                        Text("Note").tag("RATING")
                    }
                }
                Section {
                    Toggle("Obligatoire", isOn: binding(field, \.required))
                    Toggle("Visible sur l'écran Taguer", isOn: binding(field, \.visible))
                    Toggle("Valide le morceau", isOn: advanceBinding(field))
                    Toggle("Proposé « par artiste »", isOn: binding(field, \.artistLevel))
                    if field.kind == .single || field.kind == .multi {
                        Picker("Valeur par défaut", selection: binding(field, \.defaultOptionID)) {
                            Text("Aucune").tag(String?.none)
                            ForEach(config.selectableOptions(forField: field.id)) { Text($0.displayLabel).tag(Optional($0.id)) }
                        }
                    }
                }
                if field.kind == .single || field.kind == .multi {
                    Section {
                        ForEach(config.options(forField: field.id)) { option in
                            NavigationLink {
                                OptionEditorView(optionID: option.id)
                            } label: {
                                HStack {
                                    if let color = Color.fieldColor(named: option.color) {
                                        Circle().fill(color).frame(width: 14, height: 14)
                                    }
                                    Text(option.displayLabel)
                                    if option.archived {
                                        Text("archivée").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(editor.tracksUsing(optionID: option.id, fieldID: field.id).count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onMove { from, to in
                            var ordered = config.options(forField: field.id)
                            ordered.move(fromOffsets: from, toOffset: to)
                            let updated = ordered.enumerated().map { index, option in
                                var o = option
                                o.position = index
                                return o
                            }
                            Task { await editor.save(options: updated) }
                        }
                        Button("Ajouter une valeur") { addingValue = true }
                    } header: {
                        Text("Valeurs")
                    } footer: {
                        switch LayoutBudget.fit(config: config) {
                        case .normal: EmptyView()
                        case .compact: Text("L'écran Taguer passe en mode compact avec cette configuration.")
                        case .scrolling: Text("Trop de valeurs visibles : l'écran Taguer devra défiler. Raccourcissez des libellés ou masquez un champ.")
                        }
                    }
                }
                Section {
                    Button("Supprimer le champ", role: .destructive) { confirmingDelete = true }
                }
            }
            .navigationTitle(field.name)
            .toolbar { EditButton() }
            .onAppear { name = field.name }
            .alert("Nouvelle valeur", isPresented: $addingValue) {
                TextField("Valeur", text: $newValue)
                    .textInputAutocapitalization(.characters)
                Button("Ajouter") {
                    let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    newValue = ""
                    guard !value.isEmpty else { return }
                    let position = (config.options(forField: field.id).map(\.position).max() ?? -1) + 1
                    let option = FieldOption(
                        id: UUID().uuidString.lowercased(), fieldID: field.id, value: value, label: value, position: position)
                    Task { await editor.save(option: option) }
                }
                Button("Annuler", role: .cancel) { newValue = "" }
            }
            .confirmationDialog("Supprimer le champ « \(field.name) » ?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) {
                    update(field) { $0.deletedAt = Timestamp.string(from: Date()) }
                }
            } message: {
                Text("Les tags déjà écrits dans les fichiers ne changent pas.")
            }
        } else {
            ContentUnavailableView("Champ supprimé", systemImage: "trash")
        }
    }

    private func update(_ field: Field, _ change: (inout Field) -> Void) {
        var f = field
        change(&f)
        let editor = ConfigEditor(store: app.store)
        Task { await editor.save(field: f) }
    }

    private func binding<Value>(_ field: Field, _ keyPath: WritableKeyPath<Field, Value>) -> Binding<Value> {
        Binding(get: { field[keyPath: keyPath] }, set: { value in update(field) { $0[keyPath: keyPath] = value } })
    }

    private func targetBinding(_ field: Field) -> Binding<String> {
        Binding(
            get: { field.targetTag == .comment ? "COMMENT:\(field.targetSlot.map(String.init) ?? "")" : field.targetTag.rawValue },
            set: { value in
                update(field) { f in
                    if value.hasPrefix("COMMENT:") {
                        f.targetTag = .comment
                        f.targetSlot = Int(value.dropFirst("COMMENT:".count))
                    } else if let tag = TargetTag(rawValue: value) {
                        f.targetTag = tag
                        f.targetSlot = nil
                        if tag == .rating { f.kind = .rating }
                    }
                }
            })
    }

    /// Only one field validates the track at a time (spec section 6).
    private func advanceBinding(_ field: Field) -> Binding<Bool> {
        Binding(
            get: { field.isAdvanceTrigger },
            set: { on in
                let stamp = Timestamp.string(from: Date())
                var updated: [Field] = []
                for var f in app.store.config.fields where f.id == field.id || (on && f.isAdvanceTrigger) {
                    f.isAdvanceTrigger = f.id == field.id ? on : false
                    f.updatedAt = stamp
                    updated.append(f)
                }
                Task { await app.store.saveConfig(DirtyConfig(fields: updated)) }
            })
    }
}

/// One value: text written in the file, displayed label, color, aliases, archive, delete (spec B-43).
struct OptionEditorView: View {
    let optionID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var label = ""
    @State private var aliases = ""
    @State private var confirmingRename = false
    @State private var deleting = false

    var body: some View {
        let config = app.store.config
        let editor = ConfigEditor(store: app.store)
        if let option = config.option(id: optionID), let field = config.field(id: option.fieldID) {
            let used = editor.tracksUsing(optionID: option.id, fieldID: field.id).count
            Form {
                Section("Texte écrit dans le fichier") {
                    TextField("Valeur", text: $value)
                        .textInputAutocapitalization(.characters)
                }
                Section("Libellé affiché") {
                    TextField(value, text: $label)
                }
                Section {
                    TextField("Rap Fr, RAPFR…", text: $aliases)
                } header: {
                    Text("Variantes reconnues à l'import")
                } footer: {
                    Text("Séparées par des virgules.")
                }
                if field.targetTag == .grouping || option.color != nil {
                    Section("Couleur") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(Color.fieldColorNames, id: \.self) { name in
                                    ColorDot(color: Color.fieldColor(named: name) ?? .gray, label: name,
                                             state: option.color == name ? .confirmed : .empty, size: 28) {
                                        var o = option
                                        o.color = name
                                        Task { await editor.save(option: o) }
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Enregistrer") {
                        if value != option.value && used > 0 { confirmingRename = true } else { save(option) }
                    }
                    Toggle("Archivée (masquée, gardée pour l'historique)", isOn: Binding(
                        get: { option.archived },
                        set: { on in
                            var o = option
                            o.archived = on
                            Task { await editor.save(option: o) }
                        }))
                    Button("Supprimer…", role: .destructive) { deleting = true }
                } footer: {
                    Text("\(used) morceaux utilisent cette valeur.")
                }
            }
            .navigationTitle(option.displayLabel)
            .onAppear {
                value = option.value
                label = option.label ?? ""
                aliases = option.aliases.joined(separator: ", ")
            }
            .confirmationDialog("Renommer en « \(value) » ?", isPresented: $confirmingRename, titleVisibility: .visible) {
                Button("Renommer") { save(option) }
            } message: {
                Text("\(used) morceaux deviendront « à appliquer ».")
            }
            .confirmationDialog("Supprimer « \(option.displayLabel) » ?", isPresented: $deleting, titleVisibility: .visible) {
                ForEach(config.selectableOptions(forField: field.id).filter { $0.id != option.id }) { replacement in
                    Button("Remplacer par \(replacement.displayLabel)") {
                        Task {
                            await editor.delete(option: option, replacement: replacement)
                            dismiss()
                        }
                    }
                }
                Button("Vider sur \(used) morceaux", role: .destructive) {
                    Task {
                        await editor.delete(option: option, replacement: nil)
                        dismiss()
                    }
                }
            } message: {
                Text("\(used) morceaux utilisent cette valeur.")
            }
        } else {
            ContentUnavailableView("Valeur supprimée", systemImage: "trash")
        }
    }

    private func save(_ option: FieldOption) {
        let editor = ConfigEditor(store: app.store)
        let aliasList = aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task {
            var o = option
            o.aliases = aliasList
            await editor.rename(option: o, to: value, label: label)
        }
    }
}
