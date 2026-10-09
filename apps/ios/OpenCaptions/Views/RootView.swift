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

    /// The first screen fades in over the launch screen (the logo on the background colour), so
    /// starting reads as one movement and not as a flash.
    @State private var shown = false

    var body: some View {
        TabView(selection: $page) {
            Tab("Projects", systemImage: "rectangle.stack.fill", value: Page.projects) { ProjectsView() }
            Tab("Settings", systemImage: "gearshape.fill", value: Page.settings) { SettingsView() }
        }
        .tint(Theme.textPrimary)
        // The content fades into the page behind the bar (`fadesIntoTabBar`), so the bar needs no
        // edge of its own.
        .toolbarBackground(.hidden, for: .tabBar)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.35)) { shown = true } }
    }
}
