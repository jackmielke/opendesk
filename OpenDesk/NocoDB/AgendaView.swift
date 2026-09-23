import SwiftUI

/// Calendar-first view of any table with a date column, modeled on the Radish Hub:
/// a KPI strip, a two-week date strip, and "party overview" cards grouped by day.
/// Works for NocoDB, Supabase and Airtable because it infers roles from column names and types.
struct AgendaRoles {
    let date: NocoColumn
    let title: NocoColumn?
    let who: NocoColumn?
    let count: NocoColumn?
    let place: NocoColumn?
    let money: NocoColumn?
    let status: NocoColumn?

    init?(model: TableModel) {
        let cols = model.visibleColumns
        func find(_ words: [String], _ types: Set<String>? = nil) -> NocoColumn? {
            cols.first { c in words.contains { c.title.lowercased().contains($0) } && (types?.contains(c.uidt) ?? true) }
        }
        let dates = cols.filter { ["Date", "DateTime"].contains($0.uidt) }
        guard let d = dates.first(where: { ["event", "date", "start", "when", "day"].contains(where: $0.title.lowercased().contains) }) ?? dates.first else { return nil }
        date = d
        title = model.primary
        who = find(["client", "customer", "company", "contact", "organization", "account", "host"], ["SingleLineText", "Email"]).flatMap { $0.id == model.primary?.id ? nil : $0 }
        count = find(["guest", "headcount", "attendee", "pax", "people", "covers", "count"], ["Number", "Decimal"])
        place = find(["venue", "location", "address", "city", "site", "room"], ["SingleLineText", "LongText"])
        money = cols.first { $0.uidt == "Currency" } ?? find(["budget", "price", "total", "amount", "revenue"], ["Number", "Decimal"])
        status = model.selectColumns.first { ["stage", "status", "state"].contains($0.title.lowercased()) } ?? model.selectColumns.first
    }
}

struct AgendaView: View {
    let model: TableModel
    let roles: AgendaRoles
    let open: (NocoRecord) -> Void
    @State private var upcoming = true
    @State private var focusDay: Date?

    private var cal: Calendar { .current }
    private var today: Date { cal.startOfDay(for: Date()) }

    private func day(_ r: NocoRecord) -> Date? { r[roles.date.title]?.string.flatMap(DateField.parse).map { cal.startOfDay(for: $0) } }

    private var dated: [(NocoRecord, Date)] {
        model.records.compactMap { r in day(r).map { (r, $0) } }
            .filter { upcoming ? $0.1 >= today : $0.1 < today }
            .sorted { upcoming ? $0.1 < $1.1 : $0.1 > $1.1 }
    }

