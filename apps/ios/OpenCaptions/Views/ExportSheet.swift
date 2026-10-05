import OpenCaptionsKit
import Photos
import SwiftUI

/// Saving the captioned video: progress while it is made, then Share or Save to Photos.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: ExportController
    @State private var photosMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch controller.state {
                case .running(let fraction):
                    ProgressView(value: fraction) { Text("Adding the captions…") }
                    Text("Keep OpenCaptions open until this finishes.").font(.footnote).foregroundStyle(.secondary)
                    Button("Cancel", role: .destructive) {
                        controller.cancel()
                        dismiss()
                    }
                case .done(let url):
                    Label("Your video is ready", systemImage: "checkmark.circle.fill")
                        .font(.headline).foregroundStyle(.green)
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                    Button { Task { await saveToPhotos(url) } } label: {
                        Label("Save to Photos", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                    if let photosMessage { Text(photosMessage).font(.footnote).foregroundStyle(.secondary) }
                case .failed(let reason):
                    Label("It could not be saved", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                case .idle:
                    ProgressView()
                }
            }
            .padding()
            .navigationTitle("Save video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !controller.isRunning {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(controller.isRunning)
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
