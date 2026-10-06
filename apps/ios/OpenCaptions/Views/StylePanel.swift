import OpenCaptionsKit
import SwiftUI

/// The presets and every style control the web editor has, plus the timing offset.
struct StylePanel: View {
    let model: EditorModel
    let presets: [Preset]

    @State private var choosingFont = false
    private var style: StyleConfig { model.project.styleConfig }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                section("Presets") {
                    PresetStrip(presets: presets, active: { style.matches($0) }, apply: { model.apply($0) })
                }
                section("Text") {
                    Row("Font") {
                        Button { choosingFont = true } label: {
                            HStack(spacing: 6) {
                                FontName(family: style.font, size: 16)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
                            }
                            .foregroundStyle(Theme.textPrimary)
                        }
                        .buttonStyle(.plain)
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
        #if DEBUG
            .task { if ProcessInfo.processInfo.environment["OC_SHOW_FONTS"] != nil { choosingFont = true } }
        #endif
        .sheet(isPresented: $choosingFont) {
            FontPickerSheet(current: style.font, suggested: fonts) { family in
                model.updateStyle { $0.font = family }
            }
            .presentationDetents([.large])
            .presentationBackground(Theme.background)
            .presentationCornerRadius(24)
        }
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
