import Foundation
import Observation
import Security

/// Teams backend: Supabase Auth (email code or magic link) + Postgres with row-level security.
/// Plain REST, no SDK. The publishable key is safe to ship; RLS decides what each user can read.
enum SupabaseConfig {
    static let url = "https://tztzifsdirqnctayihjs.supabase.co"
    static let publishableKey = "sb_publishable_7ixojXPVbmSTrpm0PvIqzg_BUlsF1MN"
    static let redirect = "opendesk://auth-callback"
}

struct Session: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var userId: String
    var email: String
}

struct Team: Identifiable, Hashable {
    let id: String
    let name: String
    let inviteCode: String
    let role: String
    var isAdmin: Bool { role == "admin" }
}

struct Member: Identifiable, Hashable {
    let userId: String
    let email: String
    let role: String
    let joinedAt: String?
    var id: String { userId }
}

@Observable
final class TeamStore {
    static let shared = TeamStore()

    var session: Session? { didSet { Keychain.save(session) } }
    var teams: [Team] = []
    var current: Team? { teams.first { $0.id == currentId } ?? teams.first }
    var currentId: String? { didSet { UserDefaults.standard.set(currentId, forKey: "teamId") } }
    var pendingInvite: String?
    var lastSync: Date?

    init() {
        session = Keychain.load()
        currentId = UserDefaults.standard.string(forKey: "teamId")
    }

    var isSignedIn: Bool { session != nil }

    // MARK: Auth

    func sendCode(to email: String) async throws {
        _ = try await HTTP.data(SupabaseConfig.url + "/auth/v1/otp?redirect_to=\(SupabaseConfig.redirect.queryEncoded)", method: "POST",
                                headers: base, body: ["email": JSONValue.string(email), "create_user": .bool(true)])
    }

    func verify(email: String, code: String) async throws {
        let j = try await HTTP.json(JSONValue.self, SupabaseConfig.url + "/auth/v1/verify", method: "POST", headers: base,
                                    body: ["type": "email", "email": email, "token": code])
        try adopt(j)
        await refreshTeams()
    }

    func signIn(email: String, password: String) async throws {
        let j = try await HTTP.json(JSONValue.self, SupabaseConfig.url + "/auth/v1/token?grant_type=password", method: "POST", headers: base,
                                    body: ["email": email, "password": password])
        try adopt(j)
        await refreshTeams()
    }

