import SwiftUI
import Charts

extension Brand {
    static let metabase = Color(red: 0.31, green: 0.62, blue: 0.89)
}

struct MetabaseHomeView: View {
    @Environment(AppConfig.self) private var config
    @State private var dashboards: [MBDashRef] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if error != nil && dashboards.isEmpty {
                    ContentUnavailableView {
                        Label("Metabase isn't reachable", systemImage: "chart.pie")
                    } description: {
                        Text("OpenDesk will load your dashboards as soon as \(URL(string: config.metabaseURL)?.host ?? "the server") responds.")
                    } actions: {
                        Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(dashboards) { d in
                    NavigationLink(value: d) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(d.name).font(.body.weight(.medium))
                            Text(d.description ?? d.collection ?? "Dashboard").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .overlay { if !loaded { ProgressView() } }
            .navigationTitle("Analytics")
            .navigationDestination(for: MBDashRef.self) { MBDashboardScreen(ref: $0) }
            .refreshable { await load() }
            .task { if !loaded { await load() } }
        }
    }

    private func load() async {
        do {
            dashboards = try await config.metabase.dashboards()
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }
}

struct MBDashboardScreen: View {
    @Environment(AppConfig.self) private var config
    let ref: MBDashRef
    @State private var dash: MBDashboard?
    @State private var tab: Int?
    @State private var results: [Int: MBResult] = [:]
    @State private var failed: Set<Int> = []
    @State private var error: String?
    @State private var askAI = false

    private var visible: [MBDashcard] {
        guard let dash else { return [] }
        return dash.cards.filter { tab == nil || $0.tabId == tab }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let dash, dash.tabs.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(dash.tabs) { t in
                                Button(t.name) { tab = t.id }
                                    .buttonStyle(.bordered)
                                    .tint(tab == t.id ? Brand.metabase : .secondary)
                            }
                        }
                    }
                }
                if error != nil { Label("Metabase isn't reachable right now · pull to retry", systemImage: "icloud.slash").font(.caption).foregroundStyle(.secondary) }
                let scalars = visible.filter { ["scalar", "smartscalar", "progress", "gauge"].contains($0.display) }
                if !scalars.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(scalars) { c in MBCardView(card: c, result: results[c.id], failed: failed.contains(c.id)) }
                    }
                }
                ForEach(visible.filter { !["scalar", "smartscalar", "progress", "gauge"].contains($0.display) }) { c in
                    if c.isHeading {
                        if let h = c.heading, !h.isEmpty, c.display == "heading" {
                            Text(h).font(.title3.bold()).padding(.top, 8)
                        }
                    } else {
                        MBCardView(card: c, result: results[c.id], failed: failed.contains(c.id))
                    }
                }
                if dash == nil && error == nil { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }
            .padding()
        }
        .navigationTitle(dash?.name ?? ref.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button { askAI = true } label: { Image(systemName: "sparkles") } }
        .refreshable { await load() }
        .task { if dash == nil { await load() } }
        .onChange(of: tab) { Task { await runQueries() } }
        .sheet(isPresented: $askAI) {
            AskSheet(title: "Ask \(ref.name)", accent: Brand.metabase,
                     suggestions: ["What are the key takeaways?", "Which category is growing fastest?", "Anything that looks off?"]) {
                describe()
            }
        }
    }

    private func load() async {
        do {
            let d = try await config.metabase.dashboard(ref.id)
            dash = d
            if tab == nil { tab = d.tabs.first?.id }
            error = nil
            await runQueries()
        } catch { self.error = error.localizedDescription }
    }

    private func runQueries() async {
        guard let dash else { return }
        let client = config.metabase
        let todo = visible.filter { !$0.isHeading && results[$0.id] == nil }
        await withTaskGroup(of: (Int, MBResult?).self) { group in
            for c in todo {
                group.addTask { (c.id, try? await client.query(dashboard: dash.id, card: c)) }
            }
            for await (id, r) in group {
                if let r { results[id] = r } else { failed.insert(id) }
            }
        }
    }

    private func describe() -> String {
        var lines = ["METABASE DASHBOARD \(ref.name)"]
        for c in visible where !c.isHeading {
            guard let r = results[c.id], !r.rows.isEmpty else { continue }
            lines.append("CARD \(c.name) [\(c.display)] columns: \(r.cols.map(\.name).joined(separator: ", "))")
            for row in r.rows.filter({ !$0.contains(.null) }).suffix(8) {
                lines.append("  " + row.map { $0.double.map { $0.compact } ?? $0.display }.joined(separator: " | "))
            }
        }
        return lines.joined(separator: "\n")
    }
}

