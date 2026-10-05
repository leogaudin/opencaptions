import OpenCaptionsKit
import SwiftUI

/// The presets and every style control the web editor has, plus the timing offset.
struct StylePanel: View {
    let model: EditorModel
    let presets: [Preset]

    private var style: StyleConfig { model.project.styleConfig }

    var body: some View {
        Form {
            Section("Caption style") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(presets) { preset in
                            PresetButton(preset: preset, active: style.matches(preset)) { model.apply(preset) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            Section("Customize") {
                Picker("Font", selection: model.binding(\.font)) {
                    ForEach(fonts, id: \.self) { Text($0).tag($0) }
                }
                slider("Font size", value: intBinding(\.fontSize), range: 20...120, step: 1)
                ColorPicker("Text color", selection: color(\.textColor), supportsOpacity: false)
                ColorPicker("Highlight color", selection: color(\.highlightColor), supportsOpacity: false)
                Picker("Background", selection: model.binding(\.background)) {
                    ForEach(Background.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                if style.background != .none {
                    ColorPicker("Background color", selection: color(\.backgroundColor), supportsOpacity: false)
                    slider("Background opacity", value: model.binding(\.backgroundOpacity), range: 0...1, step: 0.05)
                }
                Picker("Animation", selection: model.binding(\.animation)) {
                    ForEach(CaptionAnimation.allCases, id: \.self) { Text(animationName($0)).tag($0) }
                }
                slider("Words per line", value: intBinding(\.wordsPerLine), range: 1...10, step: 1)
                slider("Word spacing", value: model.binding(\.wordSpacing), range: 0...0.6, step: 0.02)
                slider("Stroke width", value: model.binding(\.strokeWidth), range: 0...10, step: 0.5)
                if style.strokeWidth > 0 {
                    ColorPicker("Stroke color", selection: color(\.strokeColor), supportsOpacity: false)
                }
                slider("Shadow blur", value: model.binding(\.shadowBlur), range: 0...20, step: 1)
                if style.shadowBlur > 0 {
                    ColorPicker("Shadow color", selection: color(\.shadowColor, alpha: true), supportsOpacity: true)
                }
            }
            Section {
                OffsetControl(model: model)
            } header: {
                Text("Timing offset")
            } footer: {
                Text("Moves every caption against the audio, without transcribing again.")
            }
        }
    }

    /// The families the app can draw: the bundled face, the presets', and the current one.
    private var fonts: [String] {
        var seen = Set<String>()
        return (["Inter"] + presets.map(\.config.font) + [style.font]).filter { seen.insert($0).inserted }
    }

    private func animationName(_ animation: CaptionAnimation) -> String {
        switch animation {
        case .wordHighlight: "Highlight"
        case .highlightBox: "Box"
        case .wordPop: "Pop"
        case .wordFade: "Fade"
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(0...2))))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func intBinding(_ keyPath: WritableKeyPath<StyleConfig, Int>) -> Binding<Double> {
        Binding(
            get: { Double(model.project.styleConfig[keyPath: keyPath]) },
            set: { value in model.updateStyle { $0[keyPath: keyPath] = Int(value.rounded()) } })
    }

    private func color(_ keyPath: WritableKeyPath<StyleConfig, String>, alpha: Bool = false) -> Binding<Color> {
        Binding(
            get: { ColorHex.color(model.project.styleConfig[keyPath: keyPath]) },
            set: { value in model.updateStyle { $0[keyPath: keyPath] = ColorHex.hex(value, withAlpha: alpha) } })
    }
}

private struct PresetButton: View {
    let preset: Preset
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text("Aa")
                    .font(.title3.bold())
                    .foregroundStyle(ColorHex.color(preset.config.highlightColor))
                    .frame(width: 64, height: 40)
                    .background(
                        preset.config.background == .none ? Color.black.opacity(0.75) : ColorHex.color(preset.config.backgroundColor).opacity(0.8),
                        in: .rect(cornerRadius: 8))
                Text(preset.name).font(.caption2).foregroundStyle(.primary)
            }
            .padding(6)
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: active ? 2 : 0) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Nudge every caption earlier or later: a slider for the coarse move, buttons for 50 ms.
private struct OffsetControl: View {
    let model: EditorModel

    var body: some View {
        let ms = model.project.captionOffsetMs
        VStack(spacing: 8) {
            HStack {
                Text(ms == 0 ? "0 ms" : "\(ms > 0 ? "+" : "")\(ms) ms").monospacedDigit().fontWeight(.semibold)
                Spacer()
                Button { model.setOffset(ms: ms - 50) } label: { Image(systemName: "minus") }
                Button { model.setOffset(ms: ms + 50) } label: { Image(systemName: "plus") }
                Button { model.setOffset(ms: 0) } label: { Image(systemName: "arrow.counterclockwise") }
                    .disabled(ms == 0)
            }
            .buttonStyle(.bordered)
            Slider(
                value: Binding(get: { Double(ms) }, set: { model.setOffset(ms: Int($0.rounded())) }),
                in: Double(EditorModel.offsetRangeMs.lowerBound)...Double(EditorModel.offsetRangeMs.upperBound),
                step: 10)
        }
    }
}
