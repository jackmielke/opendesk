import Foundation
import Observation
import Security
import SwiftUI

extension Brand {
    static let airtable = Color(red: 0.99, green: 0.71, blue: 0.0)
}

/// Airtable, direct: one personal access token, then every base and table the token can see,
/// in the same list / board / insights / editor UI as NocoDB.
@Observable
final class AirtableStore {
    static let shared = AirtableStore()

    var token: String { didSet { SecretStore.set(token, for: "airtable") } }
    var bases: [ATBase] = []
    var tables: [String: [ATTable]] = [:]
    var error: String?

    init() { token = SecretStore.get("airtable") ?? "" }

    var isConnected: Bool { !token.isEmpty }
    private var headers: [String: String] { ["Authorization": "Bearer \(token)"] }
    private let api = "https://api.airtable.com/v0"

    func load() async throws {
        guard isConnected else { throw APIError.notConfigured("Airtable") }
        let j = try await HTTP.json(JSONValue.self, api + "/meta/bases", headers: headers)
        let list = j["bases"]?.array.map { ATBase(id: $0["id"]?.string ?? "", name: $0["name"]?.string ?? "") } ?? []
        var t: [String: [ATTable]] = [:]
        for b in list {
            let s = try await HTTP.json(JSONValue.self, api + "/meta/bases/\(b.id)/tables", headers: headers)
            t[b.id] = s["tables"]?.array.map { ATTable(baseId: b.id, json: $0) } ?? []
        }
        bases = list
        tables = t
        error = nil
    }

    func records(_ t: ATTable) async throws -> [JSONValue] {
        var out: [JSONValue] = []
        var offset: String?
        repeat {
            var url = api + "/\(t.baseId)/\(t.id)?pageSize=100"
            if let offset { url += "&offset=\(offset.queryEncoded)" }
            let j = try await HTTP.json(JSONValue.self, url, headers: headers)
            out += j["records"]?.array ?? []
            offset = j["offset"]?.string
        } while offset != nil && out.count < 2000
        return out
    }

    func patch(_ t: ATTable, record: String, fields: [String: JSONValue]) async throws {
        _ = try await HTTP.data(api + "/\(t.baseId)/\(t.id)", method: "PATCH", headers: headers,
                                body: JSONValue.object(["records": .array([.object(["id": .string(record), "fields": .object(fields)])]), "typecast": .bool(true)]))
    }

    func create(_ t: ATTable, fields: [String: JSONValue]) async throws {
        _ = try await HTTP.data(api + "/\(t.baseId)/\(t.id)", method: "POST", headers: headers,
                                body: JSONValue.object(["records": .array([.object(["fields": .object(fields)])]), "typecast": .bool(true)]))
    }

    func delete(_ t: ATTable, record: String) async throws {
        _ = try await HTTP.data(api + "/\(t.baseId)/\(t.id)?records[]=\(record)", method: "DELETE", headers: headers)
    }
}

struct ATBase: Identifiable, Hashable { let id: String; let name: String }

struct ATTable: Identifiable, Hashable {
    let baseId: String
    let id: String
    let name: String
    let primaryFieldId: String
    let fields: [JSONValue]

    init(baseId: String, json: JSONValue) {
        self.baseId = baseId
        id = json["id"]?.string ?? ""
        name = json["name"]?.string ?? ""
        primaryFieldId = json["primaryFieldId"]?.string ?? ""
        fields = json["fields"]?.array ?? []
    }

    /// Airtable field types → the field kinds the shared Tables UI knows.
    var columns: [NocoColumn] {
        fields.map { f in
            let type = f["type"]?.string ?? ""
            let uidt: String = switch type {
            case "multilineText", "richText": "LongText"
            case "email": "Email"
            case "url": "URL"
            case "phoneNumber": "PhoneNumber"
            case "number", "count", "autoNumber": "Number"
            case "currency": "Currency"
            case "percent": "Percent"
            case "checkbox": "Checkbox"
            case "singleSelect": "SingleSelect"
            case "multipleSelects": "MultiSelect"
            case "date": "Date"
            case "rating": "Rating"
            case "createdTime": "CreatedTime"
            case "lastModifiedTime": "LastModifiedTime"
            case "formula", "rollup", "lookup", "multipleLookupValues", "multipleRecordLinks", "button", "createdBy", "lastModifiedBy", "multipleAttachments", "multipleCollaborators": "Formula"
            default: "SingleLineText"
            }
            let choices = f["options"]?["choices"]?.array ?? []
            return NocoColumn(json: .object([
                "id": f["id"] ?? .null, "title": f["name"] ?? .null, "uidt": .string(uidt),
                "pv": .bool(f["id"]?.string == primaryFieldId), "system": .bool(false),
                "colOptions": .object(["options": .array(choices.map { .object(["title": $0["name"] ?? .null, "color": .string(ATColor.hex($0["color"]?.string))]) })]),
            ]))
        }
    }
}

