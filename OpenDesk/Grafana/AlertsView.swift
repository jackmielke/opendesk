import SwiftUI

/// On-call inbox: what's firing right now, most severe first, with an AI triage.
struct AlertsView: View {
    @Environment(AppConfig.self) private var config
    @State private var alerts: [GrafanaAlert] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var triage = false

    var body: some View {
        List {
            if let error { ErrorCard(message: error) { Task { await load() } }.listRowBackground(Color.clear) }
            if loaded {
                Section {
                    HStack(spacing: 20) {
                        count(alerts.filter(\.isFiring).count, "Firing", .red)
                        count(alerts.filter(\.isPending).count, "Pending", .orange)
                        Spacer()
                        Button { triage = true } label: { Label("Triage", systemImage: "sparkles") }
                            .buttonStyle(.borderedProminent).tint(Brand.ai.opacity(0.8))
                    }
                }
            }
            ForEach(alerts) { a in
                NavigationLink {
                    AlertDetail(alert: a)
                } label: { AlertRow(alert: a) }
            }
            if loaded && alerts.isEmpty && error == nil {
                ContentUnavailableView("All clear", systemImage: "checkmark.seal", description: Text("Nothing firing or pending."))
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .sheet(isPresented: $triage) {
            AskSheet(title: "Alert triage", accent: Brand.grafana,
                     suggestions: ["What should on-call look at first?", "Group these alerts by likely root cause", "Which teams are affected?"]) {
                alerts.prefix(40).map { a in
                    "- [\(a.isFiring ? "FIRING" : "PENDING")] \(a.name) sev=\(a.severity ?? "?") service=\(a.service ?? "?") team=\(a.team ?? "?") since \(relativeDate(a.activeAt)): \(a.summary ?? "")"
                }.joined(separator: "\n")
            }
        }
    }

    private func count(_ n: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading) {
            Text("\(n)").font(.title.bold()).foregroundStyle(color).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        do {
            alerts = try await config.grafana.activeAlerts()
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }
}

func severityColor(_ s: String?) -> Color {
    switch s?.lowercased() {
    case "critical", "high": .red
    case "warning", "medium": .orange
    case "info", "low": .blue
    default: .gray
    }
}

struct AlertRow: View {
    let alert: GrafanaAlert
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(alert.isFiring ? Color.red : .orange).frame(width: 9).padding(.top, 5)
                .shadow(color: alert.isFiring ? .red : .clear, radius: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    if let s = alert.severity { Chip(text: s, color: severityColor(s)) }
                    if let svc = alert.service { Text(svc).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Text(relativeDate(alert.activeAt)).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

struct AlertDetail: View {
    @Environment(AppConfig.self) private var config
    let alert: GrafanaAlert

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(alert.name).font(.title3.weight(.semibold))
                    HStack {
                        Chip(text: alert.isFiring ? "Firing" : "Pending", color: alert.isFiring ? .red : .orange)
                        if let s = alert.severity { Chip(text: s, color: severityColor(s)) }
                    }
                    Text("Active since \(relativeDate(alert.activeAt))").font(.caption).foregroundStyle(.secondary)
                    if let s = alert.summary { Text(s).font(.subheadline) }
                }
            }
            if let uid = alert.dashboardUID {
                Section {
                    NavigationLink {
                        DashboardScreen(ref: GrafanaDashRef(json: .object(["uid": .string(uid), "title": .string(alert.name)])))
                    } label: { Label("Open linked dashboard", systemImage: "chart.xyaxis.line") }
                }
            }
            Section("Labels") {
                ForEach(alert.labels.sorted { $0.key < $1.key }, id: \.key) { k, v in
                    LabeledContent(k, value: v).font(.caption)
                }
            }
        }
        .navigationTitle("Alert")
        .navigationBarTitleDisplayMode(.inline)
    }
}
