import OpenCaptionsKit
import Photos
import SwiftUI

/// Saving the captioned video: a percentage and time left while it is made, then Share or
/// Save to Photos. Small on purpose: there is little to say, so it takes little of the screen.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: ExportController
    @State private var photosMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            switch controller.state {
            case .running(let fraction):
                running(fraction)
            case .done(let url):
                done(url)
            case .failed(let reason):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.red)
                    Text("It could not be saved").font(.headline)
                    Text(reason).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            case .idle:
                ProgressView()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(250)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(controller.isRunning)
    }

    private func running(_ fraction: Double) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 46, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer()
                TimeLeft(fraction: fraction, startedAt: controller.startedAt)
            }
            ProgressView(value: fraction)
            Text("Adding the captions to your video. Keep OpenCaptions open until it finishes.")
                .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Button("Cancel", role: .destructive) {
                controller.cancel()
                dismiss()
            }
            .padding(.top, 4)
        }
    }

    private func done(_ url: URL) -> some View {
        VStack(spacing: 16) {
            Label("Your video is ready", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            HStack(spacing: 12) {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                Button { Task { await saveToPhotos(url) } } label: {
                    Label("Save to Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            Text(photosMessage ?? " ").font(.footnote).foregroundStyle(.secondary)
            Button("Done") { dismiss() }
        }
    }

    private func saveToPhotos(_ url: URL) async {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
            photosMessage = "OpenCaptions needs permission to add to Photos. You can allow it in Settings."
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            photosMessage = "Saved to Photos."
        } catch {
            photosMessage = "Could not save: \(error.localizedDescription)"
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
