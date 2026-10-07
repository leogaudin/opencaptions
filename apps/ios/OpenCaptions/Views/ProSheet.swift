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
            HStack {
                Text("One-time purchase").font(.system(size: 15, weight: .medium))
                Spacer()
                Text(price).font(.system(size: 20, weight: .heavy).monospacedDigit())
            }
            .padding(.horizontal, 4)
            #if APPSTORE
                if let message = app.purchases.message {
                    Text(message).font(.system(size: 13)).foregroundStyle(Theme.danger)
                }
                Button("Unlock Pro") { Task { await app.purchases.buy() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(app.purchases.product == nil || app.purchases.isBusy)
                Button("Restore purchases") { Task { await app.purchases.restore() } }
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                    .disabled(app.purchases.isBusy)
            #elseif DEBUG
                Button("Unlock Pro (debug)") {
                    app.setTier(.pro)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            #endif
            Button("Not now") { dismiss() }.buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.fraction(0.8)])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.background)
        .presentationCornerRadius(24)
        .tint(Theme.accent)
    }

    /// What it costs, as the store shows it. A build that is not from the App Store has no store to ask:
    /// a debug build shows a test price, so the sheet can be seen as it will be.
    private var price: String {
        #if APPSTORE
            return app.purchases.displayPrice ?? "…"
        #else
            return String(localized: "4.99 € (test price)")
        #endif
    }

    private func benefit(_ icon: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).font(.system(size: 15, weight: .medium))
        } icon: {
            Image(systemName: icon).frame(width: 22)
        }
    }
}
