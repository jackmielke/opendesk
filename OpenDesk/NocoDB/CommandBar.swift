import SwiftUI

/// "Tell it what happened" bar: plain language (typed or dictated) becomes a reviewed set of row edits.
struct CommandBar: View {
    @Environment(AppConfig.self) private var config
    let model: TableModel
    @State private var text = ""
    @State private var thinking = false
    @State private var plan: EditPlan?
    @State private var error: String?
    @State private var voice = VoiceInput()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let error = error ?? voice.error {
                Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Image(systemName: thinking ? "ellipsis" : "sparkles")
                    .foregroundStyle(Brand.ai)
                    .symbolEffect(.variableColor.iterative, isActive: thinking)
                TextField(voice.isListening ? "Listening…" : placeholder,
                          text: voice.isListening ? .constant(voice.transcript) : $text, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit { Task { await run() } }
                if !text.isEmpty && !voice.isListening {
                    Button { Task { await run() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .tint(Brand.ai).disabled(thinking)
                } else {
                    HoldToTalkButton(voice: voice) { spoken in
                        text = spoken
                        Task { await run() }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Brand.ai.opacity(focused ? 0.7 : 0.25)))
        }
        .padding(.horizontal).padding(.bottom, 6)
        .sheet(item: Binding(get: { plan.map(PlanBox.init) }, set: { plan = $0?.plan })) { box in
            PlanReview(model: model, plan: box.plan) { text = "" }
        }
    }

    private var placeholder: String {
        switch model.table.title.lowercased() {
        case "events": return "“Summit Bank tasting went great, book it, Dana captains”"
        case "staff": return "“Bea is out this week”"
        case "clients": return "“Log that Maya prefers text”"
        default: return "Tell OpenDesk what changed…"
        }
    }

    private func run() async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        thinking = true
        error = nil
        defer { thinking = false }
        do {
            let ctx = TableContext.forEditing(model: model, instruction: q, budget: AI.contextBudget(config))
            let p = try await AI.plan(q, context: ctx, config: config)
            focused = false
            if p.edits.isEmpty { error = p.summary.isEmpty ? "No matching rows." : p.summary } else { plan = p }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PlanBox: Identifiable {
    let plan: EditPlan
    var id: String { plan.summary + "\(plan.edits.count)" }
}

struct PlanReview: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    let model: TableModel
    let plan: EditPlan
    let onApplied: () -> Void
    @State private var applying = false

    var body: some View {
        NavigationStack {
            List {
                Section { Text(plan.summary).font(.subheadline) }
                ForEach(Array(plan.edits.enumerated()), id: \.offset) { _, e in
                    let row = model.records.first { $0.recordId == e.rowId }
                    let col = model.columns.first { $0.title.lowercased() == e.field.lowercased() }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.flatMap { r in model.primary.flatMap { r[$0.title]?.display } } ?? "Row \(e.rowId)")
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            Text(col?.title ?? e.field).font(.caption).foregroundStyle(.secondary)
                            Text(row.flatMap { r in col.map { FieldText.format($0, r[$0.title]) } }.flatMap { $0.isEmpty ? nil : $0 } ?? "empty")
                                .font(.caption).strikethrough().foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.caption2)
                            if let col, col.isSelect { Chip(text: e.value, color: vivid(col.color(for: e.value))) }
                            else { Text(e.value).font(.caption.weight(.semibold)) }
                        }
                        if row == nil || col == nil || !(col?.isEditable ?? false) {
                            Label("Will be skipped: unknown row or read-only column", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Review changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { Task { await apply() } }.disabled(applying)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func apply() async {
        applying = true
        for e in plan.edits {
            guard let col = model.columns.first(where: { $0.title.lowercased() == e.field.lowercased() }), col.isEditable,
                  model.records.contains(where: { $0.recordId == e.rowId }) else { continue }
            let value: JSONValue
            switch col.uidt {
            case "Number", "Currency", "Decimal", "Percent", "Rating":
                value = Double(e.value.filter { $0.isNumber || $0 == "." }).map(JSONValue.number) ?? .null
            case "Checkbox":
                value = .bool(["true", "yes", "1", "checked", "available"].contains(e.value.lowercased()))
            default:
                value = .string(e.value)
            }
            await model.set(e.rowId, col.title, value, client: config.noco)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onApplied()
        dismiss()
    }
}
