import Foundation
import Observation
import Security

/// "Bring your Supabase": browse and edit an existing Supabase app's tables as a signed-in user of that app.
/// No service key ever touches the phone. Every read and write carries the user's own JWT, so row-level
/// security decides what each teammate sees.
@Observable
final class SupabaseApp {
    static let shared = SupabaseApp()

    var url: String { didSet { UserDefaults.standard.set(url, forKey: "sbAppURL") } }
    var key: String { didSet { UserDefaults.standard.set(key, forKey: "sbAppKey") } }
    var session: Session? { didSet { AppKeychain.save(session) } }
    var tables: [SBTable] = []
    var needsHelper = false

    // Admin mode: a Supabase access token (supabase.com/dashboard/account/tokens) + a chosen project.
    var accessToken: String { didSet { SecretStore.set(accessToken, for: "supabase-pat") } }
    var adminKey: String { didSet { SecretStore.set(adminKey, for: "supabase-admin-key") } }
    var projectName: String { didSet { UserDefaults.standard.set(projectName, forKey: "sbProjectName") } }
    var isAdmin: Bool { !adminKey.isEmpty }

    init() {
        // Defaults to the OpenDesk demo project so the flow can be tried with the demo accounts; swap in your own.
        url = UserDefaults.standard.string(forKey: "sbAppURL") ?? SupabaseConfig.url
        key = UserDefaults.standard.string(forKey: "sbAppKey") ?? SupabaseConfig.publishableKey
        session = AppKeychain.load()
        accessToken = SecretStore.get("supabase-pat") ?? ""
        adminKey = SecretStore.get("supabase-admin-key") ?? ""
        projectName = UserDefaults.standard.string(forKey: "sbProjectName") ?? ""
    }

    struct Project: Identifiable, Hashable { let id: String; let name: String; let region: String; let status: String }

    private var mgmt: [String: String] { ["Authorization": "Bearer \(accessToken)"] }

    func projects() async throws -> [Project] {
        try await HTTP.json(JSONValue.self, "https://api.supabase.com/v1/projects", headers: mgmt).array.map {
            Project(id: $0["id"]?.string ?? $0["ref"]?.string ?? "", name: $0["name"]?.string ?? "", region: $0["region"]?.string ?? "", status: $0["status"]?.string ?? "")
        }
    }

    /// Admin mode: fetch the project's secret key and point the data browser at it. Bypasses RLS by design.
    func use(_ p: Project) async throws {
        let keys = try await HTTP.json(JSONValue.self, "https://api.supabase.com/v1/projects/\(p.id)/api-keys?reveal=true", headers: mgmt).array
        let secret = keys.first { $0["type"]?.string == "secret" }?["api_key"]?.string
            ?? keys.first { $0["name"]?.string == "service_role" }?["api_key"]?.string
        guard let secret else { throw APIError.status(0, "Couldn't read this project's keys. Is the token from an owner or admin?") }
        url = "https://\(p.id).supabase.co"
        key = keys.first { $0["type"]?.string == "publishable" }?["api_key"]?.string ?? keys.first { $0["name"]?.string == "anon" }?["api_key"]?.string ?? ""
        adminKey = secret
        projectName = p.name
        session = nil
        try await loadSchema()
    }

    func disconnectAdmin() {
        accessToken = ""; adminKey = ""; projectName = ""; tables = []
    }

    var isConfigured: Bool { !url.isEmpty && !key.isEmpty }
    var projectRef: String { projectName.isEmpty ? (URL(string: url)?.host?.split(separator: ".").first.map(String.init) ?? "Supabase") : projectName }

    static let helperSQL = """
    -- Run once in your Supabase SQL editor. Lists only the tables the signed-in user can read.
    create or replace function public.opendesk_schema() returns jsonb
    language sql stable security invoker set search_path = public, pg_catalog as $$
      select coalesce(jsonb_agg(t order by t->>'table'), '[]'::jsonb) from (
        select jsonb_build_object(
          'table', c.relname,
          'columns', (select jsonb_agg(jsonb_build_object(
              'name', a.attname,
              'type', format_type(a.atttypid, a.atttypmod),
              'pk', exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary and a.attnum = any(i.indkey)),
              'options', (select jsonb_agg(e.enumlabel order by e.enumsortorder) from pg_enum e where e.enumtypid = a.atttypid)
            ) order by a.attnum)
            from pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped)
        ) as t
        from pg_class c join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind in ('r', 'v', 'm') and has_table_privilege(c.oid, 'SELECT')
      ) s;
    $$;
    grant execute on function public.opendesk_schema() to authenticated;
    """