struct MBCardView: View {
    let card: MBDashcard
    let result: MBResult?
    let failed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let result, !result.rows.isEmpty {
                content(result)
            } else if failed {
                Text("No data yet").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
    }

    @ViewBuilder
    private func content(_ r: MBResult) -> some View {
        switch card.display {
        case "scalar", "gauge", "progress":
            let v = r.rows.first?.compactMap(\.double).last ?? 0
            Text(v.compact).font(.title.bold()).monospacedDigit().foregroundStyle(Brand.metabase)
        case "smartscalar":
            let series = r.rows.compactMap { row -> Double? in row.last?.double }
            let last = series.last ?? 0
            let prev = series.dropLast().last
            VStack(alignment: .leading, spacing: 2) {
                Text(last.compact).font(.title.bold()).monospacedDigit().foregroundStyle(Brand.metabase)
                if let prev, prev != 0 {
                    let pct = (last - prev) / abs(prev) * 100
                    Label(String(format: "%+.1f%% vs previous", pct), systemImage: pct >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption).foregroundStyle(pct >= 0 ? .green : .red)
                }
            }
        case "line", "area", "combo", "bar", "row", "waterfall":
            MBSeriesChart(result: r, display: card.display)
        case "pie", "funnel":
            MBPie(result: r, funnel: card.display == "funnel")
        case "scatter":
            MBScatter(result: r)
        default:
            MBTable(result: r)
        }
    }
}

private func xLabel(_ v: JSONValue, temporal: Bool) -> String {
    let s = v.display
    if temporal, let d = DateField.parse(s) { return d.formatted(.dateTime.month(.abbreviated).year(.twoDigits)) }
    return s
}

struct MBSeriesChart: View {
    let result: MBResult
    let display: String

    var body: some View {
        // Two breakouts (e.g. month × category): x is the temporal one, series come from the other.
        let dims = result.cols.indices.filter { !result.cols[$0].isNumeric }
        let breakout: Int? = dims.count >= 2 ? dims.first { !result.cols[$0].isTemporal } : nil
        let dim = breakout.flatMap { b in dims.first { $0 != b } } ?? result.dimension ?? 0
        let temporal = result.cols[dim].isTemporal
        let metrics = breakout != nil ? Array(result.metrics.filter { $0 != dim && $0 != breakout }.prefix(1)) : Array(result.metrics.prefix(3))
        let rows = result.rows.filter { r in metrics.contains { r.indices.contains($0) && r[$0].double != nil } }.prefix(breakout != nil ? 240 : 60)
        let points: [(x: String, date: Date?, series: String, y: Double)] = rows.flatMap { r in
            metrics.compactMap { m in
                guard let y = r[m].double else { return nil }
                let series = breakout.map { r[$0].display } ?? result.cols[m].name
                return (xLabel(r[dim], temporal: temporal), temporal ? DateField.parse(r[dim].display) : nil, series, y)
            }
        }
        let seriesCount = Set(points.map(\.series)).count
        Chart(Array(points.enumerated()), id: \.offset) { _, p in
            if display == "row" {
                BarMark(x: .value(p.series, p.y), y: .value("", p.x))
                    .foregroundStyle(by: .value("Series", p.series))
            } else if display == "bar" || display == "waterfall" || (display == "combo" && breakout == nil && p.series == result.cols[metrics.last ?? 0].name && metrics.count > 1) {
                if let d = p.date {
                    BarMark(x: .value("", d, unit: .month), y: .value(p.series, p.y)).foregroundStyle(by: .value("Series", p.series))
                } else {
                    BarMark(x: .value("", p.x), y: .value(p.series, p.y)).foregroundStyle(by: .value("Series", p.series))
                }
            } else if let d = p.date {
                LineMark(x: .value("", d), y: .value(p.series, p.y))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.monotone)
                if display == "area" {
                    AreaMark(x: .value("", d), y: .value(p.series, p.y)).foregroundStyle(by: .value("Series", p.series)).opacity(0.25)
                }
            } else {
                LineMark(x: .value("", p.x), y: .value(p.series, p.y)).foregroundStyle(by: .value("Series", p.series))
            }
        }
        .chartLegend(seriesCount > 1 ? .visible : .hidden)
        .frame(height: display == "row" ? CGFloat(min(rows.count, 12)) * 26 + 20 : 180)
    }
}

