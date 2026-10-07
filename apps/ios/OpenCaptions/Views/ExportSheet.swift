import OpenCaptionsKit
import Photos
import SwiftUI

/// Saving the captioned video: a percentage and time left while it is made, then Share or
/// Save to Photos. Small on purpose: there is little to say, so it takes little of the screen.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: ExportController
    @State private var photosMessage: String?
    @State private var contentHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 18) {
            switch controller.state {
            case .running(let fraction):
                running(fraction)
            case .done(let url):
                done(url)
            case .failed(let reason):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(Theme.danger)
                    Text("It could not be saved").font(.headline)
                    Text(reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            case .idle:
                ProgressView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        // The sheet is as tall as what it shows (measured), not a fixed height with room to spare.
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .tint(Theme.accent)
        .interactiveDismissDisabled(controller.isRunning)
    }

    private func running(_ fraction: Double) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 46, weight: .heavy, design: .rounded)).monospacedDigit()
                Spacer()
                TimeLeft(fraction: fraction, startedAt: controller.startedAt)
            }
            ProgressView(value: fraction).tint(Theme.accent)
            Text("Adding the captions to your video. Keep OpenCaptions open until it finishes.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel") {
                controller.cancel()
                dismiss()
            }
            .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.danger)
        }
    }

    private func done(_ url: URL) -> some View {
        VStack(spacing: 12) {
            Label("Your video is ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .heavy)).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 12) {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PrimaryButtonStyle())
                Button { Task { await saveToPhotos(url) } } label: {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .accessibilityLabel("Save to Photos")
                .buttonStyle(SecondaryButtonStyle())
            }
            if let photosMessage { Text(photosMessage).font(.footnote).foregroundStyle(.secondary) }
            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 2)
        }
        .animation(.default, value: photosMessage)
    }

    private func saveToPhotos(_ url: URL) async {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
            photosMessage = String(localized: "OpenCaptions needs permission to add to Photos. You can allow it in Settings.")
            return
        }
        do {
            try await PhotosLibrary.addVideo(at: url)
            photosMessage = String(localized: "Saved to Photos.")
        } catch {
            photosMessage = String(localized: "Could not save: \(error.localizedDescription)")
        }
    }
}

/// An estimate from the pace so far, once there is enough progress to judge it by.
private struct TimeLeft: View {
    let fraction: Double
    let startedAt: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let startedAt, fraction > 0.03 {
                let left = max(0, context.date.timeIntervalSince(startedAt) * (1 - fraction) / fraction)
                Text(left < 60 ? "about \(Int(left.rounded(.up))) s left" : "about \(Int((left / 60).rounded(.up))) min left")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Starting…").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Photos runs the change on its own queue, so the closure must not be isolated to the main actor
/// (a closure written inside a view method is, and Swift traps when Photos calls it).
private enum PhotosLibrary {
    nonisolated static func addVideo(at url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
