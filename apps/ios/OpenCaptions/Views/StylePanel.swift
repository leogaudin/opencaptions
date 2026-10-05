import OpenCaptionsKit
import SwiftUI

/// The presets and every style control the web editor has, plus the timing offset.
struct StylePanel: View {
    let model: EditorModel
    let presets: [Preset]

    private var style: StyleConfig { model.project.styleConfig }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                section("Presets") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(presets) { preset in
                                PresetTile(preset: preset, active: style.matches(preset)) { model.apply(preset) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                section("Text") {
                    Row("Font") {
                        Picker("Font", selection: model.binding(\.font)) {
                            ForEach(fonts, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.menu)
                    }
                    LabeledSlider("Size", value: intBinding(\.fontSize), range: 20...120, step: 1)
                    Row("Text color") { ColorPicker("Text color", selection: color(\.textColor), supportsOpacity: false).labelsHidden() }
                    Row("Highlight color") { ColorPicker("Highlight color", selection: color(\.highlightColor), supportsOpacity: false).labelsHidden() }
                    LabeledSlider("Words per line", value: intBinding(\.wordsPerLine), range: 1...10, step: 1)
                    LabeledSlider("Word spacing", value: model.binding(\.wordSpacing), range: 0...0.6, step: 0.02)
                }
                section("Background") {
                    SegmentedPills(
                        options: Background.allCases, selection: model.binding(\.background),
                        label: { $0.rawValue.capitalized })
                    if style.background != .none {
                        Row("Color") { ColorPicker("Background color", selection: color(\.backgroundColor), supportsOpacity: false).labelsHidden() }
                        LabeledSlider("Opacity", value: model.binding(\.backgroundOpacity), range: 0...1, step: 0.05)
                    }
                }
                section("Animation") {
                    SegmentedPills(
                        options: CaptionAnimation.allCases, selection: model.binding(\.animation),
                        label: animationName)
                }
                section("Outline & shadow") {
                    LabeledSlider("Outline", value: model.binding(\.strokeWidth), range: 0...10, step: 0.5)
                    if style.strokeWidth > 0 {
                        Row("Outline color") { ColorPicker("Outline color", selection: color(\.strokeColor), supportsOpacity: false).labelsHidden() }
                    }
                    LabeledSlider("Shadow", value: model.binding(\.shadowBlur), range: 0...20, step: 1)
                    if style.shadowBlur > 0 {
                        Row("Shadow color") { ColorPicker("Shadow color", selection: color(\.shadowColor, alpha: true), supportsOpacity: true).labelsHidden() }
                    }
                }
                section("Timing", footer: "Moves every caption against the audio, without transcribing again.") {
                    OffsetControl(model: model)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .tint(Theme.accent)
    }

    // MARK: Layout

    private func section<Content: View>(
        _ title: String, footer: String? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 16, content: content).card()
            if let footer {
                Text(footer).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
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

// MARK: Components

/// A label at the left and a control at the right.
private struct Row<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(title).font(.system(size: 15, weight: .medium))
            Spacer()
            control
        }
    }
}

/// A slider with its name and value above it.
private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) {
        self.title = title
        _value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(0...2))))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

/// A row of options in a pill-shaped track, the chosen one in yellow.
private struct SegmentedPills<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let chosen = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(chosen ? Theme.onAccent : Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(chosen ? Theme.accent : .clear, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Theme.raised, in: .capsule)
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

private struct PresetTile: View {
    let preset: Preset
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text("Aa")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(ColorHex.color(preset.config.highlightColor))
                    .frame(width: 84, height: 54)
                    .background(
                        preset.config.background == .none
                            ? Color.black : ColorHex.color(preset.config.backgroundColor).opacity(0.9),
                        in: .rect(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, lineWidth: 1))
                Text(preset.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            }
            .padding(7)
            .overlay {
                RoundedRectangle(cornerRadius: 16).stroke(Theme.accent, lineWidth: active ? 2 : 0)
            }
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
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text(ms == 0 ? "0 ms" : "\(ms > 0 ? "+" : "")\(ms) ms")
                    .font(.system(size: 20, weight: .heavy).monospacedDigit())
                Spacer()
                nudge("minus", "Earlier by 50 milliseconds") { model.setOffset(ms: ms - 50) }
                nudge("plus", "Later by 50 milliseconds") { model.setOffset(ms: ms + 50) }
                nudge("arrow.counterclockwise", "Reset the offset") { model.setOffset(ms: 0) }
                    .disabled(ms == 0)
            }
            Slider(
                value: Binding(get: { Double(ms) }, set: { model.setOffset(ms: Int($0.rounded())) }),
                in: Double(EditorModel.offsetRangeMs.lowerBound)...Double(EditorModel.offsetRangeMs.upperBound),
                step: 10)
        }
    }

    private func nudge(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .background(Theme.raised, in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