    // MARK: Auth (the app's own users)

    func signIn(email: String, password: String) async throws {
        let j = try await HTTP.json(JSONValue.self, url.trimmedSlash + "/auth/v1/token?grant_type=password", method: "POST",
                                    headers: ["apikey": key], body: ["email": email, "password": password])
        guard let access = j["access_token"]?.string, let refresh = j["refresh_token"]?.string else {
            throw APIError.status(0, j["error_description"]?.string ?? j["msg"]?.string ?? "Sign-in failed")
        }
        session = Session(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(j["expires_in"]?.double ?? 3600),
                          userId: j["user"]?["id"]?.string ?? "", email: j["user"]?["email"]?.string ?? email)
    }

    func signOut() { session = nil; tables = []; LiveUpdates.shared.stop() }

    private func bearer() async throws -> String? {
        guard var s = session else { return nil }
        if s.expiresAt.timeIntervalSinceNow < 60 {
            let j = try await HTTP.json(JSONValue.self, url.trimmedSlash + "/auth/v1/token?grant_type=refresh_token", method: "POST",
                                        headers: ["apikey": key], body: ["refresh_token": s.refreshToken])
            s.accessToken = j["access_token"]?.string ?? s.accessToken
            s.refreshToken = j["refresh_token"]?.string ?? s.refreshToken
            s.expiresAt = Date().addingTimeInterval(j["expires_in"]?.double ?? 3600)
            session = s
        }
        return s.accessToken
    }

    func headers(_ extra: [String: String] = [:]) async throws -> [String: String] {
        if isAdmin {
            var h = ["apikey": adminKey]
            if adminKey.hasPrefix("eyJ") { h["Authorization"] = "Bearer \(adminKey)" }
            return h.merging(extra) { $1 }
        }
        var h = ["apikey": key]
        if let t = try await bearer() { h["Authorization"] = "Bearer \(t)" }
        return h.merging(extra) { $1 }
    }

    // MARK: Schema

    func loadSchema() async throws {
        if isAdmin && !accessToken.isEmpty {
            // Admins don't need the helper function: read the catalog through the Management API.
            let ref = URL(string: url)?.host?.split(separator: ".").first.map(String.init) ?? ""
            let sql = Self.helperSQL.components(separatedBy: "as $$")[1].components(separatedBy: "$$;")[0]
                .replacingOccurrences(of: " and has_table_privilege(c.oid, 'SELECT')", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            let j = try await HTTP.json(JSONValue.self, "https://api.supabase.com/v1/projects/\(ref)/database/query", method: "POST",
                                        headers: mgmt, body: ["query": "select (" + sql + ") as schema"])
            let schema = j[0]?["schema"] ?? .array([])
            tables = schema.array.map(SBTable.init).filter { !$0.columns.isEmpty }
            needsHelper = false
            Task { await LiveUpdates.shared.start() }
            return
        }
        do {
            let j = try await HTTP.json(JSONValue.self, url.trimmedSlash + "/rest/v1/rpc/opendesk_schema", method: "POST",
                                        headers: try await headers(), body: [String: String]())
            tables = j.array.map(SBTable.init).filter { !$0.columns.isEmpty && !$0.name.hasPrefix("team_") && $0.name != "teams" }
            needsHelper = false
            Task { await LiveUpdates.shared.start() }
        } catch APIError.status(let code, _) where code == 404 {
            needsHelper = true
            throw APIError.status(404, "This project needs the one-time OpenDesk helper. Copy the SQL below into the Supabase SQL editor.")
        }
    }
}

struct SBTable: Identifiable, Hashable {
    let name: String
    let columns: [SBColumn]
    var id: String { name }
    var title: String { name.replacingOccurrences(of: "_", with: " ").capitalized }
    var pk: String? { columns.first(where: \.pk)?.name ?? columns.first { $0.name == "id" }?.name }

    init(json: JSONValue) {
        name = json["table"]?.string ?? ""
        columns = json["columns"]?.array.map(SBColumn.init) ?? []
    }

