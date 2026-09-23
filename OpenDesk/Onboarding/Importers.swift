import Foundation

/// Getting existing data into NocoDB from a phone: Airtable (through NocoDB's own importer) and CSV files.
extension NocoClient {
    private var auth: [String: String] { ["xc-token": token] }

    struct CreatedBase { let id: String; let workspace: String; let source: String }

    func createBase(title: String) async throws -> CreatedBase {
        let b = try await HTTP.json(JSONValue.self, baseURL + "/api/v2/meta/bases", method: "POST", headers: auth, body: ["title": title])
        let id = b["id"]?.string ?? ""
        let full = try await HTTP.json(JSONValue.self, baseURL + "/api/v2/meta/bases/\(id)", headers: auth)
        return CreatedBase(id: id, workspace: b["fk_workspace_id"]?.string ?? full["fk_workspace_id"]?.string ?? "nc",
                           source: full["sources"]?[0]?["id"]?.string ?? "")
    }

    /// Mirrors what NocoDB's web "Import from Airtable" dialog does: register a sync source, then trigger the import job.
    func startAirtableImport(into base: CreatedBase, link: String, airtableToken: String) async throws -> String {
        let share = link.range(of: #"(exp|shr)[A-Za-z0-9]{14}"#, options: .regularExpression).map { String(link[$0]) } ?? ""
        let app = link.range(of: #"app[A-Za-z0-9]{14}"#, options: .regularExpression).map { String(link[$0]) } ?? ""
        guard !share.isEmpty || !app.isEmpty else { throw APIError.badURL("That doesn't look like an Airtable base or share link") }
        let body: JSONValue = .object([
            "type": .string("Airtable"),
            "details": .object([
                "syncInterval": .string("15mins"), "syncDirection": .string("Airtable to NocoDB"), "syncRetryCount": .number(1),
                "apiKey": .string(airtableToken), "appId": .string(app), "shareId": .string(share), "syncSourceUrlOrId": .string(link),
                "options": .object(["syncViews": .bool(true), "syncData": .bool(true), "syncRollup": .bool(false), "syncLookup": .bool(true),
                                    "syncFormula": .bool(false), "syncAttachment": .bool(true), "syncUsers": .bool(false)]),
            ]),
        ])
        let root = baseURL + "/api/v2/internal/\(base.workspace)/\(base.id)"
        let sync = try await HTTP.json(JSONValue.self, root + "?operation=syncSourceCreate&sourceId=\(base.source)", method: "POST", headers: auth, body: body)
        guard let syncId = sync["id"]?.string else { throw APIError.status(0, "NocoDB didn't create the sync source") }
        let job = try await HTTP.json(JSONValue.self, root + "?operation=atImportTrigger&syncId=\(syncId)", method: "POST", headers: auth, body: [String: String]())
        return job["id"]?.string ?? ""
    }

    /// Job status for a base: "waiting", "active", "completed" or "failed".
    func jobStatus(baseId: String, jobId: String) async throws -> String {
        let jobs = try await HTTP.json(JSONValue.self, baseURL + "/api/v2/jobs/\(baseId)", method: "POST", headers: auth, body: [String: String]())
        return jobs.array.first { $0["id"]?.string == jobId }?["status"]?.string ?? "waiting"
    }

    func deleteBase(_ id: String) async throws {
        _ = try await HTTP.data(baseURL + "/api/v2/meta/bases/\(id)", method: "DELETE", headers: auth)
    }

    /// Creates a table from parsed CSV with inferred column types, then inserts the rows in batches.
    func importCSV(_ csv: CSV, table: String, baseId: String, progress: @escaping (Double) -> Void) async throws -> String {
        let cols: [JSONValue] = csv.columns.enumerated().map { i, c in
            var o: [String: JSONValue] = ["column_name": .string(c.key), "title": .string(c.title), "uidt": .string(c.type)]
            if i == csv.primaryIndex { o["pv"] = .bool(true) }
            if !c.options.isEmpty {
                let palette = ["#cfdffe", "#d0f1fd", "#c2f5e9", "#ffdaf6", "#ffdce5", "#fee2d5", "#ffeab6", "#d1f7c4", "#ede2fe"]
                o["colOptions"] = .object(["options": .array(c.options.enumerated().map { .object(["title": .string($1), "color": .string(palette[$0 % palette.count])]) })])
            }
            return .object(o)
        }
        let t = try await HTTP.json(JSONValue.self, baseURL + "/api/v2/meta/bases/\(baseId)/tables", method: "POST", headers: auth,
                                    body: JSONValue.object(["table_name": .string(CSV.key(table)), "title": .string(table), "columns": .array(cols)]))
        guard let tid = t["id"]?.string else { throw APIError.status(0, "NocoDB didn't create the table") }
        let rows = csv.records()
        for start in stride(from: 0, to: rows.count, by: 100) {
            let chunk = Array(rows[start..<min(start + 100, rows.count)])
            _ = try await HTTP.data(baseURL + "/api/v2/tables/\(tid)/records", method: "POST", headers: auth, body: chunk)
            progress(Double(min(start + 100, rows.count)) / Double(max(rows.count, 1)))
        }
        return tid
    }
}

/// Minimal RFC 4180 CSV parser plus column type inference.
struct CSV {
    struct Column { let title: String; let key: String; let type: String; let options: [String] }

    let header: [String]
    let rows: [[String]]
    let columns: [Column]
    let primaryIndex: Int

    init(text: String) throws {
        var all = CSV.parse(text).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !all.isEmpty else { throw APIError.badURL("The file is empty") }
        let head = all.removeFirst().enumerated().map { $1.trimmingCharacters(in: .whitespaces).isEmpty ? "Column \($0 + 1)" : $1.trimmingCharacters(in: .whitespaces) }
        header = head
        rows = all.map { r in (0..<head.count).map { $0 < r.count ? r[$0] : "" } }
        var cols: [Column] = []
        for (i, h) in head.enumerated() {
            let values = all.compactMap { i < $0.count ? $0[i].trimmingCharacters(in: .whitespaces) : nil }.filter { !$0.isEmpty }
            cols.append(Column(title: h, key: CSV.key(h), type: CSV.infer(h, values), options: CSV.options(h, values)))
        }
        columns = cols
        primaryIndex = cols.firstIndex { $0.type == "SingleLineText" } ?? 0
    }

    func records() -> [[String: JSONValue]] {
        rows.map { r in
            var o: [String: JSONValue] = [:]
            for (i, c) in columns.enumerated() {
                let v = r[i].trimmingCharacters(in: .whitespaces)
                if v.isEmpty { continue }
                switch c.type {
                case "Number", "Decimal", "Currency", "Percent":
                    if let d = Double(v.filter { $0.isNumber || $0 == "." || $0 == "-" }) { o[c.title] = .number(d) }
                case "Checkbox": o[c.title] = .bool(["true", "yes", "y", "1", "x", "✓"].contains(v.lowercased()))
                case "Date": o[c.title] = .string(CSV.isoDate(v) ?? v)
                default: o[c.title] = .string(v)
                }
            }
            return o
        }
    }

    static func key(_ s: String) -> String {
        let k = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(String(k).prefix(50))
    }

    private static func infer(_ name: String, _ values: [String]) -> String {
        guard !values.isEmpty else { return "SingleLineText" }
        let n = name.lowercased()
        func all(_ p: (String) -> Bool) -> Bool { values.allSatisfy(p) }
        if all({ $0.contains("@") && $0.contains(".") && !$0.contains(" ") }) { return "Email" }
        if all({ ["true", "false", "yes", "no", "y", "n", "0", "1", "x", "✓"].contains($0.lowercased()) }) && Set(values.map { $0.lowercased() }).count <= 2 { return "Checkbox" }
        if all({ $0.hasPrefix("$") || $0.hasPrefix("€") || $0.hasPrefix("£") }) || (["price", "budget", "amount", "revenue", "cost", "value", "total"].contains { n.contains($0) } && all({ Double($0.filter { $0.isNumber || $0 == "." || $0 == "-" }) != nil })) { return "Currency" }
        if all({ Double($0.replacingOccurrences(of: ",", with: "")) != nil }) { return values.contains { $0.contains(".") } ? "Decimal" : "Number" }
        if all({ isoDate($0) != nil }) { return "Date" }
        if all({ $0.hasPrefix("http://") || $0.hasPrefix("https://") }) { return "URL" }
        if n.contains("phone") || all({ $0.filter(\.isNumber).count >= 7 && $0.allSatisfy { "0123456789+-() .".contains($0) } }) { return "PhoneNumber" }
        if values.contains(where: { $0.count > 120 }) { return "LongText" }
        let distinct = Set(values)
        let avgLen = values.map(\.count).reduce(0, +) / values.count
        let hinted = ["stage", "status", "type", "category", "priority", "tier", "segment", "source", "owner", "region"].contains { n.contains($0) }
        if distinct.count <= 12 && avgLen <= 24 && values.count >= 4 && (hinted ? distinct.count < values.count : distinct.count * 2 <= values.count) { return "SingleSelect" }
        return "SingleLineText"
    }

    private static func options(_ name: String, _ values: [String]) -> [String] {
        infer(name, values) == "SingleSelect" ? Array(Set(values)).sorted() : []
    }

    static func isoDate(_ s: String) -> String? {
        let formats = ["yyyy-MM-dd", "MM/dd/yyyy", "M/d/yyyy", "M/d/yy", "dd.MM.yyyy", "MMM d, yyyy", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) {
                f.dateFormat = "yyyy-MM-dd"
                return f.string(from: d)
            }
        }
        return nil
    }

    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", inQuotes = false
        let delimiter: Character = text.prefix(2000).filter { $0 == ";" }.count > text.prefix(2000).filter { $0 == "," }.count ? ";" : ","
        var it = Array(text.replacingOccurrences(of: "\r\n", with: "\n")).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n } } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" { inQuotes = true }
            else if c == delimiter { row.append(field); field = "" }
            else if c == "\n" || c == "\r" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