    /// Magic-link sign-in: the email link lands on opendesk://auth-callback#access_token=…
    func handleCallback(_ url: URL) async {
        guard let frag = url.fragment ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.query else { return }
        var p: [String: String] = [:]
        for pair in frag.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if kv.count == 2 { p[kv[0]] = kv[1] }
        }
        guard let access = p["access_token"], let refresh = p["refresh_token"] else { return }
        let expires = Double(p["expires_in"] ?? "3600") ?? 3600
        if let user = try? await HTTP.json(JSONValue.self, SupabaseConfig.url + "/auth/v1/user", headers: base.merging(["Authorization": "Bearer \(access)"]) { $1 }) {
            session = Session(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expires),
                              userId: user["id"]?.string ?? "", email: user["email"]?.string ?? "")
            await refreshTeams()
        }
    }

    func signOut() {
        session = nil
        teams = []
    }

    private func adopt(_ j: JSONValue) throws {
        guard let access = j["access_token"]?.string, let refresh = j["refresh_token"]?.string else {
            throw APIError.status(0, j["msg"]?.string ?? j["error_description"]?.string ?? "Sign-in failed")
        }
        session = Session(accessToken: access, refreshToken: refresh,
                          expiresAt: Date().addingTimeInterval(j["expires_in"]?.double ?? 3600),
                          userId: j["user"]?["id"]?.string ?? "", email: j["user"]?["email"]?.string ?? "")
    }

    private func token() async throws -> String {
        guard let s = session else { throw APIError.notConfigured("Your account") }
        if s.expiresAt.timeIntervalSinceNow > 60 { return s.accessToken }
        let j = try await HTTP.json(JSONValue.self, SupabaseConfig.url + "/auth/v1/token?grant_type=refresh_token", method: "POST",
                                    headers: base, body: ["refresh_token": s.refreshToken])
        try adopt(j)
        return session!.accessToken
    }

    private var base: [String: String] { ["apikey": SupabaseConfig.publishableKey] }

    private func rest(_ path: String, method: String = "GET", body: Encodable? = nil, prefer: String? = nil) async throws -> JSONValue {
        var h = base
        h["Authorization"] = "Bearer \(try await token())"
        if let prefer { h["Prefer"] = prefer }
        let d = try await HTTP.data(SupabaseConfig.url + path, method: method, headers: h, body: body)
        return d.isEmpty ? .null : ((try? JSONDecoder().decode(JSONValue.self, from: d)) ?? .null)
    }

    // MARK: Teams

    func refreshTeams() async {
        guard let uid = session?.userId,
              let rows = try? await rest("/rest/v1/team_members?select=role,teams(id,name,invite_code)&user_id=eq.\(uid)") else { return }
        teams = rows.array.compactMap { r in
            guard let t = r["teams"], let id = t["id"]?.string else { return nil }
            return Team(id: id, name: t["name"]?.string ?? "", inviteCode: t["invite_code"]?.string ?? "", role: r["role"]?.string ?? "member")
        }
        if currentId == nil || !teams.contains(where: { $0.id == currentId }) { currentId = teams.first?.id }
    }

    func createTeam(name: String) async throws {
        let t = try await rest("/rest/v1/rpc/create_team", method: "POST", body: ["team_name": name])
        currentId = t["id"]?.string
        await refreshTeams()
    }

    func join(code: String) async throws {
        let t = try await rest("/rest/v1/rpc/join_team", method: "POST", body: ["code": code])
        currentId = t["id"]?.string
        pendingInvite = nil
        await refreshTeams()
    }

    func members(of team: Team) async throws -> [Member] {
        try await rest("/rest/v1/team_members?select=user_id,email,role,joined_at&team_id=eq.\(team.id)&order=joined_at").array.map {
            Member(userId: $0["user_id"]?.string ?? "", email: $0["email"]?.string ?? "", role: $0["role"]?.string ?? "member", joinedAt: $0["joined_at"]?.string)
        }
    }

    func setRole(_ role: String, for m: Member, in team: Team) async throws {
        _ = try await rest("/rest/v1/team_members?team_id=eq.\(team.id)&user_id=eq.\(m.userId)", method: "PATCH", body: ["role": role])
    }

    func remove(_ m: Member, from team: Team) async throws {
        _ = try await rest("/rest/v1/team_members?team_id=eq.\(team.id)&user_id=eq.\(m.userId)", method: "DELETE")
        if m.userId == session?.userId { await refreshTeams() }
    }

    // MARK: Shared connections

    /// Admins publish their working setup; everyone on the team gets it on next launch.
    func publish(_ c: AppConfig, to team: Team) async throws {
        let body: [String: JSONValue] = [
            "team_id": .string(team.id), "updated_by": .string(session?.userId ?? ""),
            "noco_url": .string(c.nocoURL), "noco_token": .string(c.nocoToken),
            "grafana_url": .string(c.grafanaURL), "grafana_token": .string(c.grafanaToken),
            "metabase_url": .string(c.metabaseURL), "metabase_key": .string(c.metabaseKey),
            "gitlab_url": .string(c.gitlabURL), "gitlab_token": .string(c.gitlabToken),
            "pinned_projects": .array(c.pinnedProjects.map(JSONValue.string)),
            "updated_at": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        _ = try await rest("/rest/v1/team_connections?on_conflict=team_id", method: "POST", body: body, prefer: "resolution=merge-duplicates")
        lastSync = Date()
    }

    /// Pulls the team's connections into this device. Returns true when something was applied.
    @discardableResult
    func pull(into c: AppConfig) async -> Bool {
        guard let team = current,
              let row = try? await rest("/rest/v1/team_connections?team_id=eq.\(team.id)").array.first else { return false }
        func s(_ k: String) -> String? { row[k]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        guard s("noco_url") != nil || s("grafana_url") != nil || s("metabase_url") != nil else { return false }
        if let v = s("noco_url") { c.nocoURL = v }
        if let v = s("noco_token") { c.nocoToken = v }
        if let v = s("grafana_url") { c.grafanaURL = v }
        if let v = s("grafana_token") { c.grafanaToken = v }
        if let v = s("metabase_url") { c.metabaseURL = v }
        if let v = s("metabase_key") { c.metabaseKey = v }
        if let v = s("gitlab_url") { c.gitlabURL = v }
        if let v = s("gitlab_token") { c.gitlabToken = v }
        let pinned = row["pinned_projects"]?.array.compactMap(\.string) ?? []
        if !pinned.isEmpty { c.pinnedProjects = pinned }
        c.onboarded = true
        lastSync = Date()
        return true
    }
}

/// Session tokens live in the Keychain, not UserDefaults.
enum Keychain {
    private static let service = "com.jackmielke.opendesk.session"

    static func save(_ s: Session?) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
        guard let s, let d = try? JSONEncoder().encode(s) else { return }
        var add = q
        add[kSecValueData as String] = d
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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
