import SwiftUI
import Charts

/// One screen that answers "how is the business doing" across every self-hosted tool.
struct HomeView: View {
    @Environment(AppConfig.self) private var config
    @Binding var tab: RootTab
    @State private var pipeline: [NocoRecord] = []
    @State private var eventsTable: NocoTable?
    @State private var nocoOK: Bool?
    @State private var grafanaOK: Bool?
    @State private var gitlabOK: Bool?
    @State private var metabaseOK: Bool?
    @State private var pulse: [Series] = []
    @State private var mrs: [GLItem] = []
    @State private var pipelines: [GLPipeline] = []
    @State private var gitlabProject: GLProject?
    @State private var connecting: Integration?
    @State private var brief = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectors
                    briefButton
                    pipelineCard
                    grafanaCard
                    gitlabCard
                }
                .padding()
            }
            .navigationTitle("OpenDesk")
            .refreshable { await load() }
            .task { await load() }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    if let p = try? await config.grafana.pulse(), !p.isEmpty { pulse = p }
                }
            }

            .sheet(isPresented: $brief) {
                AskSheet(title: "Morning brief", accent: Brand.ai,
                         suggestions: ["Give me a 5-bullet brief across everything", "What should I do first today?", "Anything on fire?"]) {
                    briefContext()
                }
            }
        }
    }

    // MARK: Sections

    private var connectors: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Integration.allCases) { i in tile(i) }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 0)
        .scrollClipDisabled()
        .sheet(item: $connecting) { i in
            switch i {
            case .supabase: SupabaseConnectView()
            case .airtable: AirtableConnectView()
            case .noco: NocoConnectView()
            default: SettingsView()
            }
        }
    }

    /// nil = checking, true = live, false = needs connecting
    private func state(_ i: Integration) -> (Bool?, String) {
        switch i {
        case .noco:
            if config.nocoToken.isEmpty { return (false, "Connect") }
            if Connectivity.shared.nocoOffline { return (true, "Cached") }
            return (nocoOK, nocoOK == false ? "Can't reach" : "Live")
        case .supabase:
            let sb = SupabaseApp.shared
            return (sb.isAdmin || sb.session != nil) ? (true, "\(sb.tables.count) tables") : (false, "Connect")
        case .airtable:
            let at = AirtableStore.shared
            return at.isConnected ? (at.bases.isEmpty ? nil : true, "\(at.bases.count) bases") : (false, "Connect")
        case .grafana: return (grafanaOK, grafanaOK == false ? "Can't reach" : "Live")
        case .metabase: return config.metabaseKey.isEmpty ? (false, "Connect") : (metabaseOK, metabaseOK == false ? "Can't reach" : "Live")
        case .gitlab: return (gitlabOK, gitlabOK == false ? "Can't reach" : "Live")
        case .excalidraw: return (true, "Ready")
        }
    }

    private func tile(_ i: Integration) -> some View {
        let (ok, label) = state(i)
        return Button {
            if ok == false { connecting = i } else {
                switch i {
                case .noco, .supabase, .airtable: tab = .tables
                case .grafana: tab = .dashboards
                case .metabase:
                    tab = .dashboards
                    NotificationCenter.default.post(name: .showMetabase, object: nil)
                case .gitlab, .excalidraw: tab = .more
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    BrandMark(kind: i, size: 24)
                    Spacer()
                    Circle().fill(ok == nil ? Color.gray : ok! ? (label == "Cached" ? .orange : .green) : .clear)
                        .overlay(Circle().stroke(ok == false ? Color.secondary : .clear, lineWidth: 1))
                        .frame(width: 7)
                }
                Text(i.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(ok == nil ? "Connecting" : label).font(.caption2).foregroundStyle(ok == false ? i.color : .secondary)
            }
            .frame(width: 92, alignment: .leading)
            .card(padding: 10)
        }
        .buttonStyle(.plain)
    }

    private var briefButton: some View {
        Button { brief = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.title2).foregroundStyle(Brand.ai)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Brief me").font(.headline)
                    Text("Pipeline, metrics and code in one answer · \(AI.engine(config).rawValue)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .card()
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Brand.ai.opacity(0.4)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var pipelineCard: some View {
        let stages = ["Inquiry", "Proposal Sent", "Tasting", "Booked"]
        let open = pipeline.filter { stages.contains($0["Stage"]?.string ?? "") }
        let value = open.compactMap { $0["Budget"]?.double }.reduce(0, +)
        let upcoming = pipeline
            .filter { $0["Stage"]?.string == "Booked" }
            .compactMap { r -> (NocoRecord, Date)? in r["Date"]?.string.flatMap(DateField.parse).map { (r, $0) } }
            .filter { $0.1 >= Calendar.current.startOfDay(for: Date()) }
            .sorted { $0.1 < $1.1 }
            .prefix(3)
        if !pipeline.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                header("Sales pipeline", "NocoDB · \(eventsTable?.title ?? "Events")", Brand.noco)
                HStack(alignment: .firstTextBaseline) {
                    Text(value.currency).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("open across \(open.count) events").font(.caption).foregroundStyle(.secondary)
                }
                Chart(stages, id: \.self) { s in
                    let v = open.filter { $0["Stage"]?.string == s }.compactMap { $0["Budget"]?.double }.reduce(0, +)
                    BarMark(x: .value("Value", v), stacking: .standard)
                        .foregroundStyle(by: .value("Stage", s))
                }
                .chartForegroundStyleScale(domain: stages, range: [Color.blue, .yellow, .purple, .green])
                .chartXAxis(.hidden)
                .chartLegend(position: .bottom)
                .frame(height: 56)
                if !upcoming.isEmpty {
                    Divider()
                    Text("Next booked").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(upcoming), id: \.0.recordId) { r, d in
                        HStack {
                            Text(d.formatted(.dateTime.month(.abbreviated).day())).font(.caption.monospacedDigit()).frame(width: 48, alignment: .leading).foregroundStyle(Brand.noco)
                            Text(r["Event"]?.display ?? "").font(.subheadline).lineLimit(1)
                            Spacer()
                            Text("\(r["Guests"]?.int ?? 0) ppl").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .card()
            .onTapGesture { tab = .tables }
        }
    }

    @ViewBuilder
    private var grafanaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Live signal", "Grafana · \(URL(string: config.grafanaURL)?.host ?? "")", Brand.grafana)
            if let s = pulse.first {
                HStack(alignment: .firstTextBaseline) {
                    Text((s.last ?? 0).compact).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    let first = s.points.first?.1 ?? 0
                    let delta = (s.last ?? 0) - first
                    Text(String(format: "%+.1f in 1h", delta)).font(.caption).foregroundStyle(delta >= 0 ? .green : .red)
                }
                Chart(Array(s.points.enumerated()), id: \.offset) { p in
                    AreaMark(x: .value("t", p.element.0), y: .value("v", p.element.1))
                        .foregroundStyle(LinearGradient(colors: [Brand.grafana.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", p.element.0), y: .value("v", p.element.1)).foregroundStyle(Brand.grafana)
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .frame(height: 90)
                .animation(.smooth, value: s.points.count)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 90)
            }
        }
        .card()
        .onTapGesture { tab = .dashboards }
    }

    @ViewBuilder
    private var gitlabCard: some View {
        if let gitlabProject {
            VStack(alignment: .leading, spacing: 10) {
                header("Code health", "GitLab · \(gitlabProject.path)", Brand.gitlab)
                HStack(spacing: 2) {
                    ForEach(pipelines.prefix(30).reversed()) { p in
                        RoundedRectangle(cornerRadius: 2).fill(GLStatus.color(p.status)).frame(height: 18)
                    }
                }
                let failed = pipelines.prefix(30).filter { $0.status == "failed" }.count
                let passed = pipelines.prefix(30).filter { $0.status == "success" }.count
                Text("\(passed) passed · \(failed) failed · \(mrs.count)+ open MRs").font(.caption).foregroundStyle(.secondary)
                ForEach(mrs.prefix(3)) { m in
                    HStack {
                        Text("!\(m.iid)").font(.caption.monospacedDigit()).foregroundStyle(Brand.gitlab)
                        Text(m.title).font(.subheadline).lineLimit(1)
                    }
                }
            }
            .card()
            .onTapGesture { tab = .more }
        }
    }

    private func header(_ title: String, _ sub: String, _ color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(sub).font(.caption2).foregroundStyle(color)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: Data

    private func load() async {
        async let n: Void = loadNoco()
        async let g: Void = loadGrafana()
        async let l: Void = loadGitLab()
        async let m: Void = loadMetabase()
        async let a: Void = { if AirtableStore.shared.isConnected && AirtableStore.shared.bases.isEmpty { try? await AirtableStore.shared.load() } }()
        async let s: Void = { if SupabaseApp.shared.isAdmin || SupabaseApp.shared.session != nil { try? await SupabaseApp.shared.loadSchema() } }()
        _ = await (n, g, l, m, a, s)
    }

    private func loadNoco() async {
        do {
            let noco = config.noco
            let bases = try await noco.bases()
            nocoOK = true
            var all: [NocoTable] = []
            for b in bases {
                let tables = try await noco.tables(baseId: b.id)
                all += tables
                if eventsTable == nil, let t = tables.first(where: { $0.title.lowercased() == "events" }) {
                    eventsTable = t
                    pipeline = try await noco.allRecords(tableId: t.id)
                }
            }
            // Warm the offline cache for every table so the app still works if the server drops.
            Task.detached(priority: .background) {
                for t in all {
                    _ = try? await noco.columns(tableId: t.id)
                    _ = try? await noco.allRecords(tableId: t.id)
                }
            }
        } catch { nocoOK = false }
    }

    private func loadGrafana() async {
        do {
            pulse = try await config.grafana.pulse()
            grafanaOK = true
        } catch {
            grafanaOK = (try? await config.grafana.search(limit: 1)) != nil
        }
    }

    private func loadMetabase() async {
        metabaseOK = (try? await config.metabase.dashboards()) != nil
    }

    private func loadGitLab() async {
        let gl = config.gitlab
        guard let path = config.pinnedProjects.first, let p = try? await gl.project(path) else { gitlabOK = false; return }
        gitlabOK = true
        gitlabProject = p
        async let m = gl.mergeRequests(p.id)
        async let pl = gl.pipelines(p.id)
        mrs = (try? await m) ?? []
        pipelines = (try? await pl) ?? []
    }

    private func briefContext() -> String {
        var lines = ["TODAY: \(Date().formatted(date: .complete, time: .shortened)). Cover all three sources below: the catering pipeline first, then metrics, then code."]
        if !pipeline.isEmpty {
            lines.append("CATERING PIPELINE (NocoDB Events): Event | Client | Date | Guests | Stage | Budget | Notes")
            let soon = pipeline.sorted { ($0["Date"]?.string ?? "") < ($1["Date"]?.string ?? "") }
                .filter { ($0["Date"]?.string ?? "") >= DateField.string(Date().addingTimeInterval(-7 * 86400)) }
            for r in soon.prefix(18) {
                lines.append(["Event", "Client", "Date", "Guests", "Stage", "Budget", "Notes"].map { r[$0]?.display ?? "" }.joined(separator: " | "))
            }
        }
        if let s = pulse.first, let last = s.last, let first = s.points.first?.1 {
            lines.append("GRAFANA LIVE SIGNAL: now \(last.compact), 1h ago \(first.compact), min \(s.points.map(\.1).min()!.compact), max \(s.points.map(\.1).max()!.compact)")
        }
        if let gitlabProject {
            lines.append("GITLAB \(gitlabProject.path): last 30 pipelines \(pipelines.prefix(30).map(\.status).joined(separator: ","))")
            for m in mrs.prefix(6) { lines.append("MR !\(m.iid) \(m.title) (updated \(relativeDate(m.updatedAt)))") }
        }
        return lines.joined(separator: "\n")
    }
}
