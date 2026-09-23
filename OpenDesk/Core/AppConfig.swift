import Foundation
import Observation

/// Connection settings. Persisted in UserDefaults, prefilled from an optional bundled LocalDefaults.plist.
@Observable
final class AppConfig {
    var nocoURL: String { didSet { save("nocoURL", nocoURL) } }
    var nocoToken: String { didSet { save("nocoToken", nocoToken) } }
    var grafanaURL: String { didSet { save("grafanaURL", grafanaURL) } }
    var grafanaToken: String { didSet { save("grafanaToken", grafanaToken) } }
    var gitlabURL: String { didSet { save("gitlabURL", gitlabURL) } }
    var gitlabToken: String { didSet { save("gitlabToken", gitlabToken) } }
    var anthropicKey: String { didSet { save("anthropicKey", anthropicKey) } }
    var pinnedProjects: [String] { didSet { UserDefaults.standard.set(pinnedProjects, forKey: "pinnedProjects") } }

    static let defaultProjects = [
        "gitlab-org/gitlab", "gitlab-org/gitlab-runner", "gitlab-org/cli",
        "inkscape/inkscape", "fdroid/fdroidclient", "wireshark/wireshark", "veloren/veloren",
    ]

    init() {
        var bundled: [String: String] = [:]
        if let url = Bundle.main.url(forResource: "LocalDefaults", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url) as? [String: String] {
            bundled = dict
        }
        func load(_ key: String, _ fallback: String) -> String {
            UserDefaults.standard.string(forKey: key) ?? bundled[key] ?? fallback
        }
        nocoURL = load("nocoURL", "http://localhost:8080")
        nocoToken = load("nocoToken", "")
        grafanaURL = load("grafanaURL", "https://play.grafana.org")
        grafanaToken = load("grafanaToken", "")
        gitlabURL = load("gitlabURL", "https://gitlab.com")
        gitlabToken = load("gitlabToken", "")
        anthropicKey = load("anthropicKey", "")
        pinnedProjects = UserDefaults.standard.stringArray(forKey: "pinnedProjects") ?? Self.defaultProjects
    }

    private func save(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var noco: NocoClient { NocoClient(baseURL: nocoURL.trimmedSlash, token: nocoToken) }
    var grafana: GrafanaClient { GrafanaClient(baseURL: grafanaURL.trimmedSlash, token: grafanaToken) }
    var gitlab: GitLabClient { GitLabClient(baseURL: gitlabURL.trimmedSlash, token: gitlabToken) }
}
