import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// The few places where the iPhone and the Mac differ in what the app asks of the system, so that the views
/// carry no `#if`: each is one call that does the right thing on the platform it runs on.

/// The small tick that says a dragged caption has snapped to a centre line.
@MainActor
enum Haptics {
    #if os(iOS)
        private static let generator = UISelectionFeedbackGenerator()
    #endif

    static func tick() {
        #if os(iOS)
            generator.selectionChanged()
        #endif
    }
}
