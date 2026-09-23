import SwiftUI
import Charts

struct GrafanaHomeView: View {
    @Environment(AppConfig.self) private var config
    @State private var dashboards: [GrafanaDashRef] = []
    @State private var query = ""
    @State private var error: String?
    @State private var loading = true
    @State private var section = 0

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case 1: AlertsView()
                case 2: MetabaseHomeView()
                default: dashboardList
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("", selection: $section) {
                    Label("Grafana", systemImage: "chart.xyaxis.line").tag(0)
                    Text("Alerts").tag(1)
                    Text("Metabase").tag(2)
                }
                .pickerStyle(.segmented).padding(.horizontal).padding(.bottom, 6)
            }
            .navigationTitle("Dashboards")
            .navigationDestination(for: GrafanaDashRef.self) { DashboardScreen(ref: $0) }
            .navigationDestination(for: MBDashRef.self) { MBDashboardScreen(ref: $0) }
            .onReceive(NotificationCenter.default.publisher(for: .showMetabase)) { _ in section = 2 }
        }
    }

    private var dashboardList: some View {
            List {
                if let error { ErrorCard(message: error) { Task { await load() } }.listRowBackground(Color.clear) }
                let grouped = Dictionary(grouping: dashboards) { $0.folder ?? "General" }
                ForEach(grouped.keys.sorted(), id: \.self) { folder in
                    Section(folder) {
                        ForEach(grouped[folder] ?? []) { d in
                            NavigationLink(value: d) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(d.title).font(.body.weight(.medium))
                                    if !d.tags.isEmpty {
                                        Text(d.tags.prefix(3).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay { if loading && dashboards.isEmpty { ProgressView() } }
            .searchable(text: $query, prompt: "Search dashboards")
            .onSubmit(of: .search) { Task { await load() } }
            .onChange(of: query) { if query.isEmpty { Task { await load() } } }
            .refreshable { await load() }
            .task { if dashboards.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            dashboards = try await config.grafana.search(query, limit: query.isEmpty ? 80 : 40)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

@Observable
final class PanelData {
    var series: [Series] = []
    var failed = false
    var loaded = false
}

struct DashboardScreen: View {
    @Environment(AppConfig.self) private var config
    let ref: GrafanaDashRef
    @State private var dash: GrafanaDashboard?
    @State private var range: TimeRange = .h6
    @State private var data: [Int: PanelData] = [:]
    @State private var error: String?
    @State private var focused: GrafanaPanel?
    @State private var askAI = false
    @State private var autoRefresh = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if let error { ErrorCard(message: error) { Task { await load() } } }

                if let dash {
                    let panels = dash.panels.filter { !$0.isText && $0.type != "row" }
                    let stats = panels.filter { ["stat", "gauge"].contains($0.type) }
                    let others = panels.filter { !["stat", "gauge"].contains($0.type) }
                    if !stats.isEmpty {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            ForEach(stats) { p in
                                PanelCard(ref: ref, panel: p, range: range, data: data[p.id] ?? PanelData(), compact: true)
                                    .onTapGesture { focused = p }
                            }
                        }
                    }
                    ForEach(others) { p in
                        PanelCard(ref: ref, panel: p, range: range, data: data[p.id] ?? PanelData(), compact: false)
                            .onTapGesture { focused = p }
                    }
                } else if error == nil {
                    ProgressView().padding(40)
                }
            }
            .padding()
        }
        .navigationTitle(dash?.title ?? ref.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { autoRefresh.toggle() } label: {
                    Image(systemName: autoRefresh ? "dot.radiowaves.left.and.right" : "arrow.clockwise")
                        .symbolEffect(.variableColor.iterative, isActive: autoRefresh)
                }
                Button { askAI = true } label: { Image(systemName: "sparkles") }
                if let u = config.grafana.webURL(uid: ref.uid) { ShareLink(item: u) }
            }
        }
        .refreshable { await refreshData() }
        .task { await load() }
        .onChange(of: range) { Task { await refreshData() } }
        .task(id: autoRefresh) {
            while autoRefresh && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if autoRefresh { await refreshData() }
            }
        }
        .sheet(item: $focused) { p in PanelDetail(ref: ref, panel: p, range: range, data: data[p.id] ?? PanelData()) }
        .sheet(isPresented: $askAI) {
            AskSheet(title: "Ask this dashboard", accent: Brand.grafana,
                     suggestions: ["What looks abnormal right now?", "Summarize this dashboard in 3 bullets", "Which metric is trending up fastest?"]) {
                describe()
            }
        }
    }

    private func load() async {
        do {
            dash = try await config.grafana.dashboard(uid: ref.uid)
            error = nil
            await refreshData()
        } catch { self.error = error.localizedDescription }
    }

    private func refreshData() async {
        guard let dash else { return }
        let client = config.grafana
        let r = range
        for p in dash.panels where data[p.id] == nil { data[p.id] = PanelData() }
        await withTaskGroup(of: Void.self) { group in
            for p in dash.panels where p.isChartable {
                let holder = data[p.id]!
                group.addTask {
                    do {
                        let s = try await client.query(panel: p, range: r)
                        await MainActor.run { holder.series = s; holder.failed = s.isEmpty; holder.loaded = true }
                    } catch {
                        await MainActor.run { holder.failed = true; holder.loaded = true }
                    }
                }
            }
        }
    }

    /// Numbers, not pixels, for the model: per-series last/min/max/trend.
    private func describe() -> String {
        guard let dash else { return "" }
        var lines = ["DASHBOARD \(dash.title), range last \(range.rawValue)."]
        for p in dash.panels where p.isChartable {
            guard let d = data[p.id], !d.series.isEmpty else { continue }
            lines.append("PANEL \(p.title) [\(p.type)\(p.unit.map { ", unit \($0)" } ?? "")]")
            for s in d.series.prefix(6) {
                let vals = s.points.map(\.1)
                guard let first = vals.first, let last = vals.last else { continue }
                let change = first == 0 ? 0 : (last - first) / abs(first) * 100
                lines.append("  \(s.name): last \(last.compact), min \(vals.min()!.compact), max \(vals.max()!.compact), change \(String(format: "%+.0f", change))%")
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct PanelCard: View {
    @Environment(AppConfig.self) private var config
    let ref: GrafanaDashRef
    let panel: GrafanaPanel
    let range: TimeRange
    let data: PanelData
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(panel.title.isEmpty ? panel.type.capitalized : panel.title)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if data.loaded && !data.series.isEmpty {
                    Image(systemName: "waveform.path.ecg").font(.caption2).foregroundStyle(Brand.grafana)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    @ViewBuilder
    private var content: some View {
        if !data.series.isEmpty {
            if compact || panel.type == "stat" || panel.type == "gauge" {
                StatValue(series: data.series, unit: panel.unit, compact: compact)
            } else {
                SeriesChart(series: data.series, unit: panel.unit).frame(height: 170)
            }
        } else if !panel.isChartable || data.failed {
            RenderedPanel(url: config.grafana.renderURL(uid: ref.uid, panelId: panel.id, range: range,
                                                        width: compact ? 500 : 1000, height: compact ? 300 : 500))
                .frame(height: compact ? 90 : 170)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: compact ? 60 : 170)
        }
    }
}

struct StatValue: View {
    let series: [Series]
    let unit: String?
    let compact: Bool
    var body: some View {
        let v = series.compactMap(\.last).reduce(0, +)
        VStack(alignment: .leading, spacing: 4) {
            Text(UnitFormat.format(v, unit)).font(compact ? .title2.bold() : .largeTitle.bold()).monospacedDigit()
                .foregroundStyle(Brand.grafana).minimumScaleFactor(0.5).lineLimit(1)
            if let s = series.first, s.points.count > 2 {
                Chart(Array(s.points.enumerated()), id: \.offset) { p in
                    AreaMark(x: .value("t", p.element.0), y: .value("v", p.element.1))
                        .foregroundStyle(Brand.grafana.opacity(0.25).gradient)
                    LineMark(x: .value("t", p.element.0), y: .value("v", p.element.1))
                        .foregroundStyle(Brand.grafana)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 30)
            }
        }
    }
}

struct SeriesChart: View {
    let series: [Series]
    let unit: String?
    @State private var selected: Date?

    var body: some View {
        let shown = Array(series.prefix(8))
        Chart {
            ForEach(shown) { s in
                ForEach(Array(s.points.enumerated()), id: \.offset) { p in
                    LineMark(x: .value("Time", p.element.0), y: .value("Value", p.element.1))
                        .foregroundStyle(by: .value("Series", s.name))
                        .interpolationMethod(.monotone)
                }
            }
            if let selected {
                RuleMark(x: .value("Selected", selected)).foregroundStyle(.white.opacity(0.4))
                    .annotation(position: .top, overflowResolution: .init(x: .fit, y: .disabled)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selected.formatted(date: .omitted, time: .shortened)).font(.caption2.bold())
                            ForEach(shown.prefix(4)) { s in
                                if let v = s.points.min(by: { abs($0.0.timeIntervalSince(selected)) < abs($1.0.timeIntervalSince(selected)) }) {
                                    Text("\(s.name.prefix(18)): \(UnitFormat.format(v.1, unit))").font(.caption2)
                                }
                            }
                        }
                        .padding(6).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                    }
            }
        }
        .chartXSelection(value: $selected)
        .chartLegend(shown.count > 1 ? .visible : .hidden)
        .chartLegend(position: .bottom, spacing: 4)
        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(UnitFormat.format(d, unit)) } } } }
    }
}

