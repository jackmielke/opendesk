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

enum RootTab: Hashable { case home, tables, dashboards, analytics, code }

struct RootView: View {
    @State private var tab: RootTab = .home

    private var tint: Color {
        switch tab {
        case .home: Brand.ai
        case .tables: Brand.noco
        case .dashboards: Brand.grafana
        case .analytics: Brand.metabase
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
        }
        .tint(tint)
        .onOpenURL { url in
            switch url.host {
            case "tables": tab = .tables
            case "dashboards": tab = .dashboards
            case "code": tab = .code
            case "analytics": tab = .analytics
            default: tab = .home
            }
        }
    }
}
