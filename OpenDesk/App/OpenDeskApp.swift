import SwiftUI

@main
struct OpenDeskApp: App {
    @State private var config = AppConfig()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(config)
                .preferredColorScheme(.dark)
        }
    }
}

enum RootTab: Hashable { case home, tables, dashboards, more }

struct RootView: View {
    @Environment(AppConfig.self) private var config
    @State private var tab: RootTab = .home
    @State private var onboarding = false
    @State private var toast: String?
    @State private var showTeam = false

    private var tint: Color {
        switch tab {
        case .home: Brand.ai
        case .tables: Brand.noco
        case .dashboards: Brand.grafana
        case .more: Brand.ai
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "square.grid.2x2.fill", value: .home) { HomeView(tab: $tab).tint(Brand.ai) }
            Tab("Tables", systemImage: "tablecells.fill", value: .tables) { NocoHomeView().tint(Brand.noco) }
            Tab("Dashboards", systemImage: "chart.xyaxis.line", value: .dashboards) { GrafanaHomeView().tint(Brand.grafana) }
            Tab("More", systemImage: "person.crop.circle", value: .more) { MoreView().tint(Brand.ai) }
        }
        .tint(tint)
        .onAppear { if !config.onboarded { onboarding = true } }
        .fullScreenCover(isPresented: $onboarding) { BringDataView { tab = .tables } }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium)).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule()).padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            // Signed-in members pick up whatever their admin last published.
            let store = TeamStore.shared
            if store.isSignedIn {
                await store.refreshTeams()
                if await store.pull(into: config) { ResponseCache.clear() }
            }
        }
        .sheet(isPresented: $showTeam) { TeamView() }
        .onOpenURL { url in
            if url.host == "auth-callback" {
                Task {
                    await TeamStore.shared.handleCallback(url)
                    if let code = TeamStore.shared.pendingInvite { try? await TeamStore.shared.join(code: code) }
                    await TeamStore.shared.pull(into: config)
                    showTeam = true
                }
                return
            }
            if url.host == "join" {
                let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value ?? ""
                TeamStore.shared.pendingInvite = code
                if TeamStore.shared.isSignedIn {
                    Task { try? await TeamStore.shared.join(code: code); await TeamStore.shared.pull(into: config) }
                }
                showTeam = true
                return
            }
            if url.host == "connect" {
                if config.apply(connectLink: url) {
                    ResponseCache.clear()
                    withAnimation { toast = "Connected to your team's tools" }
                    Task { try? await Task.sleep(for: .seconds(3)); withAnimation { toast = nil } }
                    tab = .home
                }
                return
            }
            switch url.host {
            case "tables": tab = .tables
            case "dashboards": tab = .dashboards
            case "analytics":
                tab = .dashboards
                NotificationCenter.default.post(name: .showMetabase, object: nil)
            case "code", "whiteboard", "more", "team": tab = .more
            default: tab = .home
            }
        }
    }
}
