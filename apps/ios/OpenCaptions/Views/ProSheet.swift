import OpenCaptionsKit
import SwiftUI

/// What Pro adds, shown when a free build runs into one of its limits. Builds from source are Pro
/// already and never show it; a debug build can unlock to try both sides.
struct ProSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("OpenCaptions Pro").font(.system(size: 22, weight: .heavy))
                ProBadge()
                Spacer()
            }
            VStack(alignment: .leading, spacing: 12) {
                benefit("film", "Videos in 4K and above 1080p")
                benefit("speedometer", "60 frames per second")
                benefit("sun.max.fill", "HDR videos stay HDR")
                benefit("textformat", "Every caption style")
                benefit("waveform", "The Large v3 speech model")
                benefit("drop.degreesign.slash", "No watermark on your videos")
            }
            .card()
            #if DEBUG
                Button("Unlock Pro (this debug build)") {
                    app.setTier(.pro)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            #endif
            Button("Not now") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .presentationCornerRadius(24)
        .tint(Theme.accent)
    }

    private func benefit(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).font(.system(size: 15, weight: .medium))
        } icon: {
            Image(systemName: icon).frame(width: 22)
        }
    }
}