    var body: some View {
        let items = dated
        let groups = Dictionary(grouping: items, by: \.1)
        let days = groups.keys.sorted(by: upcoming ? (<) : (>))
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    kpis(items)
                    if upcoming { dateStrip(groups) { d in withAnimation { proxy.scrollTo(d, anchor: .top) } } }
                    Picker("", selection: $upcoming) { Text("Upcoming").tag(true); Text("Past").tag(false) }
                        .pickerStyle(.segmented)
                    if days.isEmpty {
                        ContentUnavailableView(upcoming ? "Nothing coming up" : "Nothing in the past", systemImage: "calendar")
                            .padding(.top, 30)
                    }
                    ForEach(days, id: \.self) { d in
                        VStack(alignment: .leading, spacing: 8) {
                            dayHeader(d)
                            ForEach(Array((groups[d] ?? []).enumerated()), id: \.offset) { _, pair in
                                PartyCard(record: pair.0, roles: roles).onTapGesture { open(pair.0) }
                            }
                        }
                        .id(d)
                    }
                }
                .padding()
                .padding(.bottom, 80)
            }
        }
    }

    // MARK: Pieces

    private func kpis(_ items: [(NocoRecord, Date)]) -> some View {
        let window = items.filter { upcoming ? $0.1 <= cal.date(byAdding: .day, value: 30, to: today)! : true }
        let people = roles.count.map { c in window.compactMap { $0.0[c.title]?.double }.reduce(0, +) }
        let value = roles.money.map { c in window.compactMap { $0.0[c.title]?.double }.reduce(0, +) }
        let thisWeek = items.filter { $0.1 < cal.date(byAdding: .day, value: 7, to: today)! && $0.1 >= today }.count
        return VStack(alignment: .leading, spacing: 10) {
            Text(greeting).font(.title3.weight(.semibold))
            Text(upcoming ? (thisWeek == 0 ? "Nothing on the calendar this week." : "\(thisWeek) on the calendar this week.") : "Looking back.")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                kpi("\(window.count)", upcoming ? "next 30 days" : "total", "calendar")
                if let people { kpi(people.compact, roles.count!.title.lowercased(), "person.2.fill") }
                if let value { kpi(value.currency, roles.money!.title.lowercased(), "dollarsign.circle.fill") }
            }
        }
    }

    private var greeting: String {
        let h = cal.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    private func kpi(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(Brand.noco)
            Text(value).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 10)
    }

    private func dateStrip(_ groups: [Date: [(NocoRecord, Date)]], jump: @escaping (Date) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<21, id: \.self) { i in
                    let d = cal.date(byAdding: .day, value: i, to: today)!
                    let n = groups[d]?.count ?? 0
                    Button { if n > 0 { focusDay = d; jump(d) } } label: {
                        VStack(spacing: 4) {
                            Text(d.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                            Text(d.formatted(.dateTime.day())).font(.headline.monospacedDigit())
                            HStack(spacing: 2) {
                                ForEach(0..<min(n, 3), id: \.self) { _ in Circle().fill(Brand.noco).frame(width: 4, height: 4) }
                            }
                            .frame(height: 4)
                        }
                        .frame(width: 40, height: 62)
                        .background(i == 0 ? Brand.noco.opacity(0.25) : (focusDay == d ? Color.white.opacity(0.12) : Brand.card),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(n == 0 && i != 0 ? 0.5 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func dayHeader(_ d: Date) -> some View {
        let n = cal.dateComponents([.day], from: today, to: d).day ?? 0
        let rel = n == 0 ? "Today" : n == 1 ? "Tomorrow" : n > 0 ? "in \(n) days" : "\(-n) days ago"
        return HStack(alignment: .firstTextBaseline) {
            Text(d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).font(.subheadline.weight(.semibold))
            Text(rel).font(.caption).foregroundStyle(n >= 0 && n <= 7 ? Brand.noco : .secondary)
            Spacer()
        }
        .padding(.top, 4)
    }
}

/// The Hub's "party overview" card: status stripe, title, who, and a row of facts.
struct PartyCard: View {
    let record: NocoRecord
    let roles: AgendaRoles

    var body: some View {
        let status = roles.status.flatMap { c in record[c.title]?.string.map { (c, $0) } }
        let stripe = status.map { vivid($0.0.color(for: $0.1)) } ?? Brand.noco
        HStack(spacing: 0) {
            Rectangle().fill(stripe).frame(width: 4)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(roles.title.flatMap { record[$0.title]?.display } ?? "Untitled")
                            .font(.headline).lineLimit(2)
                        if let w = roles.who.flatMap({ record[$0.title]?.display }), !w.isEmpty {
                            Text(w).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if let (c, v) = status { Chip(text: v, color: vivid(c.color(for: v))) }
                }
                HStack(spacing: 14) {
                    if let c = roles.count, let n = record[c.title]?.double { fact("person.2", "\(Int(n))") }
                    if let c = roles.money, let v = record[c.title]?.double { fact("dollarsign.circle", v.currency) }
                    if let c = roles.place, let v = record[c.title]?.display, !v.isEmpty { fact("mappin.and.ellipse", v) }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Brand.stroke))
        .contentShape(Rectangle())
    }

    private func fact(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}
