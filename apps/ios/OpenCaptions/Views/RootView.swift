import SwiftUI

/// Projects and Settings, as two tabs. The editor hides the tab bar while it is open.
struct RootView: View {
    private enum Page { case projects, settings }

    #if DEBUG
        // Screenshots on a simulator: OC_TAB=settings opens on Settings.
        @State private var page = ProcessInfo.processInfo.environment["OC_TAB"] == "settings" ? Page.settings : .projects
    #else
        @State private var page = Page.projects
    #endif

    var body: some View {
        TabView(selection: $page) {
            Tab("Projects", systemImage: "rectangle.stack.fill", value: Page.projects) { ProjectsView() }
            Tab("Settings", systemImage: "gearshape.fill", value: Page.settings) { SettingsView() }
        }
        .tint(Theme.textPrimary)
    }
}
