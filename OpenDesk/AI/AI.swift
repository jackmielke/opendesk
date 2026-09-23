import Foundation
import FoundationModels

/// AI answers: on-device Apple Intelligence by default (data never leaves the phone),
/// Claude when an Anthropic key is configured (bigger context, better reasoning).
enum AI {
    enum Engine: String { case onDevice = "On-device", claude = "Claude" }

    static func engine(_ config: AppConfig) -> Engine { config.anthropicKey.isEmpty ? .onDevice : .claude }

    static var onDeviceStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Ready"
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings"
        case .unavailable(.deviceNotEligible): return "This device doesn't support Apple Intelligence"
        case .unavailable(.modelNotReady): return "Model still downloading"
        case .unavailable: return "Unavailable"
        }
    }

    /// Rough character budget for context, per engine. The on-device model has a 4K token window.
    static func contextBudget(_ config: AppConfig) -> Int { engine(config) == .claude ? 80_000 : 5_500 }

    static let system = """
    You are OpenDesk, an assistant inside a mobile app for self-hosted open-source business tools \
    (NocoDB tables, Grafana dashboards, GitLab projects). Answer from the provided data only. \
    Be brief and concrete: lead with the answer, use short bullet points, name specific rows, numbers, and dates. \
    If the data doesn't contain the answer, say so in one line.
    """

    static func ask(_ question: String, context: String, config: AppConfig) async throws -> String {
        let prompt = "DATA:\n\(context)\n\nQUESTION: \(question)"
        switch engine(config) {
        case .claude:
            return try await claude(prompt: prompt, key: config.anthropicKey)
        case .onDevice:
            guard case .available = SystemLanguageModel.default.availability else {
                throw APIError.notConfigured("Apple Intelligence (\(onDeviceStatus)) or an Anthropic key")
            }
            let session = LanguageModelSession(instructions: system)
            return try await session.respond(to: prompt).content
        }
    }

    struct ClaudeRequest: Encodable {
        struct Msg: Encodable { let role: String; let content: String }
        let model: String
        let max_tokens: Int
        let system: String
        let messages: [Msg]
    }

    private static func claude(prompt: String, key: String) async throws -> String {
        let body = ClaudeRequest(model: "claude-sonnet-5", max_tokens: 1200, system: system, messages: [.init(role: "user", content: prompt)])
        let j = try await HTTP.json(JSONValue.self, "https://api.anthropic.com/v1/messages", method: "POST",
                                    headers: ["x-api-key": key, "anthropic-version": "2023-06-01"], body: body)
        return j["content"]?.array.compactMap { $0["text"]?.string }.joined() ?? ""
    }
}

