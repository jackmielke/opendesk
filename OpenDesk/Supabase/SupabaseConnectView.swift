import SwiftUI

extension Brand {
    static let supabase = Color(red: 0.24, green: 0.81, blue: 0.56)
}

struct SupabaseConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var app = SupabaseApp.shared
    @State private var mode: Mode = .admin
    @State private var token = ""
    @State private var projects: [SupabaseApp.Project] = []
    @State private var email = ""
    @State private var password = ""
    @State private var busy: String?
    @State private var error: String?
    @State private var copied = false

    enum Mode: String, CaseIterable { case admin = "I own the project", member = "I use the app" }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        BrandMark(kind: .supabase, size: 40)
                        Text("Connect Supabase").font(.title2.bold())
                        Text(connected ? "Connected to \(app.projectRef). \(app.tables.count) tables are in the Tables tab." :
                             "See your Supabase tables as boards, charts and editable records.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    if !connected {
                        Picker("", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                            .pickerStyle(.segmented)
                    }
                }

                if connected {
                    Section {
                        LabeledContent("Project", value: app.projectRef)
                        LabeledContent("Access", value: app.isAdmin ? "Owner (bypasses RLS)" : (app.session?.email ?? ""))
                        Button("Refresh tables") { Task { await run("refresh") { try await app.loadSchema() } } }
                        Button("Disconnect", role: .destructive) { app.disconnectAdmin(); app.signOut() }
                    }
                } else if mode == .admin {
                    adminFlow
                } else {
                    memberFlow
                }

                if let error { Section { Text(error).foregroundStyle(.orange).font(.footnote) } }

                if app.needsHelper && !connected {
                    Section {
                        Text(SupabaseApp.helperSQL).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy SQL") { UIPasteboard.general.string = SupabaseApp.helperSQL; copied = true }
                    } header: { Text("One-time setup by the project owner") } footer: {
                        Text("Read-only helper that lists tables the signed-in user can already read. Grants no new access.")
                    }
                }
            }
            .navigationTitle("Supabase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .animation(.default, value: projects)
        }
    }

    private var connected: Bool { !app.tables.isEmpty && (app.isAdmin || app.session != nil) }

    @ViewBuilder private var adminFlow: some View {
        if projects.isEmpty {
            Section {
                SecureField("sbp_…", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button { Task { await listProjects() } } label: {
                    HStack { Text("Continue"); Spacer(); if busy == "projects" { ProgressView() } }
                }
                .disabled(!token.hasPrefix("sbp_") || busy != nil)
            } header: { Text("1 · Access token") } footer: {
                Text("Works however you sign in to Supabase, GitHub included. In the dashboard: Account → Access Tokens → Generate new token. It's stored in this iPhone's Keychain.")
            }
        } else {
            Section {
                ForEach(projects) { p in
                    Button { Task { await run(p.id) { try await app.use(p) } } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).foregroundStyle(.primary)
                                Text("\(p.region) · \(p.status.replacingOccurrences(of: "_", with: " ").lowercased())").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if busy == p.id { ProgressView() }
                        }
                    }
                    .disabled(busy != nil || !p.status.hasPrefix("ACTIVE"))
                }
            } header: { Text("2 · Pick a project") } footer: {
                Text("Owner access sees every row. For teammates, use “I use the app” so your row-level security applies.")
            }
        }
    }

    @ViewBuilder private var memberFlow: some View {
        @Bindable var app = app
        Section {
            TextField("you@company.com", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
            SecureField("Password", text: $password).textContentType(.password)
        } header: { Text("Your app account") }
        Section {
            TextField("https://xyz.supabase.co", text: $app.url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Publishable key", text: $app.key).textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption.monospaced())
            Button { Task { await run("signin") { try await app.signIn(email: email, password: password); password = ""; try await app.loadSchema() } } } label: {
                HStack { Text("Sign in"); Spacer(); if busy == "signin" { ProgressView() } }
            }
            .disabled(busy != nil || email.isEmpty || password.isEmpty || !app.isConfigured)
        } header: { Text("Which app") } footer: {
            Text("Your admin can share these, or send you an OpenDesk team invite that fills them in.")
        }
    }

    private func listProjects() async {
        app.accessToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        await run("projects") {
            projects = try await app.projects().sorted { $0.status.hasPrefix("ACTIVE") && !$1.status.hasPrefix("ACTIVE") }
            if projects.isEmpty { throw APIError.status(0, "No projects on this account.") }
        }
        if projects.isEmpty { app.accessToken = "" }
    }

    private func run(_ tag: String, _ f: () async throws -> Void) async {
        busy = tag
        defer { busy = nil }
        do { try await f(); error = nil } catch {
            if case APIError.status(401, _) = error { self.error = "Supabase didn't accept that token." }
            else { self.error = error.localizedDescription }
        }
    }
}
