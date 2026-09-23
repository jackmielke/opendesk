import Foundation
import Observation

struct NocoBase: Identifiable, Hashable {
    let id: String
    let title: String
    let colorHex: String?

    init(json: JSONValue) {
        id = json["id"]?.string ?? UUID().uuidString
        title = json["title"]?.string ?? "Untitled"
        if let meta = json["meta"]?.string, let d = meta.data(using: .utf8),
           let obj = try? JSONDecoder().decode(JSONValue.self, from: d) {
            colorHex = obj["iconColor"]?.string
        } else {
            colorHex = nil
        }
    }
}

struct NocoTable: Identifiable, Hashable {
    let id: String
    let title: String
    let baseId: String
    init(json: JSONValue) {
        id = json["id"]?.string ?? ""
        title = json["title"]?.string ?? ""
        baseId = json["base_id"]?.string ?? ""
    }
}

struct NocoOption: Hashable {
    let title: String
    let color: String?
}

struct NocoColumn: Identifiable, Hashable {
    let id: String
    let title: String
    let uidt: String
    let isPrimary: Bool
    let isSystem: Bool
    let options: [NocoOption]

    init(json: JSONValue) {
        id = json["id"]?.string ?? UUID().uuidString
        title = json["title"]?.string ?? ""
        uidt = json["uidt"]?.string ?? "SingleLineText"
        isPrimary = json["pv"]?.bool ?? false
        isSystem = json["system"]?.bool ?? false
        options = (json["colOptions"]?["options"]?.array ?? []).map {
            NocoOption(title: $0["title"]?.string ?? "", color: $0["color"]?.string)
        }
    }

    static let readOnlyTypes: Set<String> = ["ID", "CreatedTime", "LastModifiedTime", "CreatedBy", "LastModifiedBy", "Formula", "Rollup", "Lookup", "Links", "LinkToAnotherRecord", "Order", "Deleted", "Button", "QrCode", "Barcode", "AutoNumber"]

    var isVisible: Bool { !isSystem && uidt != "ID" }
    var isEditable: Bool { isVisible && !Self.readOnlyTypes.contains(uidt) }
    var isNumeric: Bool { ["Number", "Currency", "Decimal", "Percent", "Rating", "Duration"].contains(uidt) }
    var isSelect: Bool { uidt == "SingleSelect" }

    func color(for value: String) -> String? { options.first { $0.title == value }?.color }

    var icon: String {
        switch uidt {
        case "SingleLineText": return "textformat"
        case "LongText": return "text.alignleft"
        case "Number", "Decimal": return "number"
        case "Currency": return "dollarsign"
        case "Percent": return "percent"
        case "Checkbox": return "checkmark.square"
        case "SingleSelect": return "circle.circle"
        case "MultiSelect": return "list.bullet.circle"
        case "Date", "DateTime": return "calendar"
        case "Email": return "envelope"
        case "PhoneNumber": return "phone"
        case "URL": return "link"
        case "Rating": return "star"
        case "Attachment": return "paperclip"
        default: return "square.grid.2x2"
        }
    }
}

typealias NocoRecord = [String: JSONValue]

extension Dictionary where Key == String, Value == JSONValue {
    var recordId: Int { self["Id"]?.int ?? -1 }
}

struct NocoPage {
    let records: [NocoRecord]
    let total: Int
    let isLast: Bool
}

struct NocoClient {
    let baseURL: String
    let token: String

    private var headers: [String: String] { ["xc-token": token] }

    /// Reads go through a disk cache: fresh responses are saved, and when the server is unreachable
    /// the last good copy is served instead so the app stays usable offline (and on stage).
    private func get(_ path: String) async throws -> JSONValue {
        guard !token.isEmpty else { throw APIError.notConfigured("NocoDB") }
        do {
            let data = try await HTTP.data(baseURL + path, headers: headers)
            ResponseCache.save(data, for: path)
            await MainActor.run { Connectivity.shared.nocoOffline = false }
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch let error as URLError {
            guard let cached = ResponseCache.load(for: path) else { throw error }
            await MainActor.run { Connectivity.shared.nocoOffline = true }
            return try JSONDecoder().decode(JSONValue.self, from: cached)
        }
    }

    func bases() async throws -> [NocoBase] {
        try await get("/api/v2/meta/bases")["list"]?.array.map(NocoBase.init) ?? []
    }

    func tables(baseId: String) async throws -> [NocoTable] {
        try await get("/api/v2/meta/bases/\(baseId)/tables")["list"]?.array.map(NocoTable.init) ?? []
    }

    func columns(tableId: String) async throws -> [NocoColumn] {
        try await get("/api/v2/meta/tables/\(tableId)")["columns"]?.array.map(NocoColumn.init) ?? []
    }

    func records(tableId: String, offset: Int = 0, limit: Int = 200, sort: String? = nil) async throws -> NocoPage {
        var path = "/api/v2/tables/\(tableId)/records?offset=\(offset)&limit=\(limit)"
        if let sort { path += "&sort=\(sort.queryEncoded)" }
        let j = try await get(path)
        return NocoPage(
            records: j["list"]?.array.map(\.object) ?? [],
            total: j["pageInfo"]?["totalRows"]?.int ?? 0,
            isLast: j["pageInfo"]?["isLastPage"]?.bool ?? true
        )
    }

    /// Fetches every row (capped) — fine for demo-sized tables and for building AI context.
    func allRecords(tableId: String, cap: Int = 1000) async throws -> [NocoRecord] {
        var out: [NocoRecord] = []
        var offset = 0
        while out.count < cap {
            let page = try await records(tableId: tableId, offset: offset, limit: 200)
            out += page.records
            if page.isLast || page.records.isEmpty { break }
            offset += page.records.count
        }
        return out
    }

    func update(tableId: String, id: Int, fields: [String: JSONValue]) async throws {
        var body = fields
        body["Id"] = .number(Double(id))
        _ = try await HTTP.data(baseURL + "/api/v2/tables/\(tableId)/records", method: "PATCH", headers: headers, body: [body])
    }

    func create(tableId: String, fields: [String: JSONValue]) async throws {
        _ = try await HTTP.data(baseURL + "/api/v2/tables/\(tableId)/records", method: "POST", headers: headers, body: [fields])
    }

    func delete(tableId: String, id: Int) async throws {
        _ = try await HTTP.data(baseURL + "/api/v2/tables/\(tableId)/records", method: "DELETE", headers: headers, body: [["Id": id]])
    }
}

@Observable
final class Connectivity {
    static let shared = Connectivity()
    var nocoOffline = false
}

enum ResponseCache {
    private static var dir: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("noco", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func file(_ key: String) -> URL? {
        let safe = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? String(key.hashValue)
        return dir?.appendingPathComponent(String(safe.prefix(200)))
    }

    static func save(_ data: Data, for key: String) {
        guard let f = file(key) else { return }
        try? data.write(to: f, options: .atomic)
    }

    static func load(for key: String) -> Data? {
        file(key).flatMap { try? Data(contentsOf: $0) }
    }
}
