import SwiftUI

@main
struct OpenCaptionsApp: App {
    @State private var app = AppModel()
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup {
            RootView()
                // Inside the environment, which it reads the app model from.
                .modifier(PairingConfirmation())
                .environment(app)
                .task { await app.bootstrap() }
                .onOpenURL { app.handle(link: $0) }
                .preferredColorScheme(appearance.scheme)
                .tint(Theme.accent)
        }
    }
}
