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

enum RootTab: Hashable { case home, tables, dashboards, analytics, code, whiteboard }

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
        case .analytics: Brand.metabase
        case .whiteboard: Brand.excalidraw
        case .code: Brand.gitlab
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "square.grid.2x2.fill", value: .home) { HomeView(tab: $tab).tint(Brand.ai) }
            Tab("Tables", systemImage: "tablecells.fill", value: .tables) { NocoHomeView().tint(Brand.noco) }
            Tab("Dashboards", systemImage: "chart.xyaxis.line", value: .dashboards) { GrafanaHomeView().tint(Brand.grafana) }
            Tab("Analytics", systemImage: "chart.pie.fill", value: .analytics) { MetabaseHomeView().tint(Brand.metabase) }
            Tab("Code", systemImage: "chevron.left.forwardslash.chevron.right", value: .code) { GitLabHomeView().tint(Brand.gitlab) }
            Tab("Whiteboard", systemImage: "scribble.variable", value: .whiteboard) { WhiteboardHomeView().tint(Brand.excalidraw) }
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
            case "code": tab = .code
            case "analytics": tab = .analytics
            case "whiteboard": tab = .whiteboard
            default: tab = .home
            }
        }
    }
}
