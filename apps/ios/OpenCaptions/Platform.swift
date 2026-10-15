import SwiftUI
import UniformTypeIdentifiers

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

/// The sentences that name the device the app is on (a phone or a Mac), which a translator cannot be handed
/// as one sentence with a word left out: each is written out for each.
enum ThisDevice {
    static var tagline: String.LocalizationValue {
        #if os(macOS)
            "Transcribe, restyle and **save** a video, all on this Mac."
        #else
            "Transcribe, restyle and **save** a video, all on this phone."
        #endif
    }

    static var about: LocalizedStringKey {
        #if os(macOS)
            "Captions that move, made on your Mac. Nothing is uploaded: the speech is transcribed on this device."
        #else
            "Captions that move, made on your phone. Nothing is uploaded: the speech is transcribed on this device."
        #endif
    }

    /// Where the speech is transcribed, as an option next to the remote server.
    static var here: LocalizedStringKey {
        #if os(macOS)
            "On this Mac"
        #else
            "On this phone"
        #endif
    }

    static func noRoom(need: String, free: String) -> LocalizedStringKey {
        #if os(macOS)
            "There is not enough room: this needs about \(need) and the Mac has \(free) free. Choose a smaller size or frame rate, or free up space."
        #else
            "There is not enough room: this needs about \(need) and the phone has \(free) free. Choose a smaller size or frame rate, or free up space."
        #endif
    }
}

extension View {
    /// Hides the system's navigation bar, for a screen that draws its own (the iPhone's; the Mac has none to hide).
    func hidesNavigationBar() -> some View {
        #if os(iOS)
            toolbar(.hidden, for: .navigationBar)
        #else
            // The Mac puts a navigation stack's back button in the window's toolbar: hidden, the screen's own
            // is the only one, and the toolbar leaves no strip of its own at the top.
            toolbar(.hidden, for: .windowToolbar)
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

    /// A Mac window cannot be made smaller than the editor needs; on the iPhone the screen is what it is.
    func macWindowMinimum() -> some View {
        #if os(macOS)
            frame(minWidth: 880, minHeight: 600)
        #else
            self
        #endif
    }
}

#if os(macOS)
    /// The Mac's way to put a file somewhere the user chooses: the system's save panel, which also gives a
    /// sandboxed app the right to write there.
    @MainActor
    enum SaveDialog {
        /// Asks where to put a copy of `file`, and copies it there. The chosen place, or nil if the user cancelled.
        static func copy(_ file: URL, suggesting name: String) async throws -> URL? {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            if let type = UTType(filenameExtension: file.pathExtension) { panel.allowedContentTypes = [type] }
            let chosen: URL? = await withCheckedContinuation { continuation in
                panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
            }
            guard let chosen else { return nil }
            // The panel has already asked about replacing a file that is there.
            if FileManager.default.fileExists(atPath: chosen.path) { try FileManager.default.removeItem(at: chosen) }
            try FileManager.default.copyItem(at: file, to: chosen)
            return chosen
        }
    }
#endif
