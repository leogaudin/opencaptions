import OpenCaptionsKit
import SwiftUI

/// What the saved video is like, before it is made: the format, the size, the frame rate, and for an
/// HDR video whether it stays HDR. The choice is remembered.
struct SaveOptionsSheet: View {
    let project: Project
    let save: (ExportOptions) -> Void
    let cancel: () -> Void

    @AppStorage("export.codec") private var codec = ExportOptions.Codec.h264
    @AppStorage("export.resolution") private var resolution = ExportOptions.Resolution.original
    @AppStorage("export.keepHDR") private var keepHDR = true
    @AppStorage("export.fps") private var frameRate = ExportOptions.FrameRate.original
    @State private var contentHeight: CGFloat = 520
    @State private var freeBytes = DiskSpace.available()

    private var isHDR: Bool { project.hdrTransfer != nil }
    private var options: ExportOptions {
        ExportOptions(codec: codec, resolution: resolution, keepHDR: keepHDR, frameRate: frameRate)
    }

    /// The sizes this video can be saved at: its own, and each smaller.
    private var sizes: [ExportOptions.Resolution] {
        ExportOptions.Resolution.available(forShortSide: min(project.videoWidth ?? 1080, project.videoHeight ?? 1920))
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Save video").font(.system(size: 22, weight: .heavy))
                .frame(maxWidth: .infinity, alignment: .leading)
            if isHDR { hdrSection }
            if !isHDR || !keepHDR { formatSection }
            sizeSection
            if rates.count > 1 { frameRateSection }
            estimate
            HStack(spacing: 10) {
                Button("Cancel", action: cancel).buttonStyle(SecondaryButtonStyle())
                Button("Save") { save(options) }.buttonStyle(PrimaryButtonStyle())
                    .disabled(!fits).opacity(fits ? 1 : 0.4)
            }
        }
        .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 + 16 }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(contentHeight)])
        .presentationDragIndicator(.visible)
        .tint(Theme.accent)
        .onAppear {
            // What was chosen for another video may not exist for this one.
            if !sizes.contains(resolution) { resolution = .original }
            if !rates.contains(frameRate) { frameRate = .original }
        }
    }

    private var hdrSection: some View {
        section("Range", note: keepHDR
            ? "Keeps the full brightness and colour of the original. Saved as HEVC."
            : "An ordinary video that looks right everywhere, including where HDR is not supported.") {
            SegmentedPills(options: [true, false], selection: $keepHDR, label: { $0 ? "Keep HDR" : "Standard (SDR)" })
        }
    }

    private var formatSection: some View {
        section("Format", note: codec == .h264
            ? "Plays everywhere."
            : "About a third smaller. Plays on recent phones and computers, not on some old players and sites.") {
            SegmentedPills(options: ExportOptions.Codec.allCases, selection: $codec, label: { $0 == .h264 ? "H.264" : "HEVC" })
        }
    }

    private var sizeSection: some View {
        section("Size", note: dimensions) {
            SegmentedPills(options: sizes, selection: $resolution, label: label(for:))
        }
    }

    /// The rates this video can be saved at: its own, and each lower one.
    private var rates: [ExportOptions.FrameRate] {
        ExportOptions.FrameRate.available(forSourceFps: project.videoFps ?? 30)
    }

    private var frameRateNote: String {
        let source = project.videoFps ?? 30
        guard let rate = frameRate.value else { return "As filmed (\(Int(source.rounded())) fps)." }
        return rate > source
            ? "The picture stays as filmed; the captions animate at \(Int(rate)) fps, smoother."
            : "Fewer frames: a smaller file."
    }

    private var frameRateSection: some View {
        section("Frame rate", note: frameRateNote) {
            SegmentedPills(options: rates, selection: $frameRate, label: { rate in
                rate.value.map { "\(Int($0)) fps" } ?? "Original"
            })
        }
    }

    /// Whether the video, as estimated, fits in what the phone has free.
    private var fits: Bool {
        options.estimatedBytes(for: project).map { DiskSpace.fits($0, available: freeBytes) } ?? true
    }

    private var estimate: some View {
        VStack(spacing: 6) {
            estimateRow
            if !fits, let free = freeBytes {
                Text("There is not enough room: this needs about \(Self.size(options.estimatedBytes(for: project) ?? 0)) and the phone has \(Self.size(free)) free. Choose a smaller size or frame rate, or free up space.")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var estimateRow: some View {
        HStack {
            Label("About", systemImage: "internaldrive").font(.system(size: 13, weight: .medium))
            Spacer()
            Text(options.estimatedBytes(for: project).map(Self.size) ?? "")
                .font(.system(size: 15, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 4)
    }

    private func section<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
            if let note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
            }
        }
    }

    private func label(for size: ExportOptions.Resolution) -> String {
        switch size {
        case .original: "Original"
        case .p2160: "4K"
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }

    /// The pixel size the choice makes, e.g. "1080 × 1920".
    private var dimensions: String {
        let size = options.outputSize(width: project.videoWidth ?? 0, height: project.videoHeight ?? 0)
        return project.videoWidth == nil ? "" : "\(size.width) × \(size.height)"
    }
}
