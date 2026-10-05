import SwiftUI

@main
struct OpenCaptionsApp: App {
    @State private var app = AppModel()
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup {
            ProjectsView()
                .environment(app)
                .task { await app.bootstrap() }
                .preferredColorScheme(appearance.scheme)
                .tint(Theme.accent)
        }
    }
}
