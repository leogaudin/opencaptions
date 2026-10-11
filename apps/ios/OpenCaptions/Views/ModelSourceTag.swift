import OpenCaptionsKit
import SwiftUI

/// Where a model comes from, as a small icon: the Unicode 🤗 for Hugging Face (an emoji anyone may use)
/// and a phone for the one built into iOS. Apple's logo is not ours to put in an app, and no names, to
/// keep the row quiet.
struct ModelSourceTag: View {
    let model: SpeechModel

    var body: some View {
        Group {
            switch model.source {
            case .huggingFace: Text(verbatim: "\u{1F917}")
            case .apple: Image(systemName: "iphone")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.textSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.source == .apple ? "Apple" : "Hugging Face"))
    }
}
