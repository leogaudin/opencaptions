import SwiftUI

#if os(macOS)
    import AppKit

    /// Scrolling over a view with two fingers on a trackpad, or with a modifier key held (Option, Shift, Command
    /// or Control) on a mouse wheel, which a mouse has no other way to do sideways. Calls `onScroll` with how far
    /// the content is to move across, in points, positive to the right.
    private struct HorizontalScroll: ViewModifier {
        let onScroll: (CGFloat) -> Void
        @State private var pointer = Pointer()
        @State private var monitor: Any?

        /// Whether the pointer is over the view: read by the event monitor, which outlives any one render.
        private final class Pointer { var over = false }

        func body(content: Content) -> some View {
            content
                .onContinuousHover { phase in
                    switch phase {
                    case .active: pointer.over = true
                    case .ended: pointer.over = false
                    }
                }
                .onAppear {
                    let pointer = pointer
                    let onScroll = onScroll
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                        guard pointer.over else { return event }
                        let (x, y) = (event.scrollingDeltaX, event.scrollingDeltaY)
                        let delta: CGFloat
                        if event.hasPreciseScrollingDeltas {
                            // A trackpad: the way the fingers move most.
                            delta = abs(x) >= abs(y) ? x : y
                        } else {
                            // A wheel counts lines, and only with a key held (a plain wheel has nothing to do here).
                            guard !event.modifierFlags.intersection([.option, .shift, .command, .control]).isEmpty
                            else { return event }
                            delta = (abs(x) >= abs(y) ? x : y) * 8
                        }
                        guard delta != 0 else { return nil }
                        MainActor.assumeIsolated { onScroll(delta) }
                        return nil
                    }
                }
                .onDisappear {
                    if let monitor { NSEvent.removeMonitor(monitor) }
                    monitor = nil
                }
        }
    }
#endif

#if os(macOS)
    /// Lets the window be moved by dragging any part of it that does not take the mouse itself: with the title
    /// bar hidden the content runs to the top edge, and there is no bar to drag it by.
    private struct WindowChrome: NSViewRepresentable {
        /// For a window that the scene does not already give a hidden title bar (Settings').
        let hidesTitle: Bool

        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            DispatchQueue.main.async {
                guard let window = view.window else { return }
                window.isMovableByWindowBackground = true
                if hidesTitle {
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    window.styleMask.insert(.fullSizeContentView)
                }
            }
            return view
        }

        func updateNSView(_ view: NSView, context: Context) {}
    }
#endif

extension View {
    /// Makes room, above the content, for the window's three buttons on the Mac, where the content runs under a
    /// hidden title bar instead of beneath a bar of its own: the buttons get a strip of their own at the top, so
    /// that what is under it lines up with the rest of the page. Nothing on the iPhone.
    func titlebarInset() -> some View {
        #if os(macOS)
            padding(.top, 22)
        #else
            self
        #endif
    }

    /// The Mac's window with its title bar hidden: the content runs to the top and the buttons sit on it.
    /// `ownTitle` is for a window whose scene does not hide it already (Settings').
    func hidesTitleBar(ownTitle: Bool = false) -> some View {
        #if os(macOS)
            background(WindowChrome(hidesTitle: ownTitle))
        #else
            self
        #endif
    }

    /// A sheet is as wide as its content on the iPhone, which is the screen; on the Mac it is a panel and needs a
    /// width of its own, or its buttons are squeezed until their words are cut.
    func macSheetWidth(_ width: CGFloat) -> some View {
        #if os(macOS)
            frame(width: width)
        #else
            self
        #endif
    }

    /// Moves a horizontal view with two-finger scrolling (and a modifier key with a wheel) while the pointer is
    /// over it. The iPhone's touch scrolling is its own gesture.
    func onHorizontalScroll(_ onScroll: @escaping (CGFloat) -> Void) -> some View {
        #if os(macOS)
            modifier(HorizontalScroll(onScroll: onScroll))
        #else
            self
        #endif
    }
}

/// A slider that moves in steps. The Mac draws a dot at every step of a stepped slider, which is noise on a range
/// of dozens, so there the steps are applied to the value and the slider itself is continuous.
struct SteppedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        #if os(macOS)
            Slider(
                value: Binding(
                    get: { value },
                    set: { value = min(range.upperBound, max(range.lowerBound, ($0 / step).rounded() * step)) }),
                in: range)
        #else
            Slider(value: $value, in: range, step: step)
        #endif
    }
}
