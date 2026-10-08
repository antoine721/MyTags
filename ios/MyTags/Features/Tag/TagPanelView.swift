import MyTagsKit
import SwiftUI

/// One row per visible field, in the settings order; positions never move (spec 9.2, U-03).
struct TagPanelView: View {
    let session: TagSessionModel
    let resolved: ResolvedTrack
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            ForEach(session.config.visibleFields) { field in
                FieldRow(session: session, field: field, resolved: resolved[field.id], compact: compact)
            }
        }
    }
}

private struct FieldRow: View {
    let session: TagSessionModel
    let field: Field
    let resolved: ResolvedField?
    let compact: Bool

    @State private var editingText = false
    @State private var textDraft = ""

    var body: some View {
        let isMissing = session.flashing.contains(field.id)
        HStack(alignment: .top, spacing: Theme.spacing) {
            Text(field.name.uppercased())
                .font(.fieldLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: Theme.labelWidth, alignment: .leading)
                .frame(minHeight: Theme.minHitSize)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.4) {
                    if field.kind == .single || field.kind == .multi {
                        Haptics.shared.select()
                        session.addingValueTo = field
                    } else if field.kind == .rating {
                        session.clearRating(field: field)
                    }
                }
                .accessibilityAddTraits(.isHeader)
                .accessibilityAction(named: "Ajouter une valeur") { session.addingValueTo = field }
            values
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .keyframeAnimator(initialValue: 0.0, trigger: session.flashGeneration) { content, opacity in
            content.background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(isMissing ? opacity : 0))
            )
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(0.18, duration: 0.075)
                LinearKeyframe(0, duration: 0.075)
                LinearKeyframe(0.18, duration: 0.075)
                LinearKeyframe(0, duration: 0.075)
            }
        }
        .alert(field.name, isPresented: $editingText) {
            TextField(field.name, text: $textDraft)
            Button("OK") { session.setText(textDraft, field: field) }
            Button("Annuler", role: .cancel) {}
        }
    }

    @ViewBuilder private var values: some View {
        switch field.kind {
        case .rating:
            StarRating(
                rating: resolved?.state == .confirmed ? resolved?.value.rating : nil,
                size: compact ? 34 : Theme.starSize,
                onRate: { session.rate($0, field: field) },
                onClear: { session.clearRating(field: field) })
        case .text:
            Pill(title: resolved?.value.text ?? "—", state: state(for: nil), compact: compact) {
                textDraft = resolved?.value.text ?? ""
                editingText = true
            }
        case .single, .multi:
            let options = visibleOptions
            if !options.isEmpty, options.allSatisfy({ Color.fieldColor(named: $0.color) != nil }) {
                FlowLayout(spacing: 2) {
                    ForEach(options) { option in
                        ColorDot(
                            color: Color.fieldColor(named: option.color) ?? .gray, label: option.displayLabel,
                            state: state(for: option.id), size: compact ? 30 : Theme.colorDotSize
                        ) {
                            session.tap(option: option, in: field)
                        }
                    }
                }
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(options) { option in
                        Pill(title: option.displayLabel, state: state(for: option.id), compact: compact) {
                            session.tap(option: option, in: field)
                        }
                    }
                }
            }
        }
    }

    /// Selectable options plus archived ones still in use on this track.
    private var visibleOptions: [FieldOption] {
        let selectable = session.config.selectableOptions(forField: field.id)
        let selected = Set(resolved?.value.optionIDs ?? [])
        let archived = session.config.options(forField: field.id).filter { $0.archived && selected.contains($0.id) }
        return selectable + archived
    }

    private func state(for optionID: String?) -> ValueState {
        guard let resolved else { return .empty }
        if let optionID, !resolved.value.optionIDs.contains(optionID) { return .empty }
        if optionID == nil, resolved.value.text == nil { return .empty }
        switch resolved.state {
        case .confirmed: return .confirmed
        case .suggested: return .suggested
        case .empty: return .empty
        }
    }
}

/// Quick pass: one field, big buttons, one tap = next track (spec 9.3).
struct QuickPassView: View {
    let session: TagSessionModel
    let field: Field
    let resolved: ResolvedTrack?

    var body: some View {
        let options = session.config.selectableOptions(forField: field.id)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: options.count > 6 ? 3 : 2)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PASSE RAPIDE · \(field.name.uppercased())")
                    .font(.fieldLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Terminer") { session.stopQuickPass() }
                    .font(.subheadline.weight(.semibold))
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(options) { option in
                    Button {
                        session.quickPick(option: option, field: field)
                    } label: {
                        HStack(spacing: 8) {
                            if let color = Color.fieldColor(named: option.color) {
                                Circle().fill(color).frame(width: 22, height: 22)
                            }
                            Text(option.displayLabel)
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.quickPassButtonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isCurrent(option) ? Color.primary.opacity(0.18) : Color(uiColor: .secondarySystemFill))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressScaleStyle())
                    .foregroundStyle(.primary)
                }
            }
        }
    }

    private func isCurrent(_ option: FieldOption) -> Bool {
        resolved?[field.id]?.value.optionIDs.contains(option.id) == true
    }
}

/// "Annuler" for 3 seconds after a validation (spec B-14).
struct UndoBanner: View {
    let undo: TagSessionModel.Undo
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(undo.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Annuler", action: action)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Annuler", action)
    }
}
