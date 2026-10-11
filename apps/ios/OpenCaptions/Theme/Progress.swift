import SwiftUI

/// A bar for work with a known fraction. The highlight yellow alone vanishes on the light
/// background, so the fill is outlined in black on a visible track, like the captions themselves.
struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let filled = max(height, geometry.size.width * min(max(value, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                Capsule().strokeBorder(Theme.textPrimary.opacity(0.28), lineWidth: 1)
                Capsule().fill(Theme.accent)
                    .overlay(Capsule().strokeBorder(Color.black.opacity(0.85), lineWidth: 1.5))
                    .frame(width: value > 0 ? filled : 0)
                    .animation(.easeOut(duration: 0.25), value: value)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int(min(max(value, 0), 1) * 100))%"))
    }
}

/// A spinner in the text colour: the yellow tint most screens set is invisible on white.
struct Spinner: View {
    var body: some View {
        ProgressView().tint(Theme.textPrimary)
    }
}
