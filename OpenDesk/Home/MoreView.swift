import SwiftUI

/// Profile, team, connections, imports and the extra tools, all in one place.
struct MoreView: View {
    @Environment(AppConfig.self) private var config
    @State private var team = TeamStore.shared
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable {
        case team, supabase, airtable, noco, settings, importData, share, code, whiteboard
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                // Account
                Section {
                    Button { sheet = .team } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle().fill(Brand.ai.opacity(0.2))
                                Text(initials).font(.headline).foregroundStyle(Brand.ai)
                            }
                            .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(team.session?.email ?? "Not signed in").font(.headline).foregroundStyle(.primary)
                                Text(teamLine).font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    if team.isSignedIn, let t = team.current {
                        Button { sheet = .team } label: {
                            Label(t.isAdmin ? "Members and roles" : "Team members", systemImage: "person.2")
                        }
                        Button { sheet = .team } label: {
                            Label("Invite with code \(t.inviteCode)", systemImage: "qrcode")
                        }
                    }
                }

                // Connections
                Section("Connections") {
                    connection(.noco, config.nocoToken.isEmpty ? "Not connected" : host(config.nocoURL)) { sheet = .noco }
                    connection(.supabase, SupabaseApp.shared.isAdmin || SupabaseApp.shared.session != nil ? SupabaseApp.shared.projectRef : "Not connected") { sheet = .supabase }
                    connection(.airtable, AirtableStore.shared.isConnected ? "\(AirtableStore.shared.bases.count) bases" : "Not connected") { sheet = .airtable }
                    connection(.grafana, host(config.grafanaURL)) { sheet = .settings }
                    connection(.metabase, config.metabaseKey.isEmpty ? "Not connected" : host(config.metabaseURL)) { sheet = .settings }
                    connection(.gitlab, host(config.gitlabURL)) { sheet = .settings }
                }

                // Data
                Section("Your data") {
                    Button { sheet = .importData } label: { Label("Import a spreadsheet or Airtable base", systemImage: "square.and.arrow.down") }
                    Button { sheet = .share } label: { Label("Share this setup by QR code", systemImage: "qrcode.viewfinder") }
                }

                // Tools
                Section("More tools") {
                    Button { sheet = .code } label: { tool(.gitlab, "Code", "Merge requests, issues and pipelines") }
                    Button { sheet = .whiteboard } label: { tool(.excalidraw, "Whiteboard", "Boards drawn from your data") }
                }

                // App
                Section("App") {
                    Button { sheet = .settings } label: { Label("AI and connection settings", systemImage: "gearshape") }
                    LabeledContent { Text(AI.engine(config) == .onDevice ? AI.onDeviceStatus : "Claude") } label: {
                        Label("AI engine", systemImage: "sparkles")
                    }
                    Link(destination: URL(string: "https://opendesk-app.vercel.app")!) { Label("Website", systemImage: "globe") }
                    Link(destination: URL(string: "https://github.com/jackmielke/opendesk")!) { Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                }

                if team.isSignedIn {
                    Section {
                        Button("Sign out", role: .destructive) { team.signOut() }
                    } footer: {
                        Text("OpenDesk \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                    }
                }
            }
            .navigationTitle("More")
            .task { if team.isSignedIn { await team.refreshTeams() } }
            .sheet(item: $sheet) { s in
                switch s {
                case .team: TeamView()
                case .supabase: SupabaseConnectView()
                case .airtable: AirtableConnectView()
                case .noco: NocoConnectView()
                case .settings: SettingsView()
                case .importData: BringDataView()
                case .share: ShareSetupView()
                case .code: GitLabHomeView().tint(Brand.gitlab)
                case .whiteboard: WhiteboardHomeView().tint(Brand.excalidraw)
                }
            }
        }
    }

    private var initials: String {
        guard let e = team.session?.email else { return "?" }
        return String(e.prefix(2)).uppercased()
    }

    private var teamLine: String {
        guard team.isSignedIn else { return "Sign in to join your team" }
        guard let t = team.current else { return "No team yet · create or join one" }
        return "\(t.name) · \(t.isAdmin ? "Admin" : "Member")"
    }

    private func host(_ s: String) -> String { URL(string: s)?.host ?? s }

    private func connection(_ i: Integration, _ detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                BrandMark(kind: i, size: 22).frame(width: 28)
                Text(i.name).foregroundStyle(.primary)
                Spacer()
                Text(detail).font(.caption).foregroundStyle(detail == "Not connected" ? i.color : .secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func tool(_ i: Integration, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 12) {
            BrandMark(kind: i, size: 22).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(.primary)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Just the NocoDB connection, without the import and team steps.
struct NocoConnectView: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        @Bindable var config = config
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        BrandMark(kind: .noco, size: 36)
                        Text("Connect NocoDB").font(.title2.bold())
                        Text("Your bases show up in Tables as agendas, grids and boards.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    TextField("https://nocodb.yourcompany.com", text: $config.nocoURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API token", text: $config.nocoToken)
                    Button { Task { await check() } } label: {
                        HStack { Text("Connect"); Spacer(); if busy { ProgressView() } else if let status { Text(status).font(.caption).foregroundStyle(.secondary) } }
                    }
                    .disabled(config.nocoToken.isEmpty || busy)
                } footer: { Text("In NocoDB: Team & Settings → Tokens → Create token. NocoDB Cloud works too: https://app.nocodb.com") }
            }
            .navigationTitle("NocoDB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func check() async {
        busy = true
        defer { busy = false }
        ResponseCache.clear()
        do {
            let b = try await config.noco.bases()
            status = "Connected · \(b.count) bases"
            config.onboarded = true
        } catch { status = "Can't connect: \(error.localizedDescription)" }
    }
}