enum ATColor {
    /// Airtable's named choice colors, approximated as hex.
    static func hex(_ name: String?) -> String {
        guard let name else { return "#cfdffe" }
        let base = name.replacingOccurrences(of: #"(Light|Dark)?\d?$"#, with: "", options: .regularExpression)
        return ["blue": "#cfdffe", "cyan": "#d0f1fd", "teal": "#c2f5e9", "green": "#d1f7c4", "yellow": "#ffeab6",
                "orange": "#fee2d5", "red": "#ffdce5", "pink": "#ffdaf6", "purple": "#ede2fe", "gray": "#eeeeee"][base] ?? "#cfdffe"
    }
}

final class AirtableTableSource: TableSource {
    let store: AirtableStore
    let table: ATTable
    private var ids: [Int: String] = [:]

    init(store: AirtableStore, table: ATTable) { self.store = store; self.table = table }

    var kind: String { "Airtable" }

    func columns() async throws -> [NocoColumn] { table.columns }

    func records() async throws -> [NocoRecord] {
        let rows = try await store.records(table)
        ids = [:]
        return rows.enumerated().map { i, r in
            var o: NocoRecord = [:]
            for (k, v) in r["fields"]?.object ?? [:] {
                // Multi-selects come back as arrays; the shared UI stores them comma-joined.
                if case .array(let a) = v, a.allSatisfy({ $0.string != nil }) { o[k] = .string(a.compactMap(\.string).joined(separator: ",")) }
                else { o[k] = v }
            }
            ids[i + 1] = r["id"]?.string
            o["Id"] = .number(Double(i + 1))
            return o
        }
    }

    private func convert(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (k, v) in fields {
            if table.columns.first(where: { $0.title == k })?.uidt == "MultiSelect", let s = v.string {
                out[k] = .array(s.split(separator: ",").map { .string(String($0)) })
            } else { out[k] = v }
        }
        return out
    }

    func update(id: Int, fields: [String: JSONValue]) async throws {
        guard let rec = ids[id] else { return }
        try await store.patch(table, record: rec, fields: convert(fields))
    }
    func create(fields: [String: JSONValue]) async throws { try await store.create(table, fields: convert(fields)) }
    func delete(id: Int) async throws {
        guard let rec = ids[id] else { return }
        try await store.delete(table, record: rec)
    }
}

/// Small Keychain wrapper for integration tokens.
enum SecretStore {
    private static func q(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.jackmielke.opendesk.\(key)"]
    }
    static func set(_ value: String, for key: String) {
        SecItemDelete(q(key) as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q(key)
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        var query = q(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

struct AirtableConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = AirtableStore.shared
    @State private var draft = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        BrandMark(kind: .airtable, size: 44)
                        Text("Connect Airtable").font(.title2.bold())
                        Text("Paste a personal access token once. Every base it can see shows up in Tables, with boards, charts, editing and voice updates.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if store.isConnected && !store.bases.isEmpty {
                    Section("Connected") {
                        ForEach(store.bases) { b in
                            LabeledContent(b.name, value: "\(store.tables[b.id]?.count ?? 0) tables")
                        }
                        Button("Disconnect", role: .destructive) { store.token = ""; store.bases = []; store.tables = [:] }
                    }
                } else {
                    Section {
                        SecureField("pat…", text: $draft).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { Task { await connect() } } label: {
                            HStack { Text("Connect"); Spacer(); if busy { ProgressView() } }
                        }
                        .disabled(draft.count < 20 || busy)
                    } footer: {
                        Text("airtable.com/create/tokens → Create token → scopes data.records:read, data.records:write, schema.bases:read → add your bases.")
                    }
                    if let e = store.error { Section { Text(e).foregroundStyle(.orange).font(.footnote) } }
                }
            }
            .navigationTitle("Airtable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if store.isConnected && store.bases.isEmpty { try? await store.load() } }
        }
    }

    private func connect() async {
        busy = true
        defer { busy = false }
        store.token = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try await store.load(); draft = "" } catch {
            store.error = "Airtable rejected that token. Check it has schema.bases:read and access to at least one base."
            store.token = ""
        }
    }
}
