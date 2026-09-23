import AppIntents
import Foundation

/// Siri and Shortcuts: ask the self-hosted stack a question without opening the app.
struct NextBookedIntent: AppIntent {
    static let title: LocalizedStringResource = "What's booked next"
    static let description = IntentDescription("Reads your next booked events from NocoDB.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rows = try await EventsLookup.rows()
        let today = DateField.string(Date())
        let next = rows
            .filter { $0["Stage"]?.string == "Booked" && ($0["Date"]?.string ?? "") >= today }
            .sorted { ($0["Date"]?.string ?? "") < ($1["Date"]?.string ?? "") }
            .prefix(3)
        guard !next.isEmpty else { return .result(dialog: "Nothing booked coming up.") }
        let lines = next.map { r -> String in
            let d = r["Date"]?.string.flatMap(DateField.parse)?.formatted(.dateTime.weekday(.wide).month(.wide).day()) ?? ""
            return "\(r["Event"]?.display ?? "An event") on \(d), \(r["Guests"]?.int ?? 0) guests"
        }
        return .result(dialog: "Next up: \(lines.joined(separator: ". Then "))." )
    }
}

struct PipelineIntent: AppIntent {
    static let title: LocalizedStringResource = "Pipeline value"
    static let description = IntentDescription("Totals open deals by stage from NocoDB.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let rows = try await EventsLookup.rows()
        let stages = ["Inquiry", "Proposal Sent", "Tasting", "Booked"]
        let open = rows.filter { stages.contains($0["Stage"]?.string ?? "") }
        let total = open.compactMap { $0["Budget"]?.double }.reduce(0, +)
        let booked = open.filter { $0["Stage"]?.string == "Booked" }.compactMap { $0["Budget"]?.double }.reduce(0, +)
        return .result(dialog: "You have \(total.currency) open across \(open.count) events, \(booked.currency) of it booked.")
    }
}

struct FiringAlertsIntent: AppIntent {
    static let title: LocalizedStringResource = "Firing alerts"
    static let description = IntentDescription("Summarizes what's firing in Grafana.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let alerts = try await AppConfig().grafana.activeAlerts().filter(\.isFiring)
        guard let top = alerts.first else { return .result(dialog: "All clear. Nothing is firing.") }
        let critical = alerts.filter { $0.severity?.lowercased() == "critical" }.count
        return .result(dialog: "\(alerts.count) alerts firing, \(critical) critical. Top one: \(top.name)\(top.service.map { " on \($0)" } ?? "").")
    }
}

enum EventsLookup {
    static func rows() async throws -> [NocoRecord] {
        let noco = AppConfig().noco
        for b in try await noco.bases() {
            if let t = try await noco.tables(baseId: b.id).first(where: { $0.title.lowercased() == "events" }) {
                return try await noco.allRecords(tableId: t.id)
            }
        }
        return []
    }
}

struct OpenDeskShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextBookedIntent(), phrases: [
            "What's booked next in \(.applicationName)",
            "Next event in \(.applicationName)",
        ], shortTitle: "Next booked", systemImageName: "calendar")
        AppShortcut(intent: PipelineIntent(), phrases: [
            "How's the pipeline in \(.applicationName)",
            "Pipeline value in \(.applicationName)",
        ], shortTitle: "Pipeline", systemImageName: "dollarsign.circle")
        AppShortcut(intent: FiringAlertsIntent(), phrases: [
            "What's firing in \(.applicationName)",
            "Check alerts in \(.applicationName)",
        ], shortTitle: "Firing alerts", systemImageName: "bell.badge")
    }
}
