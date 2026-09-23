import SwiftUI
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins

/// "Install it and it just works with your data": connect NocoDB, or pull data in from Airtable or a CSV.
struct BringDataView: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    var onFinish: (() -> Void)?

    @State private var status: ConnectionStatus = .unknown
    @State private var showAirtable = false
    @State private var showCSVPicker = false
    @State private var csvPreview: CSVPreview?
    @State private var showShare = false
    @State private var showTeam = false
    @State private var showSupabase = false

    enum ConnectionStatus: Equatable { case unknown, checking, ok(bases: Int, tables: Int), failed(String) }

    var body: some View {
        @Bindable var config = config
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your data, on your phone").font(.title2.bold())
                        Text("Point OpenDesk at the NocoDB you already use, or bring data in from Airtable or a spreadsheet. Nothing is copied to us: the app talks straight to your server.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    HStack {
                        preset("NocoDB Cloud", "https://app.nocodb.com")
                        preset("Self-hosted", config.nocoURL.contains("nocodb.com") ? "http://" : config.nocoURL)
                    }
                    TextField("https://nocodb.yourcompany.com", text: $config.nocoURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API token", text: $config.nocoToken)
                    Button { Task { await check() } } label: {
                        HStack {
                            Text("Connect")
                            Spacer()
                            statusView
                        }
                    }
                    .disabled(config.nocoToken.isEmpty || status == .checking)
                } header: { Label("1 · Connect NocoDB", systemImage: "tablecells.fill") } footer: {
                    Text("In NocoDB: Team & Settings → Tokens → Create token. Paste it here once.")
                }

                Section {
                    Button { showSupabase = true } label: {
                        row("Connect a Supabase app", "Already built on Supabase? Sign in as your app's user and browse your tables under your own security rules.", "bolt.horizontal.circle.fill", Brand.supabase)
                    }
                } header: { Label("Or bring your Supabase", systemImage: "bolt.horizontal.fill") }

                Section {
                    Button { showAirtable = true } label: {
                        row("Import from Airtable", "Paste a base link and your Airtable token. NocoDB copies every table, view and record.", "arrow.down.doc.fill", .yellow)
                    }
                    Button { showCSVPicker = true } label: {
                        row("Import a spreadsheet", "Pick a CSV from Files. Column types are detected for you.", "tablecells.badge.ellipsis", .green)
                    }
                } header: { Label("2 · Bring data in (optional)", systemImage: "square.and.arrow.down.on.square") }
                .disabled(!isConnected)

                Section {
                    Button { showTeam = true } label: {
                        row("Create or join a team", "Admins publish the setup once; every teammate who signs in gets it.", "person.2.fill", Brand.ai)
                    }
                    Button { showShare = true } label: {
                        row("Share this setup", "Show a QR code a teammate scans with their Camera to get the same connections.", "qrcode", Brand.ai)
                    }
                } header: { Label("3 · Invite your team", systemImage: "person.2.fill") }
                .disabled(!isConnected)
            }
            .navigationTitle("Bring your data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isConnected ? "Done" : "Skip") { finish() }
                }
            }
            .task { if !config.nocoToken.isEmpty { await check() } }
            .sheet(isPresented: $showAirtable) { AirtableImportView { finish() } }
            .sheet(item: $csvPreview) { CSVImportView(preview: $0) { finish() } }
            .sheet(isPresented: $showShare) { ShareSetupView() }
            .sheet(isPresented: $showTeam) { TeamView() }
            .sheet(isPresented: $showSupabase) { SupabaseConnectView() }
            .fileImporter(isPresented: $showCSVPicker, allowedContentTypes: [.commaSeparatedText, .plainText, .tabSeparatedText]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let text = try String(contentsOf: url, encoding: .utf8)
                    csvPreview = CSVPreview(name: url.deletingPathExtension().lastPathComponent, csv: try CSV(text: text))
                } catch {
                    status = .failed("Couldn't read that file: \(error.localizedDescription)")
                }
            }
        }
    }

    private var isConnected: Bool { if case .ok = status { return true } else { return false } }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .unknown: EmptyView()
        case .checking: ProgressView()
        case .ok(let b, let t): Label("\(b) bases · \(t) tables", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .failed(let m): Text(m).font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private func preset(_ title: String, _ url: String) -> some View {
        Button(title) { config.nocoURL = url }
            .buttonStyle(.bordered).font(.caption)
    }

    private func row(_ title: String, _ sub: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func check() async {
        status = .checking
        do {
            let noco = config.noco
            let bases = try await noco.bases()
            var tables = 0
            for b in bases { tables += (try? await noco.tables(baseId: b.id).count) ?? 0 }
            status = .ok(bases: bases.count, tables: tables)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func finish() {
        config.onboarded = true
        onFinish?()
        dismiss()
    }
}

// MARK: - Airtable

struct AirtableImportView: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    let onDone: () -> Void
    @State private var link = ""
    @State private var token = ""
    @State private var name = "From Airtable"
    @State private var phase: Phase = .form

    enum Phase: Equatable { case form, running(String), done, failed(String) }

    var body: some View {
        NavigationStack {
            Form {
                switch phase {
                case .form, .failed:
                    Section {
                        TextField("https://airtable.com/app…/shr…", text: $link, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Airtable personal access token", text: $token)
                        TextField("New base name", text: $name)
                    } footer: {
                        Text("In Airtable, open Share → Create a shared link to the whole base, and make a personal access token with data.records:read and schema.bases:read. The token goes to your NocoDB only.")
                    }
                    if case .failed(let m) = phase {
                        Section { Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }
                    Section {
                        Button("Start import") { Task { await run() } }
                            .disabled(link.isEmpty || token.isEmpty || name.isEmpty)
                    }
                case .running(let s):
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            VStack(alignment: .leading) {
                                Text("Importing \(name)…").font(.headline)
                                Text(s).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    } footer: { Text("NocoDB is copying tables, fields and records. Big bases take a few minutes; you can leave this open.") }
                case .done:
                    Section {
                        Label("\(name) is ready", systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(.green)
                        Button("Open it") { onDone(); dismiss() }
                    }
                }
            }
            .navigationTitle("Import from Airtable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }

    private func run() async {
        let noco = config.noco
        phase = .running("Creating base")
        var created: NocoClient.CreatedBase?
        do {
            let base = try await noco.createBase(title: name)
            created = base
            phase = .running("Reading your Airtable base")
            let job = try await noco.startAirtableImport(into: base, link: link.trimmingCharacters(in: .whitespacesAndNewlines), airtableToken: token)
            for i in 0..<180 {
                try await Task.sleep(for: .seconds(2))
                let s = try await noco.jobStatus(baseId: base.id, jobId: job)
                if s == "completed" { phase = .done; return }
                if s == "failed" { throw APIError.status(0, "Airtable rejected the link or token. Check the base is shared and the token has read scopes.") }
                phase = .running(i < 3 ? "Reading your Airtable base" : "Copying records (\(i * 2)s)")
            }
            throw APIError.status(0, "Still running after 6 minutes. It will keep going in NocoDB; check back in Tables.")
        } catch {
            if let created, case .running = phase { try? await noco.deleteBase(created.id) }
            phase = .failed(error.localizedDescription)
        }
    }
}

// MARK: - CSV

struct CSVPreview: Identifiable {
    let id = UUID()
    let name: String
    let csv: CSV
}

struct CSVImportView: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    let preview: CSVPreview
    let onDone: () -> Void
    @State private var tableName = ""
    @State private var bases: [NocoBase] = []
    @State private var baseId = "new"
    @State private var progress: Double?
    @State private var error: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            Form {
                Section("\(preview.csv.rows.count) rows · \(preview.csv.columns.count) columns") {
                    ForEach(Array(preview.csv.columns.enumerated()), id: \.offset) { i, c in
                        HStack {
                            if i == preview.csv.primaryIndex { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                            Text(c.title)
                            Spacer()
                            Text(c.options.isEmpty ? c.type : "\(c.type) · \(c.options.count)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Where") {
                    TextField("Table name", text: $tableName)
                    Picker("Base", selection: $baseId) {
                        Text("New base").tag("new")
                        ForEach(bases) { Text($0.title).tag($0.id) }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.orange) } }
                Section {
                    if done {
                        Label("Imported \(preview.csv.rows.count) rows", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        Button("Open it") { onDone(); dismiss() }
                    } else if let progress {
                        ProgressView(value: progress) { Text("Importing…") }
                    } else {
                        Button("Import") { Task { await run() } }.disabled(tableName.isEmpty)
                    }
                }
            }
            .navigationTitle("Import spreadsheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .task {
                tableName = preview.name
                bases = (try? await config.noco.bases()) ?? []
            }
        }
    }

    private func run() async {
        progress = 0
        do {
            let noco = config.noco
            let target = baseId == "new" ? try await noco.createBase(title: tableName).id : baseId
            _ = try await noco.importCSV(preview.csv, table: tableName, baseId: target) { p in Task { @MainActor in progress = p } }
            done = true
        } catch {
            self.error = error.localizedDescription
            progress = nil
        }
    }
}

// MARK: - Share

/// A QR code carrying an `opendesk://connect` link. The iPhone Camera opens it straight into the app.
struct ShareSetupView: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let img = qr(config.connectLink) {
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                        .frame(maxWidth: 260).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 20))
                }
                Text("Scan with the iPhone Camera").font(.headline)
                Text("Your teammate gets the same NocoDB, Grafana and Metabase connections. The code includes your tokens, so only show it to people who should have your access.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                ShareLink(item: config.connectLink) { Label("Send link instead", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.top, 30)
            .navigationTitle("Share setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    private func qr(_ url: URL) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(url.absoluteString.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension AppConfig {
    var connectLink: URL {
        var c = URLComponents()
        c.scheme = "opendesk"
        c.host = "connect"
        c.queryItems = [
            URLQueryItem(name: "noco", value: nocoURL), URLQueryItem(name: "token", value: nocoToken),
            URLQueryItem(name: "grafana", value: grafanaURL),
            URLQueryItem(name: "metabase", value: metabaseURL), URLQueryItem(name: "mbkey", value: metabaseKey),
        ].filter { !($0.value ?? "").isEmpty }
        return c.url ?? URL(string: "opendesk://connect")!
    }

    /// Applies an `opendesk://connect?...` link. Returns true when anything changed.
    @discardableResult
    func apply(connectLink url: URL) -> Bool {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func v(_ k: String) -> String? { items.first { $0.name == k }?.value.flatMap { $0.isEmpty ? nil : $0 } }
        if let x = v("noco") { nocoURL = x }
        if let x = v("token") { nocoToken = x }
        if let x = v("grafana") { grafanaURL = x }
        if let x = v("metabase") { metabaseURL = x }
        if let x = v("mbkey") { metabaseKey = x }
        onboarded = true
        return v("noco") != nil || v("token") != nil
    }
}
