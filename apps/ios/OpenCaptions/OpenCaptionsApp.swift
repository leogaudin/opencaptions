import SwiftUI

@main
struct OpenCaptionsApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ProjectsView()
                .environment(app)
                .task { await app.bootstrap() }
        }
    }
}