enum TableContext {
    /// Compact pipe-separated dump of a table, trimmed to the engine's budget.
    static func describe(model: TableModel, budget: Int = 5_500) -> String {
        let cols = model.visibleColumns.filter { $0.uidt != "Attachment" }
        var lines = ["TABLE \(model.table.title) (\(model.records.count) rows). Today is \(DateField.string(Date())).",
                     cols.map(\.title).joined(separator: " | ")]
        var used = lines.joined().count
        for r in model.records {
            let line = cols.map { c -> String in
                let v = r[c.title]?.display ?? ""
                return c.uidt == "LongText" ? String(v.prefix(60)) : v
            }.joined(separator: " | ")
            if used + line.count > budget { lines.append("…(truncated)"); break }
            lines.append(line)
            used += line.count
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Natural-language edits

@Generable
struct RowEdit: Equatable {
    @Guide(description: "The Id of the row to change, copied from the Id column")
    var rowId: Int
    @Guide(description: "The exact column name to change")
    var field: String
    @Guide(description: "The new value. For select columns use one of the allowed options exactly. Dates as YYYY-MM-DD. Numbers as digits only.")
    var value: String
}

@Generable
struct EditPlan: Equatable {
    @Guide(description: "Every field change needed to carry out the instruction")
    var edits: [RowEdit]
    @Guide(description: "One short sentence confirming what will change")
    var summary: String
}

extension AI {
    static let editSystem = """
    You turn a user's instruction into field edits on a database table. Only use row Ids and column names that appear in the data. \
    Match rows by name loosely (partial names are fine). Never invent rows. If nothing matches, return no edits and say why in the summary.
    """

    static func plan(_ instruction: String, context: String, config: AppConfig) async throws -> EditPlan {
        let prompt = "TABLE DATA:\n\(context)\n\nINSTRUCTION: \(instruction)"
        switch engine(config) {
        case .onDevice:
            guard case .available = SystemLanguageModel.default.availability else {
                throw APIError.notConfigured("Apple Intelligence (\(onDeviceStatus)) or an Anthropic key")
            }
            let session = LanguageModelSession(instructions: editSystem)
            return try await session.respond(to: prompt, generating: EditPlan.self).content
        case .claude:
            let schema = #"Reply with ONLY JSON: {"edits":[{"rowId":1,"field":"Stage","value":"Booked"}],"summary":"..."}"#
            let body = ClaudeRequest(model: "claude-sonnet-5", max_tokens: 800, system: editSystem + " " + schema,
                                     messages: [.init(role: "user", content: prompt)])
            let j = try await HTTP.json(JSONValue.self, "https://api.anthropic.com/v1/messages", method: "POST",
                                        headers: ["x-api-key": config.anthropicKey, "anthropic-version": "2023-06-01"], body: body)
            var text = j["content"]?.array.compactMap { $0["text"]?.string }.joined() ?? ""
            if let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}") { text = String(text[s...e]) }
            let parsed = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
            return EditPlan(
                edits: parsed["edits"]?.array.map { RowEdit(rowId: $0["rowId"]?.int ?? -1, field: $0["field"]?.string ?? "", value: $0["value"]?.string ?? "") } ?? [],
                summary: parsed["summary"]?.string ?? "")
        }
    }
}

extension TableContext {
    /// Like `describe`, but with row Ids and the allowed options for select columns, so edits can be addressed.
    static func forEditing(model: TableModel, instruction: String, budget: Int) -> String {
        let cols = model.visibleColumns.filter { !["Attachment", "LongText"].contains($0.uidt) }
        let rows = candidates(model: model, instruction: instruction)
        var lines = ["TABLE \(model.table.title). Today is \(DateField.string(Date()))."]
        for c in cols where !c.options.isEmpty {
            lines.append("Column \(c.title) allowed options: \(c.options.map(\.title).joined(separator: ", "))")
        }
        // Short vocabularies (captains, venues) keep the model from inventing new spellings like "Dana Patel".
        for c in cols where c.uidt == "SingleLineText" && !c.isPrimary {
            let values = Set(model.records.compactMap { $0[c.title]?.string }.filter { !$0.isEmpty })
            if (2...10).contains(values.count) { lines.append("Column \(c.title) existing values: \(values.sorted().joined(separator: ", "))") }
        }
        lines.append((["Id"] + cols.map(\.title)).joined(separator: " | "))
        var used = lines.joined().count
        for r in rows {
            let line = ([String(r.recordId)] + cols.map { r[$0.title]?.display ?? "" }).joined(separator: " | ")
            if used + line.count > budget { break }
            lines.append(line)
            used += line.count
        }
        return lines.joined(separator: "\n")
    }
}

extension TableContext {
    private static let stop: Set<String> = ["the", "and", "for", "with", "move", "make", "set", "mark", "went", "great", "into", "from", "this", "that", "them", "lead", "captain", "booked", "stage", "change", "update"]

    /// Lexical pre-filter: small on-device models address rows far more reliably when they only see the
    /// handful of rows the instruction plausibly names. Falls back to every row when nothing matches.
    static func candidates(model: TableModel, instruction: String, limit: Int = 6) -> [NocoRecord] {
        let words = instruction.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }
        guard !words.isEmpty else { return model.records }
        let scored = model.records.map { r -> (NocoRecord, Int) in
            let title = model.primary.flatMap { r[$0.title]?.display.lowercased() } ?? ""
            let all = r.values.map { $0.display.lowercased() }.joined(separator: " ")
            let score = words.reduce(0) { $0 + (title.contains($1) ? 3 : 0) + (all.contains($1) ? 1 : 0) }
            return (r, score)
        }
        let hits = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        guard let best = hits.first?.1 else { return model.records }
        return hits.filter { $0.1 >= max(1, best / 2) }.prefix(limit).map(\.0)
    }
}
