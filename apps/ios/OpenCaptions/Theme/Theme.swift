import OpenCaptionsKit
import SwiftUI

/// The look of the app: a dark, immersive editor in the manner of Edits and Instagram, in
/// the desktop's monochrome "burned-in subtitle" spirit, with the highlight yellow as the
/// one accent. Plain SwiftUI, no UI library: a handful of colours, a few styles, one wordmark.
enum Theme {
    static let background = Color(light: "#FFFFFF", dark: "#0A0A0B")
    /// Cards and grouped controls.
    static let surface = Color(light: "#F4F4F6", dark: "#17171A")
    /// Controls sitting on a surface: buttons, tracks, fields.
    static let raised = Color(light: "#E7E7EB", dark: "#242429")
    static let textPrimary = Color(light: "#0A0A0B", dark: "#FFFFFF")
    static let textSecondary = Color(light: "#6B6B75", dark: "#8E8E96")
    static let stroke = textPrimary.opacity(0.09)
    /// The caption highlight yellow, as the desktop's favicon and style presets. It fills and tints
    /// (sliders, progress, the primary button); text stays the primary colour, because a darker
    /// yellow to read on white is simply brown.
    static let accent = Color(hex: "#FFDD00")
    static let onAccent = Color.black
    static let danger = Color(light: "#E5393B", dark: "#FF5C5C")
    /// The playhead and other marks that must stand out from the surface under them.
    static let mark = textPrimary

    static let radius: CGFloat = 16
    static let smallRadius: CGFloat = 10
}

extension Color {
    init(hex: String) {
        self = ColorHex.color(hex)
    }

    /// One colour for light and one for dark, following the interface style it is drawn in.
    init(light: String, dark: String) {
        self = Color(
            uiColor: UIColor { traits in
                UIColor(ColorHex.color(traits.userInterfaceStyle == .dark ? dark : light))
            })
    }
}

/// The user's choice of light, dark or following the system.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }

    static let storageKey = "appearance"
}

// MARK: Wordmark

/// "OpenCaptions." as on the desktop: a solid block with square corners and bold type, like
/// a subtitle burned into a video, inverted with the interface (white on dark, black on light).
struct Wordmark: View {
    var size: CGFloat = 16

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("OpenCaptions")
            Text(".")
        }
        .font(.system(size: size, weight: .heavy))
        .tracking(-0.3)
        .foregroundStyle(Theme.background)
        .padding(.horizontal, size * 0.5)
        .padding(.vertical, size * 0.125)
        .background(Theme.textPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("OpenCaptions")
    }
}

// MARK: Buttons

/// The one action on a screen: yellow, bold, full width where it can be.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.accent.opacity(enabled ? 1 : 0.35), in: .rect(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.textPrimary.opacity(enabled ? 1 : 0.4))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.raised, in: .rect(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A round icon button, translucent so it can sit over the video.
struct CircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(prominent ? Theme.onAccent : Theme.textPrimary.opacity(enabled ? 1 : 0.35))
            .frame(width: 38, height: 38)
            .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.raised), in: .circle)
            .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A small text pill, for a status or a tool.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(prominent ? Theme.onAccent : Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.raised), in: .capsule)
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: Surfaces

extension View {
    /// A grouped block of controls.
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: .rect(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
    }
}

/// A small caps label over a group, in the quiet grey of the desktop's muted text.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How far the end of a scrolling page stays above the screen's bottom edge, so that the last row can be
/// scrolled clear of the tab bar and the fade over it: the bar (49 and the home indicator, about 34), the
/// fade (44) and a little air.
let tabBarClearance: CGFloat = 49 + 34 + 44 + 8

extension View {
    /// Lets what scrolls dissolve into the page just above the tab bar, instead of being cut off at
    /// its edge: a short fade from clear to the page's colour, ending where the bar begins, and
    /// plain page colour behind the bar itself, so there is one fade and not two.
    func fadesIntoTabBar() -> some View {
        overlay(alignment: .bottom) {
            GeometryReader { screen in
                let bar = 49 + screen.safeAreaInsets.bottom
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 44)
                    Theme.background.frame(height: bar)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        }
    }
}
