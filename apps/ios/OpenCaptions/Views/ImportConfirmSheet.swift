import AVFoundation
import OpenCaptionsKit
import SwiftUI

/// A video the user picked and has not yet imported.
struct PendingImport: Identifiable {
    let id = UUID()
    let url: URL
    var title: String
    let info: VideoInfo
    let poster: CGImage?

    /// A frame from near the start, as it will look in the list.
    static func poster(of url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)
        return try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
    }

    /// "0:21 · 1080 × 1920 · 30 fps · HDR"
    var summary: String {
        let seconds = Int(info.duration.rounded())
        var parts = [String(format: "%d:%02d", seconds / 60, seconds % 60), "\(info.width) × \(info.height)"]
        if info.fps > 0 { parts.append("\(Int(info.fps.rounded())) fps") }
        if info.hdr != nil { parts.append("HDR") }
        return parts.joined(separator: " · ")
    }
}

/// Shows the picked video and asks before importing it: a poster, a name that can be changed, and
/// what the video is.
struct ImportConfirmSheet: View {
    @State var item: PendingImport
    let choose: (PendingImport) -> Void
    let cancel: () -> Void
    @FocusState private var naming: Bool

    init(item: PendingImport, choose: @escaping (PendingImport) -> Void, cancel: @escaping () -> Void) {
        _item = State(initialValue: item)
        self.choose = choose
        self.cancel = cancel
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Import this video?").font(.system(size: 22, weight: .heavy))
                .frame(maxWidth: .infinity, alignment: .leading)
            ZStack {
                Theme.surface
                if let poster = item.poster {
                    Image(decorative: poster, scale: 1).resizable().scaledToFit()
                } else {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 360)
            .clipShape(.rect(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.stroke, lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $item.title)
                    .focused($naming)
                    .submitLabel(.done)
                    .font(.system(size: 17, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .background(Theme.raised, in: .rect(cornerRadius: 12))
                Text(item.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 2)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button("Cancel", action: cancel).buttonStyle(SecondaryButtonStyle())
                Button("Import") { choose(item) }.buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .presentationDetents([.fraction(0.82)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled()
        .tint(Theme.accent)
    }
}