struct RenderedPanel: View {
    let url: URL?
    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
            case .failure: Label("Preview unavailable", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
            default: ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct PanelDetail: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    let ref: GrafanaDashRef
    let panel: GrafanaPanel
    let range: TimeRange
    let data: PanelData

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !data.series.isEmpty {
                        SeriesChart(series: data.series, unit: panel.unit).frame(height: 300).card()
                        ForEach(data.series.prefix(12)) { s in
                            HStack {
                                Text(s.name).font(.caption).lineLimit(1)
                                Spacer()
                                Text(UnitFormat.format(s.last ?? 0, panel.unit)).font(.caption.monospacedDigit().bold())
                            }
                        }
                        .card()
                    } else {
                        RenderedPanel(url: config.grafana.renderURL(uid: ref.uid, panelId: panel.id, range: range, width: 1200, height: 700)).card()
                    }
                    if let d = panel.description, !d.isEmpty { Text(d).font(.footnote).foregroundStyle(.secondary) }
                    Label(data.series.isEmpty ? "Server-rendered image" : "Native chart from /api/ds/query",
                          systemImage: data.series.isEmpty ? "photo" : "chart.xyaxis.line")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding()
            }
            .navigationTitle(panel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

enum UnitFormat {
    static func format(_ v: Double, _ unit: String?) -> String {
        switch unit ?? "" {
        case "percent": return String(format: "%.1f%%", v)
        case "percentunit": return String(format: "%.1f%%", v * 100)
        case "bytes", "decbytes": return ByteCountFormatter.string(fromByteCount: Int64(v), countStyle: .binary)
        case "s": return v < 1 ? String(format: "%.0f ms", v * 1000) : String(format: "%.1f s", v)
        case "ms": return String(format: "%.0f ms", v)
        case "reqps": return v.compact + " req/s"
        case "currencyUSD": return "$" + v.compact
        default: return v.compact
        }
    }
}

extension Notification.Name {
    static let showMetabase = Notification.Name("opendesk.showMetabase")
}
