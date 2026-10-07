import OpenCaptionsKit
import SwiftUI

/// The presets in a row that scrolls sideways. At the start a fade and an arrow on the right edge
/// say there is more; they go as soon as it has been scrolled.
struct PresetStrip: View {
    @Environment(AppModel.self) private var app
    let presets: [Preset]
    let active: (Preset) -> Bool
    let apply: (Preset) -> Void
    @State private var scrolled = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(presets) { preset in
                    PresetTile(preset: preset, image: app.presetPreviews.images[preset.id], active: active(preset)) {
                        apply(preset)
                    }
                }
            }
            .padding(.vertical, 2).padding(.trailing, 28)
        }
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x > 12 } action: { _, now in
            withAnimation(.easeOut(duration: 0.2)) { scrolled = now }
        }
        .overlay(alignment: .trailing) {
            if !scrolled {
                ZStack(alignment: .trailing) {
                    LinearGradient(colors: [Theme.surface.opacity(0), Theme.surface], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 56)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 26, height: 26)
                        .background(Theme.raised, in: .circle)
                        .overlay(Circle().stroke(Theme.stroke, lineWidth: 1))
                        .padding(.trailing, 2)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .task(id: presets.map(\.id)) {
            await app.presetPreviews.load(presets, fonts: app.fontCache)
        }
    }
}

private struct PresetTile: View {
    let preset: Preset
    let image: CGImage?
    let active: Bool
    let action: () -> Void

    var body: some View {
        StyleTile(title: preset.name, image: image, active: active, action: action)
    }
}

/// A picture the engine drew on a plain card, with its name under it, and a ring when chosen.
struct StyleTile: View {
    let title: String
    let image: CGImage?
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    // A plain card, the web's too: captions are mostly white, so it is dark.
                    Color(hex: "#232736")
                    if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 156, height: 87)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            .padding(6)
            .overlay { RoundedRectangle(cornerRadius: 17).stroke(Theme.accent, lineWidth: active ? 2.5 : 0) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// The choices of one setting, each drawn in the caption's current look: a row that scrolls sideways.
struct ChoiceStrip<Value: Hashable>: View {
    let options: [Value]
    let selection: Value
    let title: (Value) -> String
    let images: [Value: CGImage]
    let pick: (Value) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(options, id: \.self) { option in
                    StyleTile(title: title(option), image: images[option], active: option == selection) { pick(option) }
                }
            }
            .padding(.vertical, 4)
        }
    }
}
