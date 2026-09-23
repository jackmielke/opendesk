import SwiftUI

struct SettingsView: View {
    @Environment(AppConfig.self) private var config
    @Environment(\.dismiss) private var dismiss
    @State private var newProject = ""

    var body: some View {
        @Bindable var config = config
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.10:8080", text: $config.nocoURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API token (xc-token)", text: $config.nocoToken)
                } header: { Label("NocoDB", systemImage: "tablecells.fill") } footer: {
                    Text("Self-hosted NocoDB. Create a token under Team & Settings → API Tokens.")
                }

                Section {
                    TextField("https://play.grafana.org", text: $config.grafanaURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Service account token (optional)", text: $config.grafanaToken)
                } header: { Label("Grafana", systemImage: "chart.xyaxis.line") }

                Section {
                    TextField("https://gitlab.com", text: $config.gitlabURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Personal access token (optional)", text: $config.gitlabToken)
                    ForEach(config.pinnedProjects, id: \.self) { Text($0).font(.callout.monospaced()) }
                        .onDelete { config.pinnedProjects.remove(atOffsets: $0) }
                        .onMove { config.pinnedProjects.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField("group/project", text: $newProject).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Pin") { config.pinnedProjects.append(newProject); newProject = "" }.disabled(!newProject.contains("/"))
                    }
                } header: { Label("GitLab", systemImage: "chevron.left.forwardslash.chevron.right") } footer: {
                    Text("Without a token you get read-only access to public projects. With one: your projects, comments, approvals and pipeline retries.")
                }

                Section {
                    LabeledContent("On-device model", value: AI.onDeviceStatus)
                    SecureField("Anthropic API key (optional)", text: $config.anthropicKey)
                } header: { Label("AI", systemImage: "sparkles") } footer: {
                    Text("By default answers come from Apple Intelligence on this phone, so business data never leaves the device. Add a Claude key for larger context and deeper reasoning.")
                }
            }
            .navigationTitle("Connections")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
        }
    }
}
