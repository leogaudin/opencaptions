import OpenCaptionsKit
import SwiftUI

/// Tiles fill the width and wrap: as many to a row as fit.
private let tileColumns = [GridItem(.adaptive(minimum: 140), spacing: 10)]

/// The presets, as a grid.
struct PresetStrip: View {
    @Environment(AppModel.self) private var app
    let presets: [Preset]
    let active: (Preset) -> Bool
    let apply: (Preset) -> Void

    var body: some View {
        LazyVGrid(columns: tileColumns, spacing: 10) {
            ForEach(presets) { preset in
                PresetTile(
                    preset: preset, image: app.presetPreviews.images[preset.id], active: active(preset),
                    locked: app.entitlements.locks(preset: preset)
                ) {
                    apply(preset)
                }
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
    let locked: Bool
    let action: () -> Void

    var body: some View {
        StyleTile(title: LocalizedStringKey(preset.name), image: image, active: active, locked: locked, action: action)
    }
}

/// A picture the engine drew on a plain card, with its name under it, and a ring when chosen.
struct StyleTile: View {
    let title: LocalizedStringKey
    let image: CGImage?
    let active: Bool
    var locked = false
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
                .aspectRatio(156.0 / 87.0, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
                .overlay(alignment: .topTrailing) { if locked { ProBadge().padding(6) } }
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

/// The choices of one setting, each drawn in the caption's current look: a grid.
struct ChoiceStrip<Value: Hashable>: View {
    let options: [Value]
    let selection: Value
    let title: (Value) -> LocalizedStringKey
    let images: [Value: CGImage]
    let pick: (Value) -> Void

    var body: some View {
        LazyVGrid(columns: tileColumns, spacing: 10) {
            ForEach(options, id: \.self) { option in
                StyleTile(title: title(option), image: images[option], active: option == selection) { pick(option) }
            }
        }
    }
}
