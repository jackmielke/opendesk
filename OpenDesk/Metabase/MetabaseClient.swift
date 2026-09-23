import Foundation

struct MBDashRef: Identifiable, Hashable {
    let id: Int
    let name: String
    let collection: String?
    let description: String?
}

struct MBTab: Identifiable, Hashable {
    let id: Int
    let name: String
}

struct MBDashcard: Identifiable, Hashable {
    let id: Int
    let cardId: Int?
    let display: String
    let name: String
    let tabId: Int?
    let row: Int
    let col: Int
    let heading: String?

    var isHeading: Bool { cardId == nil }
}

struct MBDashboard {
    let id: Int
    let name: String
    let tabs: [MBTab]
    let cards: [MBDashcard]
}

struct MBColumn: Hashable {
    let name: String
    let baseType: String
    var isNumeric: Bool { ["Integer", "Float", "Decimal", "BigInteger", "Number"].contains { baseType.contains($0) } }
    var isTemporal: Bool { baseType.contains("Date") || baseType.contains("Time") }
}

struct MBResult {
    let cols: [MBColumn]
    let rows: [[JSONValue]]

    var dimension: Int? { cols.firstIndex { !$0.isNumeric } ?? (cols.count > 1 ? 0 : nil) }
    var metrics: [Int] { cols.indices.filter { cols[$0].isNumeric && $0 != dimension } }
}

struct MetabaseClient {
    let baseURL: String
    let apiKey: String

    private var headers: [String: String] { ["x-api-key": apiKey] }
    private func get(_ path: String) async throws -> JSONValue {
        guard !apiKey.isEmpty else { throw APIError.notConfigured("Metabase") }
        return try await HTTP.json(JSONValue.self, baseURL + path, headers: headers)
    }

    func dashboards() async throws -> [MBDashRef] {
        try await get("/api/search?models=dashboard")["data"]?.array.map {
            MBDashRef(id: $0["id"]?.int ?? 0, name: $0["name"]?.string ?? "",
                      collection: $0["collection"]?["name"]?.string, description: $0["description"]?.string)
        } ?? []
    }

    func dashboard(_ id: Int) async throws -> MBDashboard {
        let d = try await get("/api/dashboard/\(id)")
        let tabs = (d["tabs"]?.array ?? []).map { MBTab(id: $0["id"]?.int ?? 0, name: $0["name"]?.string ?? "") }
        let cards = (d["dashcards"]?.array ?? []).map { c -> MBDashcard in
            let vs = c["visualization_settings"]
            return MBDashcard(
                id: c["id"]?.int ?? 0,
                cardId: c["card_id"]?.int,
                display: c["card"]?["display"]?.string ?? vs?["virtual_card"]?["display"]?.string ?? "text",
                name: vs?["card.title"]?.string ?? c["card"]?["name"]?.string ?? "",
                tabId: c["dashboard_tab_id"]?.int,
                row: c["row"]?.int ?? 0, col: c["col"]?.int ?? 0,
                heading: vs?["text"]?.string)
        }
        .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        return MBDashboard(id: id, name: d["name"]?.string ?? "", tabs: tabs, cards: cards)
    }

    func query(dashboard: Int, card: MBDashcard) async throws -> MBResult {
        guard let cardId = card.cardId else { return MBResult(cols: [], rows: []) }
        let j = try await HTTP.json(JSONValue.self, baseURL + "/api/dashboard/\(dashboard)/dashcard/\(card.id)/card/\(cardId)/query",
                                    method: "POST", headers: headers, body: ["parameters": [String]()])
        let data = j["data"] ?? .null
        return MBResult(
            cols: (data["cols"]?.array ?? []).map { MBColumn(name: $0["display_name"]?.string ?? "", baseType: $0["base_type"]?.string ?? "") },
            rows: (data["rows"]?.array ?? []).map(\.array))
    }
}
