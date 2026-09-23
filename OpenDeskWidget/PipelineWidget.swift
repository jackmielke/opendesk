import WidgetKit
import SwiftUI

struct PipelineEntry: TimelineEntry {
    let date: Date
    let openValue: Double
    let openCount: Int
    let byStage: [(String, Double)]
    let upcoming: [(String, Date, Int)]
    let error: String?

    static let placeholder = PipelineEntry(
        date: .now, openValue: 169_000, openCount: 28,
        byStage: [("Inquiry", 50_000), ("Proposal Sent", 36_000), ("Tasting", 43_000), ("Booked", 40_000)],
        upcoming: [("Northwind All-Hands", .now.addingTimeInterval(86400 * 3), 220), ("Haddad Offsite", .now.addingTimeInterval(86400 * 5), 40)],
        error: nil)
}

/// Reads the same bundled connection defaults as the app (no App Group needed for the demo).
struct PipelineProvider: TimelineProvider {
    static let stages = ["Inquiry", "Proposal Sent", "Tasting", "Booked"]

    func placeholder(in context: Context) -> PipelineEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (PipelineEntry) -> Void) {
        if context.isPreview { completion(.placeholder); return }
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PipelineEntry>) -> Void) {
        Task {
            let e = await load()
            completion(Timeline(entries: [e], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    private func load() async -> PipelineEntry {
        var url = "http://localhost:8080", token = ""
        if let u = Bundle.main.url(forResource: "LocalDefaults", withExtension: "plist"),
           let d = NSDictionary(contentsOf: u) as? [String: String] {
            url = d["nocoURL"] ?? url
            token = d["nocoToken"] ?? ""
        }
        let noco = NocoClient(baseURL: url, token: token)
        do {
            for b in try await noco.bases() {
                guard let t = try await noco.tables(baseId: b.id).first(where: { $0.title.lowercased() == "events" }) else { continue }
                let rows = try await noco.allRecords(tableId: t.id)
                let open = rows.filter { Self.stages.contains($0["Stage"]?.string ?? "") }
                let byStage = Self.stages.map { s in (s, open.filter { $0["Stage"]?.string == s }.compactMap { $0["Budget"]?.double }.reduce(0, +)) }
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                let today = Calendar.current.startOfDay(for: .now)
                let upcoming = rows.filter { $0["Stage"]?.string == "Booked" }
                    .compactMap { r -> (String, Date, Int)? in
                        guard let d = r["Date"]?.string.flatMap({ f.date(from: String($0.prefix(10))) }), d >= today else { return nil }
                        return (r["Event"]?.display ?? "", d, r["Guests"]?.int ?? 0)
                    }
                    .sorted { $0.1 < $1.1 }
                return PipelineEntry(date: .now, openValue: byStage.map(\.1).reduce(0, +), openCount: open.count,
                                     byStage: byStage, upcoming: Array(upcoming.prefix(3)), error: nil)
            }
            return PipelineEntry(date: .now, openValue: 0, openCount: 0, byStage: [], upcoming: [], error: "No Events table")
        } catch {
            return PipelineEntry(date: .now, openValue: 0, openCount: 0, byStage: [], upcoming: [], error: "NocoDB offline")
        }
    }
}

private let violet = Color(red: 0.49, green: 0.44, blue: 0.97)
private let stageColors: [Color] = [.blue, .yellow, .purple, .green]

private func money(_ v: Double) -> String {
    v >= 1_000_000 ? String(format: "$%.1fM", v / 1_000_000) : v >= 1_000 ? String(format: "$%.0fK", v / 1_000) : String(format: "$%.0f", v)
}

struct PipelineWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PipelineEntry

    var body: some View {
        switch family {
        case .accessoryRectangular: lockScreen
        case .systemMedium: medium
        default: small
        }
    }

    private var stageBar: some View {
        GeometryReader { geo in
            let total = max(entry.byStage.map(\.1).reduce(0, +), 1)
            HStack(spacing: 2) {
                ForEach(Array(entry.byStage.enumerated()), id: \.offset) { i, s in
                    RoundedRectangle(cornerRadius: 3).fill(stageColors[i % stageColors.count])
                        .frame(width: max(0, geo.size.width * s.1 / total - 2))
                }
            }
        }
        .frame(height: 8)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Pipeline", systemImage: "tablecells.fill").font(.caption2.weight(.semibold)).foregroundStyle(violet)
            Spacer(minLength: 0)
            if let e = entry.error {
                Text(e).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(money(entry.openValue)).font(.system(size: 34, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                Text("\(entry.openCount) open events").font(.caption2).foregroundStyle(.secondary)
                stageBar
            }
        }
    }

    private var medium: some View {
        HStack(spacing: 16) {
            small.frame(maxWidth: 130)
            VStack(alignment: .leading, spacing: 7) {
                Text("NEXT BOOKED").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                ForEach(Array(entry.upcoming.enumerated()), id: \.offset) { _, u in
                    HStack(spacing: 8) {
                        Text(u.1.formatted(.dateTime.month(.abbreviated).day())).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(violet)
                            .frame(width: 44, alignment: .leading)
                        Text(u.0).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(u.2)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if entry.upcoming.isEmpty { Text("Nothing booked").font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
        }
    }

    private var lockScreen: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(money(entry.openValue)) pipeline").font(.headline)
            if let u = entry.upcoming.first {
                Text("Next: \(u.0)").font(.caption).lineLimit(1)
                Text(u.1.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · \(u.2) guests").font(.caption2)
            }
        }
    }
}

struct PipelineWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PipelineWidget", provider: PipelineProvider()) { entry in
            PipelineWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(red: 0.06, green: 0.06, blue: 0.10) }
                .widgetURL(URL(string: "opendesk://tables"))
        }
        .configurationDisplayName("Sales pipeline")
        .description("Open pipeline value and your next booked events, live from NocoDB.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

@main
struct OpenDeskWidgets: WidgetBundle {
    var body: some Widget { PipelineWidget() }
}