    /// Translate Postgres types into the field kinds the Tables UI already knows how to show and edit.
    var nocoColumns: [NocoColumn] {
        let primary = columns.first { ["name", "title", "event", "event_name", "full_name", "client_name", "company", "label"].contains($0.name) }
            ?? columns.first { !$0.pk && $0.type.hasPrefix("text") }
        let palette = ["#cfdffe", "#ffeab6", "#ede2fe", "#d1f7c4", "#c2f5e9", "#ffdce5", "#fee2d5", "#d0f1fd"]
        return columns.map { c in
            let n = c.name.lowercased()
            let t = c.type
            var uidt = "SingleLineText"
            if c.pk { uidt = "ID" }
            else if !c.options.isEmpty { uidt = "SingleSelect" }
            else if ["created_at", "inserted_at"].contains(n) { uidt = "CreatedTime" }
            else if n == "updated_at" { uidt = "LastModifiedTime" }
            else if t == "boolean" { uidt = "Checkbox" }
            else if t == "date" { uidt = "Date" }
            else if t.hasPrefix("timestamp") { uidt = "DateTime" }
            else if ["integer", "bigint", "smallint", "numeric", "real", "double precision"].contains(where: { t.hasPrefix($0) }) {
                uidt = ["price", "amount", "total", "cost", "budget", "revenue", "value", "fee"].contains { n.contains($0) } ? "Currency" : "Number"
            }
            else if n.contains("email") { uidt = "Email" }
            else if n.contains("phone") { uidt = "PhoneNumber" }
            else if n.contains("url") || n.contains("website") { uidt = "URL" }
            else if t.hasPrefix("json") || ["notes", "description", "body", "details"].contains(where: { n.contains($0) }) { uidt = "LongText" }
            let hidden = c.pk || t == "uuid" && n.hasSuffix("_id") || t == "tsvector"
            return NocoColumn(json: .object([
                "id": .string(c.name), "title": .string(c.name), "uidt": .string(uidt),
                "pv": .bool(c.name == primary?.name), "system": .bool(hidden),
                "colOptions": .object(["options": .array(c.options.enumerated().map { .object(["title": .string($1), "color": .string(palette[$0 % palette.count])]) })]),
            ]))
        }
    }
}

struct SBColumn: Hashable {
    let name: String
    let type: String
    let pk: Bool
    let options: [String]
    init(json: JSONValue) {
        name = json["name"]?.string ?? ""
        type = json["type"]?.string ?? "text"
        pk = json["pk"]?.bool ?? false
        options = json["options"]?.array.compactMap(\.string) ?? []
    }
}

/// Serves a Supabase table to the shared Tables UI. Rows get a local integer `Id`; writes map it back to the real key.
final class SupabaseTableSource: TableSource {
    let app: SupabaseApp
    let table: SBTable
    private var keys: [Int: JSONValue] = [:]

    init(app: SupabaseApp, table: SBTable) { self.app = app; self.table = table }

    var kind: String { "Supabase" }

    private var endpoint: String { app.url.trimmedSlash + "/rest/v1/\(table.name)" }

    func columns() async throws -> [NocoColumn] { table.nocoColumns }

    func records() async throws -> [NocoRecord] {
        let order = table.pk.map { "&order=\($0).asc" } ?? ""
        let rows = try await HTTP.json(JSONValue.self, endpoint + "?select=*&limit=1000" + order, headers: try await app.headers()).array
        keys = [:]
        return rows.enumerated().map { i, r in
            var o = r.object
            if let pk = table.pk { keys[i + 1] = o[pk] ?? .null }
            o["Id"] = .number(Double(i + 1))
            return o
        }
    }

    private func filter(_ id: Int) throws -> String {
        guard let pk = table.pk, let v = keys[id]?.string else { throw APIError.status(0, "This table has no primary key, so it's read-only here") }
        return "?\(pk)=eq.\(v.queryEncoded)"
    }

    func update(id: Int, fields: [String: JSONValue]) async throws {
        _ = try await HTTP.data(endpoint + (try filter(id)), method: "PATCH", headers: try await app.headers(["Prefer": "return=minimal"]), body: fields)
    }

    func create(fields: [String: JSONValue]) async throws {
        _ = try await HTTP.data(endpoint, method: "POST", headers: try await app.headers(["Prefer": "return=minimal"]), body: fields)
    }

    func delete(id: Int) async throws {
        _ = try await HTTP.data(endpoint + (try filter(id)), method: "DELETE", headers: try await app.headers())
    }
}

enum AppKeychain {
    private static let service = "com.jackmielke.opendesk.supabase-app"
    static func save(_ s: Session?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
        guard let s, let d = try? JSONEncoder().encode(s) else { return }
        var add = q
        add[kSecValueData as String] = d
        SecItemAdd(add as CFDictionary, nil)
    }
    static func load() -> Session? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(Session.self, from: d)
    }
}
