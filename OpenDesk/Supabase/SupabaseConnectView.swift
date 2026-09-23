import SwiftUI

extension Brand {
    static let supabase = Color(red: 0.24, green: 0.81, blue: 0.56)
}

struct SupabaseConnectView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var app = SupabaseApp.shared
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 40)).foregroundStyle(Brand.supabase)
                        Text("Bring your Supabase app").font(.title2.bold())
                        Text("Sign in as a user of your own app. OpenDesk shows the tables that account can read, with the same row-level security your app uses, so every teammate sees exactly what they're allowed to.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    TextField("https://xyz.supabase.co", text: $app.url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Publishable or anon key", text: $app.key).textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption.monospaced())
                } header: { Text("Project") } footer: { Text("Project Settings → API. Never paste a secret or service_role key here.") }

                if let s = app.session {
                    Section {
                        LabeledContent("Signed in", value: s.email)
                        Button("Load tables") { Task { await load() } }
                        Button("Sign out", role: .destructive) { app.signOut() }
                    } footer: {
                        if !app.tables.isEmpty { Text("\(app.tables.count) tables available. Find them in the Tables tab.") }
                    }
                } else {
                    Section("Your app account") {
                        TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        Button("Sign in") { Task { await signIn() } }.disabled(busy || !app.isConfigured || email.isEmpty || password.isEmpty)
                    }
                }

                if let error { Section { Text(error).foregroundStyle(.orange).font(.footnote) } }

                if app.needsHelper {
                    Section {
                        Text(SupabaseApp.helperSQL).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy SQL") { UIPasteboard.general.string = SupabaseApp.helperSQL; copied = true }
                    } header: { Text("One-time setup for your admin") } footer: {
                        Text("A read-only helper that lists tables the signed-in user can already read. It grants no new access.")
                    }
                }
            }
            .navigationTitle("Supabase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func signIn() async {
        busy = true
        defer { busy = false }
        do {
            try await app.signIn(email: email, password: password)
            password = ""
            await load()
        } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        do { try await app.loadSchema(); error = nil } catch { self.error = error.localizedDescription }
    }
}
