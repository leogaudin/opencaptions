import OpenCaptionsKit
import SwiftUI

/// The presets and every style control the web editor has, plus the timing offset.
struct StylePanel: View {
    let model: EditorModel
    let presets: [Preset]

    @State private var choosingFont = false
    @State private var tab = Tab.presets
    @State private var showPro = false
    /// The background and animation choices, each drawn in the caption's current look.
    @State private var backgroundTiles: [Background: CGImage] = [:]
    @State private var animationTiles: [CaptionAnimation: CGImage] = [:]
    @Environment(AppModel.self) private var app

    /// The style sheet's pages, so that no one page is long and the video stays in view.
    private enum Tab: String, CaseIterable, Identifiable {
        case presets, text, background, animation, outline, timing
        var id: Self { self }
        var title: LocalizedStringKey {
            switch self {
            case .presets: "Presets"
            case .text: "Text"
            case .background: "Background"
            case .animation: "Animation"
            case .outline: "Outline"
            case .timing: "Timing"
            }
        }
        var icon: String {
            switch self {
            case .presets: "sparkles"
            case .text: "textformat"
            case .background: "rectangle.inset.filled"
            case .animation: "wand.and.stars"
            case .outline: "pencil.and.outline"
            case .timing: "clock"
            }
        }
    }
    private var style: StyleConfig { model.project.styleConfig }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ScrollView {
                VStack(spacing: 24) { content }
                    .padding(16)
            }
        }
        .background(Theme.background)
        .tint(Theme.accent)
        .task(id: TileKey(tab: tab, look: tileLook)) { await drawTiles() }
        #if DEBUG
            .task {
                let env = ProcessInfo.processInfo.environment
                if env["OC_SHOW_FONTS"] != nil { choosingFont = true }
                if let name = env["OC_STYLE_TAB"], let shown = Tab.allCases.first(where: { "\($0)" == name.lowercased() }) { tab = shown }
            }
        #endif
        .sheet(isPresented: $showPro) { ProSheet() }
        .sheet(isPresented: $choosingFont) {
            FontPickerSheet(current: style.font, suggested: fonts) { family in
                model.updateStyle { $0.font = family }
            }
            .presentationDetents([.large])
            .presentationBackground(Theme.background)
            .presentationCornerRadius(24)
        }
    }


    @ViewBuilder private var content: some View {
        switch tab {
        case .presets:
            section {
                PresetStrip(presets: presets, active: { style.matches($0) }, apply: { preset in
                    if app.entitlements.locks(preset: preset) { showPro = true } else { model.apply(preset) }
                })
            }
        case .text:
            section {
                Row("Font") {
                    Button { choosingFont = true } label: {
                        HStack(spacing: 6) {
                            FontName(family: style.font, size: 16)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minHeight: 44).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                LabeledSlider("Size", value: intBinding(\.fontSize), range: CaptionGestures.fontSizeRange, step: 1)
                Row("Letter case") {
                    SegmentedPills(
                        options: TextCase.allCases, selection: model.binding(\.textCase),
                        label: { $0 == .upper ? "Uppercase" : "Normal" })
                        .frame(maxWidth: 220)
                }
                Row("Slant") {
                    SegmentedPills(
                        options: [false, true], selection: model.binding(\.italic),
                        label: { $0 ? "Italic" : "Upright" })
                        .frame(maxWidth: 220)
                }
                Row("Text color") { ColorPicker("Text color", selection: color(\.textColor), supportsOpacity: false).labelsHidden() }
                Row("Highlight color") { ColorPicker("Highlight color", selection: color(\.highlightColor), supportsOpacity: false).labelsHidden() }
                LabeledSlider("Words per line", value: intBinding(\.wordsPerLine), range: 1...10, step: 1)
                LabeledSlider("Word spacing", value: model.binding(\.wordSpacing), range: 0...0.6, step: 0.02)
            }
        case .background:
            section {
                ChoiceStrip(
                    options: Background.allCases, selection: style.background, title: backgroundName,
                    images: backgroundTiles, pick: { choice in model.updateStyle { $0 = $0.withBackground(choice) } })
                if style.background != .none {
                    Row("Color") { ColorPicker("Background color", selection: color(\.backgroundColor), supportsOpacity: false).labelsHidden() }
                    LabeledSlider("Opacity", value: model.binding(\.backgroundOpacity), range: 0...1, step: 0.05)
                }
            }
        case .animation:
            section {
                ChoiceStrip(
                    options: CaptionAnimation.allCases, selection: style.animation, title: animationName,
                    images: animationTiles, pick: { choice in model.updateStyle { $0.animation = choice } })
            }
        case .outline:
            section {
                LabeledSlider("Outline", value: model.binding(\.strokeWidth), range: 0...10, step: 0.5)
                if style.strokeWidth > 0 {
                    Row("Outline color") { ColorPicker("Outline color", selection: color(\.strokeColor), supportsOpacity: false).labelsHidden() }
                }
                LabeledSlider("Shadow", value: model.binding(\.shadowBlur), range: 0...20, step: 1)
                LabeledSlider("Shadow right", value: model.binding(\.shadowOffsetX), range: -20...20, step: 1)
                LabeledSlider("Shadow down", value: model.binding(\.shadowOffsetY), range: -20...20, step: 1)
                if style.shadowBlur > 0 || style.shadowOffsetX != 0 || style.shadowOffsetY != 0 {
                    Row("Shadow color") { ColorPicker("Shadow color", selection: color(\.shadowColor, alpha: true), supportsOpacity: true).labelsHidden() }
                }
                LabeledSlider("Glow", value: model.binding(\.glowBlur), range: 0...40, step: 1)
                if style.glowBlur > 0 {
                    Row("Glow color") { ColorPicker("Glow color", selection: color(\.glowColor), supportsOpacity: false).labelsHidden() }
                }
            }
        case .timing:
            section(footer: "Moves every caption against the audio, without transcribing again.") {
                OffsetControl(model: model)
            }
        }
    }

    /// Icons with names, as a row that scrolls if the width is short: the chosen one on a raised pill.
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Tab.allCases) { item in
                    let chosen = item == tab
                    Button { tab = item } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.icon).font(.system(size: 17, weight: .semibold))
                            Text(item.title).font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(chosen ? Theme.textPrimary : Theme.textSecondary)
                        .frame(minWidth: 62).padding(.vertical, 7).padding(.horizontal, 6)
                        .background(chosen ? Theme.raised : .clear, in: .rect(cornerRadius: 12))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    /// What the tiles in view depend on: the look without the choice they offer (picking one must not
    /// redraw them) and without where and how big the caption is, which the tiles ignore.
    private var tileLook: StyleConfig {
        var look = style
        look.positionX = 0
        look.positionY = 0
        look.fontSize = 0
        if tab == .background { look.background = .none }
        if tab == .animation { look.animation = .wordHighlight }
        return look
    }

    private struct TileKey: Equatable {
        let tab: Tab
        let look: StyleConfig
    }

    /// Draws the choices of the tab in view, in the look the caption has now.
    private func drawTiles() async {
        let base = style
        switch tab {
        case .background:
            let looks = Background.allCases.map { ("bg-\($0.rawValue)", base.withBackground($0)) }
            let drawn = await PresetPreviews.draw(looks, fonts: app.fontCache)
            backgroundTiles = Dictionary(uniqueKeysWithValues: Background.allCases.compactMap { c in
                drawn["bg-\(c.rawValue)"].map { (c, $0) } })
        case .animation:
            let looks = CaptionAnimation.allCases.map { choice -> (String, StyleConfig) in
                var look = base
                look.animation = choice
                return ("an-\(choice.rawValue)", look)
            }
            let drawn = await PresetPreviews.draw(looks, fonts: app.fontCache)
            animationTiles = Dictionary(uniqueKeysWithValues: CaptionAnimation.allCases.compactMap { c in
                drawn["an-\(c.rawValue)"].map { (c, $0) } })
        default: break
        }
    }

    // MARK: Layout

    private func section<Content: View>(
        footer: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content
    ) -> some View {
        // The tab names the section, so there is no title over it.
        VStack(alignment: .leading, spacing: 10) {
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

    private func backgroundName(_ background: Background) -> LocalizedStringKey {
        switch background {
        case .none: "None"
        case .solid: "Solid"
        case .pill: "Pill"
        }
    }

    private func animationName(_ animation: CaptionAnimation) -> LocalizedStringKey {
        switch animation {
        case .wordHighlight: "Highlight"
        case .highlightBox: "Box"
        case .wordPop: "Pop"
        case .wordFade: "Fade"
        case .wordSweep: "Karaoke"
        case .wordUnderline: "Underline"
        case .typewriter: "Typewriter"
        case .none: "None"
        case .wordBounce: "Bounce"
        case .lyricFocus: "Focus"
        case .highlightSlide: "Slide"
        case .lineBar: "Progress"
        case .stickers: "Stickers"
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
    let title: LocalizedStringKey
    @ViewBuilder let control: Control

    init(_ title: LocalizedStringKey, @ViewBuilder control: () -> Control) {
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
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(_ title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double) {
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

    private func nudge(_ symbol: String, _ label: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .bold))
                .frame(width: 34, height: 34)
                .background(Theme.raised, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
