import SwiftUI

@main
struct OpenDeskApp: App {
    @State private var config = AppConfig()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(config)
                .preferredColorScheme(.dark)
                .tint(Brand.noco)
        }
    }
}

enum RootTab: Hashable { case home, tables, dashboards, code }

struct RootView: View {
    @State private var tab: RootTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "square.grid.2x2.fill", value: .home) { HomeView(tab: $tab) }
            Tab("Tables", systemImage: "tablecells.fill", value: .tables) { NocoHomeView() }
            Tab("Dashboards", systemImage: "chart.xyaxis.line", value: .dashboards) { GrafanaHomeView() }
            Tab("Code", systemImage: "chevron.left.forwardslash.chevron.right", value: .code) { GitLabHomeView() }
        }
    }
}
