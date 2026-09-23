import SwiftUI
import Charts

// MARK: - Bases

struct NocoHomeView: View {
    @Environment(AppConfig.self) private var config
    @State private var bases: [NocoBase] = []
    @State private var tables: [String: [NocoTable]] = [:]
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    ErrorCard(message: error) { Task { await load() } }
                        .listRowBackground(Color.clear)
                }
                ForEach(bases) { base in
                    Section {
                        ForEach(tables[base.id] ?? []) { t in
                            NavigationLink(value: t) {
                                Label(t.title, systemImage: "tablecells")
                            }
                        }
                        if tables[base.id]?.isEmpty ?? true {
                            Text("No tables").foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack {
                            Circle().fill(base.colorHex.map(Color.init(hex:)) ?? Brand.noco).frame(width: 8)
                            Text(base.title)
                        }
                    }
                }
            }
            .overlay { if loading && bases.isEmpty { ProgressView() } }
            .navigationTitle("Tables")
            .navigationDestination(for: NocoTable.self) { TableScreen(table: $0) }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let noco = config.noco
            let b = try await noco.bases()
            var t: [String: [NocoTable]] = [:]
            try await withThrowingTaskGroup(of: (String, [NocoTable]).self) { group in
                for base in b { group.addTask { (base.id, try await noco.tables(baseId: base.id)) } }
                for try await (id, list) in group { t[id] = list }
            }
            // Bases with data first; NocoDB's empty "Getting Started" base sinks.
            bases = b.sorted { (t[$0.id]?.count ?? 0) > (t[$1.id]?.count ?? 0) }
            tables = t
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Table model

@Observable
final class TableModel {
    let table: NocoTable
    var columns: [NocoColumn] = []
    var records: [NocoRecord] = []
    var total = 0
    var error: String?
    var loading = false

    init(table: NocoTable) { self.table = table }

    var visibleColumns: [NocoColumn] { columns.filter(\.isVisible) }
    var primary: NocoColumn? { columns.first(where: \.isPrimary) ?? visibleColumns.first }
    var selectColumns: [NocoColumn] { columns.filter(\.isSelect) }
    var numericColumns: [NocoColumn] { visibleColumns.filter { $0.isNumeric && $0.uidt != "Rating" } }

