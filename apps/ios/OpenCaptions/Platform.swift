import SwiftUI

#if os(iOS)
    import UIKit
#else
    import AppKit
#endif

/// The few places where the iPhone and the Mac differ in what the app asks of the system, so that the views
/// carry no `#if`: each is one call that does the right thing on the platform it runs on.

/// The small tick that says a dragged caption has snapped to a centre line.
@MainActor
enum Haptics {
    static func tick() {
        #if os(iOS)
            generator.selectionChanged()
        #else
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }

    #if os(iOS)
        private static let generator = UISelectionFeedbackGenerator()
    #endif
}

/// Keeps the screen (and, on the Mac, the machine) awake while a long job runs, so that the phone does not lock
/// in the middle of a download and the Mac does not sleep through one.
@MainActor
enum KeepAwake {
    #if !os(iOS)
        private static var activity: NSObjectProtocol?
    #endif

    static func set(_ on: Bool) {
        #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = on
        #else
            if on, activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled, .userInitiated], reason: "OpenCaptions is working")
            } else if !on, let activity {
                ProcessInfo.processInfo.endActivity(activity)
                self.activity = nil
            }
        #endif
    }
}

/// The text on the clipboard.
enum Clipboard {
    static var string: String? {
        #if os(iOS)
            UIPasteboard.general.string
        #else
            NSPasteboard.general.string(forType: .string)
        #endif
    }
}

extension View {
    /// Hides the system's navigation bar, for a screen that draws its own (the iPhone's; the Mac has none to hide).
    func hidesNavigationBar() -> some View {
        #if os(iOS)
            toolbar(.hidden, for: .navigationBar)
        #else
            self
        #endif
    }

    /// Hides the tab bar while this screen is shown.
    func hidesTabBar() -> some View {
        #if os(iOS)
            toolbar(.hidden, for: .tabBar)
        #else
            self
        #endif
    }

    /// The tab bar draws no background of its own.
    func tabBarBackgroundHidden() -> some View {
        #if os(iOS)
            toolbarBackground(.hidden, for: .tabBar)
        #else
            self
        #endif
    }

    /// Hides the status bar (the iPhone's; a Mac window has none).
    func hidesStatusBar(_ hidden: Bool) -> some View {
        #if os(iOS)
            statusBarHidden(hidden)
        #else
            self
        #endif
    }

    /// Text typed here is taken as it is: no capital letter at the start (an address, a search).
    func noAutocapitalization() -> some View {
        #if os(iOS)
            textInputAutocapitalization(.never)
        #else
            self
        #endif
    }

    /// The keyboard of a web address.
    func urlKeyboard() -> some View {
        #if os(iOS)
            keyboardType(.URL)
        #else
            self
        #endif
    }
}
