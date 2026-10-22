import OpenCaptionsKit
import SwiftUI

/// The word drawn by the engine in the style's own look and in each look the style defines: a tap
/// gives the word that look. A tile cannot disagree with the export, which is drawn by the same code.
/// Nothing shows when the style defines no looks.
struct WordLooks: View {
    @Environment(AppModel.self) private var app
    let style: StyleConfig
    let word: String
    /// The look the word has now: nil is the style's own.
    let current: Int?
    let choose: (Int?) -> Void
    @State private var tiles: [Int?: CGImage] = [:]

    private struct Key: Equatable {
        let style: StyleConfig
        let word: String
    }

    private var choices: [Int?] { [nil] + style.variants.indices.map { Optional($0) } }

    var body: some View {
        if !style.variants.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(choices, id: \.self) { variant in
                        Button { choose(variant) } label: {
                            ZStack {
                                Color(hex: "#232736")
                                if let image = tiles[variant] {
                                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                                } else {
                                    Spinner().controlSize(.small)
                                }
                            }
                            .frame(width: 96, height: 54)
                            .clipShape(.rect(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15), lineWidth: 1))
                            .padding(3)
                            .overlay { RoundedRectangle(cornerRadius: 13).stroke(Theme.accent, lineWidth: current == variant ? 2.5 : 0) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Word look")
                        .accessibilityValue(variant.map { "\($0 + 1)" } ?? "0")
                        .accessibilityAddTraits(current == variant ? .isSelected : [])
                    }
                }
            }
            .task(id: Key(style: style, word: word)) { await draw() }
        }
    }

    private func draw() async {
        var drawn: [Int?: CGImage] = [:]
        for variant in choices {
            let image = await PresetPreviews.draw(
                [(id: "word", config: style)], words: [word], variants: [variant], fonts: app.fontCache)
            drawn[variant] = image["word"]
        }
        tiles = drawn
    }
}