    func load(_ client: NocoClient) async {
        loading = true
        defer { loading = false }
        do {
            async let cols = client.columns(tableId: table.id)
            async let rows = client.allRecords(tableId: table.id)
            columns = try await cols
            records = try await rows
            total = records.count
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func set(_ id: Int, _ column: String, _ value: JSONValue, client: NocoClient) async {
        guard let i = records.firstIndex(where: { $0.recordId == id }) else { return }
        let old = records[i][column]
        records[i][column] = value
        do {
            try await client.update(tableId: table.id, id: id, fields: [column: value])
        } catch {
            records[i][column] = old
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Table screen

struct TableScreen: View {
    @Environment(AppConfig.self) private var config
    @State private var model: TableModel
    @State private var mode: Mode = .list
    @State private var search = ""
    @State private var groupBy: String?
    @State private var editing: NocoRecord?
    @State private var creating = false
    @State private var askAI = false

    enum Mode: String, CaseIterable { case list = "List", board = "Board", insights = "Insights" }

    init(table: NocoTable) { _model = State(initialValue: TableModel(table: table)) }

    private var filtered: [NocoRecord] {
        guard !search.isEmpty else { return model.records }
        let q = search.lowercased()
        return model.records.filter { r in r.values.contains { $0.display.lowercased().contains(q) } }
    }

    private var groupColumn: NocoColumn? {
        model.selectColumns.first { $0.title == groupBy }
            ?? model.selectColumns.first { ["stage", "status"].contains($0.title.lowercased()) }
            ?? model.selectColumns.first
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(availableModes, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.bottom, 8)

            if let error = model.error {
                ErrorCard(message: error) { Task { await model.load(config.noco) } }.padding(.horizontal)
            }

            switch mode {
            case .list: listView
            case .board: boardView
            case .insights: InsightsView(model: model, groupColumn: groupColumn)
            }
        }
        .navigationTitle(model.table.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if mode == .board, model.selectColumns.count > 1 {
                    Menu {
                        ForEach(model.selectColumns) { c in
                            Button(c.title) { groupBy = c.title }
                        }
                    } label: { Image(systemName: "square.split.3x1") }
                }
                Button { askAI = true } label: { Image(systemName: "sparkles") }
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .overlay { if model.loading && model.records.isEmpty { ProgressView() } }
        .task { if model.columns.isEmpty { await model.load(config.noco) } }
        .refreshable { await model.load(config.noco) }
        .sheet(item: Binding(get: { editing.map(IdentifiedRecord.init) }, set: { editing = $0?.record })) { item in
            RecordEditor(model: model, record: item.record)
        }
        .sheet(isPresented: $creating) { RecordEditor(model: model, record: nil) }
        .sheet(isPresented: $askAI) {
            AskSheet(title: "Ask \(model.table.title)", accent: Brand.noco, suggestions: suggestions) {
                TableContext.describe(model: model, budget: AI.contextBudget(config))
            }
        }
    }

    private var availableModes: [Mode] {
        model.selectColumns.isEmpty ? [.list, .insights] : Mode.allCases
    }

    private var suggestions: [String] {
        switch model.table.title.lowercased() {
        case "events": return ["What needs follow-up this week?", "Which booked events are the biggest?", "Summarize the pipeline by stage"]
        case "clients": return ["Who are our most valuable clients?", "Which clients have notes I should know about?"]
        case "staff": return ["Who is available to captain?", "Summarize the team by role"]
        default: return ["Summarize this table", "What stands out?"]
        }
    }

    // MARK: List

    private var listView: some View {
        List {
            Section {
                ForEach(filtered, id: \.recordId) { r in
                    Button { editing = r } label: { RecordRow(model: model, record: r) }
                        .swipeActions(edge: .leading) { quickActions(r) }
                }
            } footer: {
                Text("\(filtered.count) of \(model.total) rows").font(.caption)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func quickActions(_ r: NocoRecord) -> some View {
        if let phone = model.columns.first(where: { $0.uidt == "PhoneNumber" }).flatMap({ r[$0.title]?.string }),
           let url = URL(string: "tel:" + phone.filter { $0.isNumber }) {
            Link(destination: url) { Label("Call", systemImage: "phone.fill") }.tint(.green)
        }
        if let email = model.columns.first(where: { $0.uidt == "Email" }).flatMap({ r[$0.title]?.string }),
           let url = URL(string: "mailto:" + email) {
            Link(destination: url) { Label("Email", systemImage: "envelope.fill") }.tint(.blue)
        }
    }

    // MARK: Board

    private var boardView: some View {
        let col = groupColumn
        let lanes = (col?.options.map(\.title) ?? []) + ["—"]
        return ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(lanes, id: \.self) { lane in
                    let items = filtered.filter { r in
                        let v = col.flatMap { r[$0.title] } ?? .null
                        return lane == "—" ? v.isNull : v.string == lane
                    }
                    if lane != "—" || !items.isEmpty {
                        BoardLane(model: model, column: col, lane: lane, items: items) { editing = $0 }
                    }
                }
            }
            .padding(.horizontal)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
    }
}

struct IdentifiedRecord: Identifiable {
    let record: NocoRecord
    var id: Int { record.recordId }
}

struct BoardLane: View {
    @Environment(AppConfig.self) private var config
    let model: TableModel
    let column: NocoColumn?
    let lane: String
    let items: [NocoRecord]
    let open: (NocoRecord) -> Void
    @State private var targeted = false

    var body: some View {
        let color = vivid(column?.color(for: lane))
        let sum = model.numericColumns.first(where: { $0.uidt == "Currency" }).map { c in items.compactMap { $0[c.title]?.double }.reduce(0, +) }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(color).frame(width: 8)
                Text(lane).font(.subheadline.weight(.semibold))
                Text("\(items.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let sum, sum > 0 { Text(sum.currency).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items, id: \.recordId) { r in
                        RecordCard(model: model, record: r, hide: column?.title)
                            .onTapGesture { open(r) }
                            .draggable(String(r.recordId))
                    }
                }
                .padding(.bottom, 80)
            }
        }
        .padding(10)
        .frame(width: 290)
        .background(targeted ? color.opacity(0.15) : Brand.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(targeted ? color : Brand.stroke))
        .dropDestination(for: String.self) { ids, _ in
            guard let column, lane != "—", let id = ids.first.flatMap(Int.init) else { return false }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await model.set(id, column.title, .string(lane), client: config.noco) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

// MARK: - Rows & cards

struct RecordRow: View {
    let model: TableModel
    let record: NocoRecord

    var body: some View {
        let title = model.primary.flatMap { record[$0.title]?.display } ?? "#\(record.recordId)"
        let rest = model.visibleColumns.filter { $0.id != model.primary?.id && !$0.isSelect && $0.uidt != "LongText" && !(record[$0.title]?.isNull ?? true) }.prefix(2)
        let selects = model.selectColumns.prefix(2)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.isEmpty ? "Untitled" : title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(rest.map { FieldText.format($0, record[$0.title]) }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(selects)) { c in
                    if let v = record[c.title]?.string, !v.isEmpty { Chip(text: v, color: vivid(c.color(for: v))) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct RecordCard: View {
    let model: TableModel
    let record: NocoRecord
    var hide: String?

    var body: some View {
        let title = model.primary.flatMap { record[$0.title]?.display } ?? "#\(record.recordId)"
        let fields = model.visibleColumns.filter { $0.id != model.primary?.id && $0.title != hide && $0.uidt != "LongText" && !(record[$0.title]?.isNull ?? true) }.prefix(4)
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
            ForEach(Array(fields)) { c in
                HStack(spacing: 6) {
                    Image(systemName: c.icon).font(.caption2).foregroundStyle(.tertiary).frame(width: 14)
                    if c.isSelect, let v = record[c.title]?.string {
                        Chip(text: v, color: vivid(c.color(for: v)))
                    } else {
                        Text(FieldText.format(c, record[c.title])).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 12))
    }
}

enum FieldText {
    static func format(_ c: NocoColumn, _ v: JSONValue?) -> String {
        guard let v, !v.isNull else { return "" }
        switch c.uidt {
        case "Currency": return v.double.map { "$" + $0.formatted(.number.precision(.fractionLength(0))) } ?? v.display
        case "Checkbox": return v.bool ? "✓ \(c.title)" : "✗ \(c.title)"
        case "Rating": return String(repeating: "★", count: v.int ?? 0)
        case "Date":
            if let s = v.string, let d = DateField.parse(s) { return d.formatted(.dateTime.month(.abbreviated).day().year()) }
            return v.display
        case "Number": return (v.int.map(String.init) ?? v.display) + (c.title.lowercased().contains("guest") ? " guests" : "")
        default: return v.display
        }
    }
}

enum DateField {
    static let f: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
    static func parse(_ s: String) -> Date? { f.date(from: String(s.prefix(10))) }
    static func string(_ d: Date) -> String { f.string(from: d) }
}

// MARK: - Insights

struct InsightsView: View {
    let model: TableModel
    let groupColumn: NocoColumn?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    stat("Rows", Double(model.records.count).compact, "tablecells")
                    ForEach(model.numericColumns.prefix(3)) { c in
                        let values = model.records.compactMap { $0[c.title]?.double }
                        let total = values.reduce(0, +)
                        stat(c.uidt == "Currency" ? "Total \(c.title)" : "Avg \(c.title)",
                             c.uidt == "Currency" ? total.currency : (values.isEmpty ? "–" : (total / Double(values.count)).compact),
                             c.icon)
                    }
                }
                ForEach(model.selectColumns) { sc in
                    chart(for: sc)
                }
                if let dateCol = model.columns.first(where: { $0.uidt == "Date" }) {
                    timeline(dateCol)
                }
            }
            .padding()
        }
    }

    private func stat(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title2.weight(.bold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private func chart(for sc: NocoColumn) -> some View {
        let money = model.numericColumns.first { $0.uidt == "Currency" }
        let rows: [(String, Double, Int)] = sc.options.map { o in
            let hits = model.records.filter { $0[sc.title]?.string == o.title }
            let sum = money.map { m in hits.compactMap { $0[m.title]?.double }.reduce(0, +) } ?? 0
            return (o.title, sum, hits.count)
        }
        VStack(alignment: .leading, spacing: 10) {
            Text(money != nil ? "\(money!.title) by \(sc.title)" : "Rows by \(sc.title)").font(.headline)
            Chart(rows, id: \.0) { row in
                BarMark(x: .value("Value", money != nil ? row.1 : Double(row.2)), y: .value(sc.title, row.0))
                    .foregroundStyle(vivid(sc.color(for: row.0)))
                    .annotation(position: .trailing) {
                        Text(money != nil ? row.1.currency : "\(row.2)").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXAxis(.hidden)
            .frame(height: CGFloat(max(rows.count, 1)) * 34)
        }
        .card()
    }

    @ViewBuilder
    private func timeline(_ dc: NocoColumn) -> some View {
        let points: [(Date, Int)] = Dictionary(grouping: model.records.compactMap { r -> Date? in
            r[dc.title]?.string.flatMap(DateField.parse)
        }) { Calendar.current.dateInterval(of: .weekOfYear, for: $0)?.start ?? $0 }
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0 < $1.0 }
        if !points.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(model.table.title) per week").font(.headline)
                Chart(points, id: \.0) { p in
                    BarMark(x: .value("Week", p.0, unit: .weekOfYear), y: .value("Count", p.1))
                        .foregroundStyle(Brand.noco.gradient)
                    RuleMark(x: .value("Today", Date())).foregroundStyle(.white.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                }
                .frame(height: 160)
            }
            .card()
        }
    }
}
