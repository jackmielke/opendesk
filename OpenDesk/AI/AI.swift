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

    private struct ClaudeRequest: Encodable {
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
