import SwiftUI
import CoreImage.CIFilterBuiltins

/// Sign in, create or join a team, and (for admins) manage members and the team's shared connections.
struct TeamView: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    @State private var store = TeamStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if !store.isSignedIn { SignInForm(store: store) }
                else if let team = store.current { TeamDetail(store: store, team: team) }
                else { CreateOrJoin(store: store) }
            }
            .navigationTitle(store.current?.name ?? "Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { if store.isSignedIn { await store.refreshTeams() } }
        }
    }
}

private struct SignInForm: View {
    let store: TeamStore
    @State private var email = ""
    @State private var code = ""
    @State private var password = ""
    @State private var usePassword = false
    @State private var sent = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "person.2.circle.fill").font(.system(size: 44)).foregroundStyle(Brand.ai)
                    Text("Work as a team").font(.title2.bold())
                    Text("Sign in to join your team. Admins set up the tools once, and everyone who joins gets the same app, with the same data.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section {
                TextField("you@company.com", text: $email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.emailAddress)
                if usePassword {
                    SecureField("Password", text: $password).textContentType(.password)
                    Button("Sign in") { Task { await go() } }.disabled(busy || email.isEmpty || password.isEmpty)
                } else {
                    if sent {
                        TextField("6-digit code", text: $code).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    }
                    Button(sent ? "Sign in" : "Email me a sign-in link") { Task { await go() } }
                        .disabled(busy || email.isEmpty || (sent && code.count < 6))
                }
                Button(usePassword ? "Use an email link instead" : "Use a password instead") { usePassword.toggle() }
                    .font(.footnote)
            } footer: {
                if sent { Text("Check \(email). Tap the link on this iPhone, or type the code if your email has one.") }
                if let error { Text(error).foregroundStyle(.orange) }
            }
            if let invite = store.pendingInvite {
                Section { Label("You'll join team \(invite) after signing in", systemImage: "envelope.open.fill") }
            }
        }
    }

    private func go() async {
        busy = true
        defer { busy = false }
        do {
            if usePassword { try await store.signIn(email: email, password: password) }
            else if sent { try await store.verify(email: email, code: code) } else { try await store.sendCode(to: email); sent = true }
            error = nil
            if store.isSignedIn, let invite = store.pendingInvite { try await store.join(code: invite) }
        } catch { self.error = error.localizedDescription }
    }
}

private struct CreateOrJoin: View {
    @Environment(AppConfig.self) private var config
    let store: TeamStore
    @State private var name = ""
    @State private var code = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Team name", text: $name)
                Button("Create team") { Task { await run { try await store.createTeam(name: name); try await store.publish(config, to: store.current!) } } }
                    .disabled(name.isEmpty)
            } header: { Text("Start a team") } footer: { Text("You'll be the admin. Your current connections become the team's setup.") }
            Section {
                TextField("Invite code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("Join team") { Task { await run { try await store.join(code: code); await store.pull(into: config) } } }
                    .disabled(code.count < 4)
            } header: { Text("Join a team") }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
            Section { Button("Sign out", role: .destructive) { store.signOut() } } footer: { Text(store.session?.email ?? "") }
        }
    }

    private func run(_ f: () async throws -> Void) async {
        do { try await f(); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct TeamDetail: View {
    @Environment(AppConfig.self) private var config
    let store: TeamStore
    let team: Team
    @State private var members: [Member] = []
    @State private var status: String?

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    if let img = qr("opendesk://join?code=\(team.inviteCode)") {
                        Image(uiImage: img).interpolation(.none).resizable().frame(width: 96, height: 96)
                            .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Invite code").font(.caption).foregroundStyle(.secondary)
                        Text(team.inviteCode).font(.system(.title, design: .monospaced).bold())
                        ShareLink(item: URL(string: "opendesk://join?code=\(team.inviteCode)")!,
                                  message: Text("Join \(team.name) on OpenDesk with code \(team.inviteCode)")) {
                            Label("Invite", systemImage: "square.and.arrow.up")
                        }
                        .font(.subheadline)
                    }
                }
            } footer: { Text("Teammates scan this with the iPhone Camera, or enter the code in Team → Join.") }

            Section {
                if team.isAdmin {
                    Button { Task { await act("Published to \(team.name)") { try await store.publish(config, to: team) } } } label: {
                        Label("Publish my connections to the team", systemImage: "arrow.up.circle.fill")
                    }
                }
                Button { Task { await act("Using \(team.name)'s setup") { if !(await store.pull(into: config)) { throw APIError.status(0, "Your admin hasn't published a setup yet") } } } } label: {
                    Label("Use the team's connections", systemImage: "arrow.down.circle.fill")
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Shared setup") } footer: {
                Text(team.isAdmin ? "Everyone on the team gets these NocoDB, Grafana, Metabase and GitLab connections when they open the app." : "Your admin manages the tools this team uses.")
            }

            Section("Members · \(members.count)") {
                ForEach(members) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.email.isEmpty ? "Teammate" : m.email)
                            if m.userId == store.session?.userId { Text("You").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Chip(text: m.role.capitalized, color: m.role == "admin" ? Brand.ai : .secondary)
                    }
                    .swipeActions {
                        if team.isAdmin && m.userId != store.session?.userId {
                            Button("Remove", role: .destructive) { Task { await act("Removed") { try await store.remove(m, from: team) } } }
                            Button(m.role == "admin" ? "Make member" : "Make admin") {
                                Task { await act("Updated") { try await store.setRole(m.role == "admin" ? "member" : "admin", for: m, in: team) } }
                            }
                            .tint(.indigo)
                        }
                    }
                }
            }

            if store.teams.count > 1 {
                Section("Switch team") {
                    ForEach(store.teams) { t in
                        Button { store.currentId = t.id } label: {
                            HStack { Text(t.name); Spacer(); if t.id == team.id { Image(systemName: "checkmark") } }
                        }
                    }
                }
            }

            Section {
                if !team.isAdmin {
                    Button("Leave team", role: .destructive) {
                        Task { if let me = members.first(where: { $0.userId == store.session?.userId }) { await act("Left") { try await store.remove(me, from: team) } } }
                    }
                }
                Button("Sign out", role: .destructive) { store.signOut() }
            } footer: { Text("Signed in as \(store.session?.email ?? "")") }
        }
        .task(id: team.id) { await load() }
        .refreshable { await load() }
    }

    /// Keeps the last good list: a refresh of the teams list can cancel this request mid-flight.
    private func load() async {
        for attempt in 0..<3 {
            if let m = try? await store.members(of: team), !m.isEmpty { members = m; return }
            try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
        }
    }

    private func act(_ ok: String, _ f: () async throws -> Void) async {
        do { try await f(); status = ok; await load() } catch { status = error.localizedDescription }
    }

    private func qr(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
