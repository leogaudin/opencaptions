import AppIntents
import SwiftUI

@main
struct OpenCaptionsApp: App {
    @State private var app: AppModel
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

    init() {
        let model = AppModel()
        _app = State(initialValue: model)
        // What the Shortcuts action reaches the app through.
        AppDependencyManager.shared.add(dependency: model)
    }

    var body: some Scene {
        #if os(macOS)
            mainWindow
                .windowStyle(.hiddenTitleBar)
                .defaultSize(width: 1280, height: 800)
                .windowResizability(.contentMinSize)
                .commands { AppCommands() }

            // The Mac keeps Settings in a window of its own (⌘,), not in a tab beside the projects.
            Settings {
                SettingsView()
                    .environment(app)
                    .preferredColorScheme(appearance.scheme)
                    .tint(Theme.accent)
                    .frame(width: 560, height: 680)
                    .hidesTitleBar(ownTitle: true)
            }
        #else
            mainWindow
        #endif
    }

    private var mainWindow: some Scene {
        WindowGroup {
            RootView()
                // Past this the fixed parts of the editor no longer fit; it is still over twice the default size.
                .dynamicTypeSize(...DynamicTypeSize.accessibility3)
                // Inside the environment, which it reads the app model from.
                .modifier(PairingConfirmation())
                .environment(app)
                .task { await app.bootstrap() }
                .onOpenURL { app.handle(link: $0) }
                .preferredColorScheme(appearance.scheme)
                .tint(Theme.accent)
                .macWindowMinimum()
                .hidesTitleBar()
        }
    }
}
