import Foundation
import SwiftUI

struct GLProject: Identifiable, Hashable {
    let id: Int
    let path: String
    let name: String
    let description: String?
    let stars: Int
    let forks: Int
    let openIssues: Int?
    let avatar: URL?
    let webURL: URL?
    let lastActivity: String?

    init(json: JSONValue) {
        id = json["id"]?.int ?? 0
        path = json["path_with_namespace"]?.string ?? ""
        name = json["name"]?.string ?? ""
        description = json["description"]?.string
        stars = json["star_count"]?.int ?? 0
        forks = json["forks_count"]?.int ?? 0
        openIssues = json["open_issues_count"]?.int
        avatar = json["avatar_url"]?.string.flatMap(URL.init(string:))
        webURL = json["web_url"]?.string.flatMap(URL.init(string:))
        lastActivity = json["last_activity_at"]?.string
    }
}

struct GLItem: Identifiable, Hashable {
    let id: Int
    let iid: Int
    let title: String
    let state: String
    let author: String
    let avatar: URL?
    let labels: [String]
    let createdAt: String?
    let updatedAt: String?
    let webURL: URL?
    let description: String?
    let draft: Bool
    let comments: Int
    let upvotes: Int
    let sourceBranch: String?
    let targetBranch: String?
    let pipelineStatus: String?
    let mergeStatus: String?

    init(json: JSONValue) {
        id = json["id"]?.int ?? 0
        iid = json["iid"]?.int ?? 0
        title = json["title"]?.string ?? ""
        state = json["state"]?.string ?? ""
        author = json["author"]?["name"]?.string ?? ""
        avatar = json["author"]?["avatar_url"]?.string.flatMap(URL.init(string:))
        labels = json["labels"]?.array.compactMap(\.string) ?? []
        createdAt = json["created_at"]?.string
        updatedAt = json["updated_at"]?.string
        webURL = json["web_url"]?.string.flatMap(URL.init(string:))
        description = json["description"]?.string
        draft = json["draft"]?.bool ?? json["work_in_progress"]?.bool ?? false
        comments = json["user_notes_count"]?.int ?? 0
        upvotes = json["upvotes"]?.int ?? 0
        sourceBranch = json["source_branch"]?.string
        targetBranch = json["target_branch"]?.string
        pipelineStatus = json["head_pipeline"]?["status"]?.string ?? json["pipeline"]?["status"]?.string
        mergeStatus = json["detailed_merge_status"]?.string
    }
}

struct GLPipeline: Identifiable, Hashable {
    let id: Int
    let status: String
    let ref: String
    let sha: String
    let source: String?
    let createdAt: String?
    let webURL: URL?

    init(json: JSONValue) {
        id = json["id"]?.int ?? 0
        status = json["status"]?.string ?? ""
        ref = json["ref"]?.string ?? ""
        sha = String((json["sha"]?.string ?? "").prefix(8))
        source = json["source"]?.string
        createdAt = json["created_at"]?.string
        webURL = json["web_url"]?.string.flatMap(URL.init(string:))
    }
}

struct GLJob: Identifiable, Hashable {
    let id: Int
    let name: String
    let stage: String
    let status: String
    let duration: Double?
    init(json: JSONValue) {
        id = json["id"]?.int ?? 0
        name = json["name"]?.string ?? ""
        stage = json["stage"]?.string ?? ""
        status = json["status"]?.string ?? ""
        duration = json["duration"]?.double
    }
}

struct GLDiff: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let added: Int
    let removed: Int
    let isNew: Bool
    let isDeleted: Bool
    let diff: String

    init(json: JSONValue) {
        path = json["new_path"]?.string ?? ""
        isNew = json["new_file"]?.bool ?? false
        isDeleted = json["deleted_file"]?.bool ?? false
        diff = json["diff"]?.string ?? ""
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
    }
}

struct GLNote: Identifiable, Hashable {
    let id: Int
    let author: String
    let body: String
    let createdAt: String?
    let system: Bool
    init(json: JSONValue) {
        id = json["id"]?.int ?? 0
        author = json["author"]?["name"]?.string ?? ""
        body = json["body"]?.string ?? ""
        createdAt = json["created_at"]?.string
        system = json["system"]?.bool ?? false
    }
}

