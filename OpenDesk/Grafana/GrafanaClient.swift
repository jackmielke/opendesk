import Foundation

struct GrafanaDashRef: Identifiable, Hashable {
    let uid: String
    let title: String
    let folder: String?
    let tags: [String]
    var id: String { uid }

    init(json: JSONValue) {
        uid = json["uid"]?.string ?? ""
        title = json["title"]?.string ?? ""
        folder = json["folderTitle"]?.string
        tags = json["tags"]?.array.compactMap(\.string) ?? []
    }
}

struct GrafanaPanel: Identifiable, Hashable {
    let id: Int
    let title: String
    let type: String
    let unit: String?
    let targets: [JSONValue]
    let datasource: JSONValue?
    let description: String?
    let width: Int

    init(json: JSONValue) {
        id = json["id"]?.int ?? 0
        title = json["title"]?.string ?? ""
        type = json["type"]?.string ?? ""
        unit = json["fieldConfig"]?["defaults"]?["unit"]?.string
        targets = json["targets"]?.array ?? []
        datasource = json["datasource"]
        description = json["description"]?.string
        width = json["gridPos"]?["w"]?.int ?? 24
    }

    var isChartable: Bool { ["timeseries", "graph", "stat", "gauge", "bargauge", "barchart"].contains(type) }
    var isText: Bool { type == "text" || type == "news" || type == "dashlist" }
}

struct GrafanaDashboard {
    let uid: String
    let title: String
    let panels: [GrafanaPanel]
    let hasVariables: Bool
}

struct Series: Identifiable {
    let id = UUID()
    let name: String
    let points: [(Date, Double)]
    var last: Double? { points.last?.1 }
}

enum TimeRange: String, CaseIterable, Identifiable {
    case h1 = "1h", h6 = "6h", h24 = "24h", d7 = "7d"
    var id: String { rawValue }
    var from: String { "now-\(rawValue)" }
    var intervalMs: Int {
        switch self { case .h1: 30_000; case .h6: 120_000; case .h24: 600_000; case .d7: 3_600_000 }
    }
}

struct GrafanaClient {
    let baseURL: String
    let token: String

    private var headers: [String: String] { token.isEmpty ? [:] : ["Authorization": "Bearer \(token)"] }

    func search(_ query: String = "", limit: Int = 60) async throws -> [GrafanaDashRef] {
        let j = try await HTTP.json(JSONValue.self, baseURL + "/api/search?type=dash-db&limit=\(limit)&query=\(query.queryEncoded)", headers: headers)
        return j.array.map(GrafanaDashRef.init)
    }

    func dashboard(uid: String) async throws -> GrafanaDashboard {
        let j = try await HTTP.json(JSONValue.self, baseURL + "/api/dashboards/uid/\(uid)", headers: headers)
        let d = j["dashboard"] ?? .null
        var flat: [GrafanaPanel] = []
        for p in d["panels"]?.array ?? [] {
            if p["type"]?.string == "row" {
                flat += (p["panels"]?.array ?? []).map(GrafanaPanel.init)
            } else {
                flat.append(GrafanaPanel(json: p))
            }
        }
        let vars = d["templating"]?["list"]?.array ?? []
        return GrafanaDashboard(uid: uid, title: d["title"]?.string ?? "", panels: flat, hasVariables: !vars.isEmpty)
    }

    /// Runs a panel's queries through Grafana's datasource proxy and returns plottable series.
    func query(panel: GrafanaPanel, range: TimeRange) async throws -> [Series] {
        let queries: [JSONValue] = panel.targets.compactMap { t in
            guard case .object(var o) = t else { return nil }
            if o["hide"]?.bool == true { return nil }
            if o["datasource"] == nil || o["datasource"]?.isNull == true { o["datasource"] = panel.datasource }
            let ds = o["datasource"]?["uid"]?.string ?? ""
            // Template variables need dashboard context we don't resolve; let the caller fall back to a render.
            if ds.hasPrefix("$") || ds == "-- Mixed --" || ds == "-- Dashboard --" || t.compactJSON.contains("$__all") { return nil }
            o["intervalMs"] = .number(Double(range.intervalMs))
            o["maxDataPoints"] = .number(300)
            return .object(o)
        }
        guard !queries.isEmpty else { return [] }
        let body: JSONValue = .object(["from": .string(range.from), "to": .string("now"), "queries": .array(queries)])
        let j = try await HTTP.json(JSONValue.self, baseURL + "/api/ds/query", method: "POST", headers: headers, body: body)
        return Self.parseFrames(j)
    }

    static func parseFrames(_ j: JSONValue) -> [Series] {
        var out: [Series] = []
        for (_, result) in j["results"]?.object ?? [:] {
            for frame in result["frames"]?.array ?? [] {
                let fields = frame["schema"]?["fields"]?.array ?? []
                let values = frame["data"]?["values"]?.array ?? []
                guard let ti = fields.firstIndex(where: { $0["type"]?.string == "time" }), values.count == fields.count else { continue }
                let times = values[ti].array.map { Date(timeIntervalSince1970: ($0.double ?? 0) / 1000) }
                for (i, f) in fields.enumerated() where f["type"]?.string == "number" {
                    let nums = values[i].array
                    var pts: [(Date, Double)] = []
                    for (k, t) in times.enumerated() where k < nums.count {
                        if let v = nums[k].double, v.isFinite { pts.append((t, v)) }
                    }
                    let labels = f["labels"]?.object.map { "\($0.key)=\($0.value.display)" }.sorted().joined(separator: ", ")
                    let name = f["config"]?["displayNameFromDS"]?.string
                        ?? (labels?.isEmpty == false ? labels! : nil)
                        ?? frame["schema"]?["name"]?.string
                        ?? f["name"]?.string ?? "value"
                    if !pts.isEmpty { out.append(Series(name: name, points: pts)) }
                }
            }
        }
        return out
    }

    func renderURL(uid: String, panelId: Int, range: TimeRange, width: Int = 1000, height: Int = 500) -> URL? {
        URL(string: baseURL + "/render/d-solo/\(uid)/_?panelId=\(panelId)&width=\(width)&height=\(height)&theme=dark&from=\(range.from)&to=now&tz=\(TimeZone.current.identifier.queryEncoded)")
    }

    func webURL(uid: String) -> URL? { URL(string: baseURL + "/d/\(uid)") }

    /// A synthetic live signal from Grafana's TestData datasource, for the home screen pulse.
    func pulse() async throws -> [Series] {
        let sources = try await HTTP.json(JSONValue.self, baseURL + "/api/datasources", headers: headers).array
        guard let ds = sources.first(where: { ($0["type"]?.string ?? "").contains("testdata") }),
              let uid = ds["uid"]?.string else { return [] }
        let body: JSONValue = .object([
            "from": .string("now-1h"), "to": .string("now"),
            "queries": .array([.object([
                "refId": .string("A"),
                "datasource": .object(["uid": .string(uid), "type": ds["type"] ?? .null]),
                "scenarioId": .string("random_walk"), "seriesCount": .number(1),
                "intervalMs": .number(30_000), "maxDataPoints": .number(120),
            ])]),
        ])
        let j = try await HTTP.json(JSONValue.self, baseURL + "/api/ds/query", method: "POST", headers: headers, body: body)
        return Self.parseFrames(j)
    }
}