struct MBPie: View {
    let result: MBResult
    let funnel: Bool
    var body: some View {
        let dim = result.dimension ?? 0
        let m = result.metrics.first ?? 1
        let slices = result.rows.compactMap { r -> (String, Double)? in
            guard r.indices.contains(m), let v = r[m].double else { return nil }
            return (r[dim].display, v)
        }.prefix(8)
        if funnel {
            Chart(Array(slices.enumerated()), id: \.offset) { _, s in
                BarMark(x: .value("Count", s.1), y: .value("Step", s.0)).foregroundStyle(Brand.metabase.gradient)
                    .annotation(position: .trailing) { Text(s.1.compact).font(.caption2).foregroundStyle(.secondary) }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(slices.count) * 30 + 10)
        } else {
            HStack(spacing: 16) {
                Chart(Array(slices.enumerated()), id: \.offset) { _, s in
                    SectorMark(angle: .value("Value", s.1), innerRadius: .ratio(0.55), angularInset: 1.5)
                        .foregroundStyle(by: .value("Slice", s.0))
                }
                .chartLegend(.hidden)
                .frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 4) {
                    let total = slices.map(\.1).reduce(0, +)
                    ForEach(Array(slices.enumerated()), id: \.offset) { _, s in
                        HStack {
                            Text(s.0).font(.caption).lineLimit(1)
                            Spacer()
                            Text(total > 0 ? String(format: "%.0f%%", s.1 / total * 100) : "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct MBScatter: View {
    let result: MBResult
    var body: some View {
        let nums = result.cols.indices.filter { result.cols[$0].isNumeric }
        if nums.count >= 2 {
            Chart(Array(result.rows.prefix(400).enumerated()), id: \.offset) { _, r in
                if let x = r[nums[0]].double, let y = r[nums[1]].double {
                    PointMark(x: .value(result.cols[nums[0]].name, x), y: .value(result.cols[nums[1]].name, y))
                        .foregroundStyle(Brand.metabase.opacity(0.6)).symbolSize(12)
                }
            }
            .frame(height: 180)
        } else {
            MBTable(result: result)
        }
    }
}

struct MBTable: View {
    let result: MBResult
    var body: some View {
        let cols = Array(result.cols.prefix(4).enumerated())
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                ForEach(cols, id: \.offset) { _, c in
                    Text(c.name).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                }
            }
            ForEach(Array(result.rows.prefix(6).enumerated()), id: \.offset) { _, r in
                HStack {
                    ForEach(cols, id: \.offset) { i, c in
                        let v = r.indices.contains(i) ? r[i] : .null
                        Text(c.isNumeric ? (v.double?.compact ?? "") : xLabel(v, temporal: c.isTemporal))
                            .font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if result.rows.count > 6 { Text("\(result.rows.count) rows").font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}