enum GLStatus {
    static func color(_ s: String) -> Color {
        switch s {
        case "success", "merged", "passed": return .green
        case "failed": return .red
        case "running", "pending", "preparing", "waiting_for_resource": return .blue
        case "canceled", "skipped", "closed": return .gray
        case "opened": return .green
        case "manual", "scheduled", "created": return .purple
        default: return .secondary
        }
    }
    static func icon(_ s: String) -> String {
        switch s {
        case "success": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "running": return "arrow.triangle.2.circlepath.circle.fill"
        case "pending", "created", "waiting_for_resource", "preparing": return "clock.fill"
        case "canceled": return "slash.circle.fill"
        case "skipped": return "forward.circle.fill"
        case "manual": return "gearshape.circle.fill"
        default: return "circle.dashed"
        }
    }
}

struct GitLabClient {
    let baseURL: String
    let token: String

    var hasToken: Bool { !token.isEmpty }
    private var headers: [String: String] { token.isEmpty ? [:] : ["PRIVATE-TOKEN": token] }
    private func get(_ path: String) async throws -> JSONValue {
        try await HTTP.json(JSONValue.self, baseURL + "/api/v4" + path, headers: headers)
    }
    private func pid(_ p: String) -> String { p.urlEncoded }

    func project(_ path: String) async throws -> GLProject { GLProject(json: try await get("/projects/\(pid(path))")) }

    func myProjects() async throws -> [GLProject] {
        try await get("/projects?membership=true&order_by=last_activity_at&per_page=30").array.map(GLProject.init)
    }

    func searchProjects(_ q: String) async throws -> [GLProject] {
        try await get("/projects?search=\(q.queryEncoded)&order_by=star_count&per_page=20").array.map(GLProject.init)
    }

    func mergeRequests(_ id: Int, state: String = "opened") async throws -> [GLItem] {
        try await get("/projects/\(id)/merge_requests?state=\(state)&per_page=30&order_by=updated_at").array.map(GLItem.init)
    }

    func mergeRequest(_ id: Int, iid: Int) async throws -> GLItem {
        GLItem(json: try await get("/projects/\(id)/merge_requests/\(iid)"))
    }

    func diffs(_ id: Int, iid: Int) async throws -> [GLDiff] {
        try await get("/projects/\(id)/merge_requests/\(iid)/diffs?per_page=40").array.map(GLDiff.init)
    }

    func issues(_ id: Int, state: String = "opened") async throws -> [GLItem] {
        try await get("/projects/\(id)/issues?state=\(state)&per_page=30&order_by=updated_at").array.map(GLItem.init)
    }

    func notes(_ id: Int, kind: String, iid: Int) async throws -> [GLNote] {
        try await get("/projects/\(id)/\(kind)/\(iid)/notes?per_page=30&sort=asc").array.map(GLNote.init).filter { !$0.system }
    }

    func pipelines(_ id: Int) async throws -> [GLPipeline] {
        try await get("/projects/\(id)/pipelines?per_page=30").array.map(GLPipeline.init)
    }

    func jobs(_ id: Int, pipeline: Int) async throws -> [GLJob] {
        try await get("/projects/\(id)/pipelines/\(pipeline)/jobs?per_page=100").array.map(GLJob.init)
    }

    func approve(_ id: Int, iid: Int) async throws {
        _ = try await HTTP.data(baseURL + "/api/v4/projects/\(id)/merge_requests/\(iid)/approve", method: "POST", headers: headers)
    }

    func comment(_ id: Int, kind: String, iid: Int, body: String) async throws {
        _ = try await HTTP.data(baseURL + "/api/v4/projects/\(id)/\(kind)/\(iid)/notes", method: "POST", headers: headers, body: ["body": body])
    }

    func retry(_ id: Int, pipeline: Int) async throws {
        _ = try await HTTP.data(baseURL + "/api/v4/projects/\(id)/pipelines/\(pipeline)/retry", method: "POST", headers: headers)
    }
}
