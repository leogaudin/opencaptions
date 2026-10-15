import SwiftUI

/// What the screen in front offers the menu bar: the Mac's File menu acts on the window that has focus, so each
/// screen publishes the action it can do (nothing, where it cannot) and the menu item reads it.
extension FocusedValues {
    /// Choose a video file to import (the project list).
    @Entry var importVideo: (@MainActor () -> Void)?
    /// Save the captioned video (an open project).
    @Entry var exportVideo: (@MainActor () -> Void)?
    /// Play or pause the video (an open project).
    @Entry var togglePlayback: (@MainActor () -> Void)?
}

#if os(macOS)
    /// The Mac's menu bar: File gains Import Video and Export, and the playback has a menu item (the Space bar
    /// does the same, but only where no text field is taking the typing, which a menu shortcut cannot tell).
    struct AppCommands: Commands {
        @FocusedValue(\.importVideo) private var importVideo
        @FocusedValue(\.exportVideo) private var exportVideo
        @FocusedValue(\.togglePlayback) private var togglePlayback

        var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Video…") { importVideo?() }
                    .keyboardShortcut("o")
                    .disabled(importVideo == nil)
            }
            CommandGroup(after: .newItem) {
                Button("Export…") { exportVideo?() }
                    .keyboardShortcut("e")
                    .disabled(exportVideo == nil)
            }
            CommandMenu("Playback") {
                Button("Play/Pause") { togglePlayback?() }
                    .disabled(togglePlayback == nil)
            }
        }
    }
#endif
