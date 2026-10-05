import OpenCaptionsKit
import SwiftUI

/// The look of the app: a dark, immersive editor in the manner of Edits and Instagram, in
/// the desktop's monochrome "burned-in subtitle" spirit, with the highlight yellow as the
/// one accent. Plain SwiftUI, no UI library: a handful of colours, a few styles, one wordmark.
enum Theme {
    static let background = Color(hex: "#0A0A0B")
    /// Cards and grouped controls.
    static let surface = Color(hex: "#17171A")
    /// Controls sitting on a surface: buttons, tracks, fields.
    static let raised = Color(hex: "#242429")
    static let stroke = Color.white.opacity(0.08)
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "#8E8E96")
    /// The caption highlight yellow, as the desktop's favicon and style presets.
    static let accent = Color(hex: "#FFDD00")
    static let onAccent = Color.black
    static let danger = Color(hex: "#FF5C5C")

    static let radius: CGFloat = 16
    static let smallRadius: CGFloat = 10
}

extension Color {
    init(hex: String) {
        self = ColorHex.color(hex)
    }
}

// MARK: Wordmark

/// "OpenCaptions." as on the desktop: a solid block with square corners and bold type, like
/// a subtitle burned into a video (white on dark here, as the desktop's dark mode has it).
struct Wordmark: View {
    var size: CGFloat = 17

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("OpenCaptions")
            Text(".")
        }
        .font(.system(size: size, weight: .heavy))
        .tracking(-0.3)
        .foregroundStyle(.black)
        .padding(.horizontal, size * 0.5)
        .padding(.vertical, size * 0.2)
        .background(.white)
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
            .background(
                prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.black.opacity(0.55)), in: .circle
            )
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
            .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.black.opacity(0.55)), in: .capsule)
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
