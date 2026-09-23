import SwiftUI

struct ChatTurn: Identifiable, Equatable {
    let id = UUID()
    let question: String
    var answer: String?
    var failed = false
}

/// Reusable "ask this data" chat. `context` is built lazily, once, when the first question is asked.
struct AskSheet: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    let title: String
    let accent: Color
    let suggestions: [String]
    let context: () async throws -> String

    @State private var turns: [ChatTurn] = []
    @State private var input = ""
    @State private var cached: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        engineBadge
                        if turns.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(suggestions, id: \.self) { s in
                                    Button { send(s) } label: {
                                        HStack {
                                            Text(s).multilineTextAlignment(.leading)
                                            Spacer()
                                            Image(systemName: "arrow.up.right").font(.caption)
                                        }
                                        .card(padding: 12)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        ForEach(turns) { t in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(t.question)
                                    .padding(10)
                                    .background(accent.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                if let a = t.answer {
                                    Text(markdown(a))
                                        .foregroundStyle(t.failed ? .orange : .primary)
                                        .textSelection(.enabled)
                                        .card(padding: 12)
                                } else {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                        Text("Thinking…").foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .id(t.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: turns) { if let last = turns.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("Ask anything…", text: $input, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit { send(input) }
                    Button { send(input) } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                        .tint(accent)
                }
                .padding(12)
                .background(.ultraThinMaterial)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private var engineBadge: some View {
        let e = AI.engine(config)
        return Label(e == .onDevice ? "On-device Apple Intelligence · data stays on this phone" : "Claude · \(e.rawValue)",
                     systemImage: e == .onDevice ? "lock.iphone" : "sparkles")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s.bulleted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input = ""
        let turn = ChatTurn(question: q)
        turns.append(turn)
        Task {
            do {
                if cached == nil { cached = try await context() }
                // Keep follow-ups grounded: prior Q&A is folded into the question.
                let history = turns.dropLast().suffix(2).compactMap { t in t.answer.map { "Q: \(t.question)\nA: \($0.prefix(400))" } }.joined(separator: "\n")
                let full = history.isEmpty ? q : "Earlier:\n\(history)\n\nNow: \(q)"
                let budget = AI.contextBudget(config)
                let answer = try await AI.ask(full, context: String((cached ?? "").prefix(budget)), config: config)
                update(turn.id) { $0.answer = answer }
            } catch {
                update(turn.id) { $0.answer = error.localizedDescription; $0.failed = true }
            }
        }
    }

    private func update(_ id: UUID, _ f: (inout ChatTurn) -> Void) {
        if let i = turns.firstIndex(where: { $0.id == id }) { f(&turns[i]) }
    }
}
