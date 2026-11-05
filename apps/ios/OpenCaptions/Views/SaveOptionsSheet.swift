import OpenCaptionsKit
import SwiftUI

/// What the saved video is like, before it is made: the format, the size, the frame rate, and for an
/// HDR video whether it stays HDR. The choice is remembered.
struct SaveOptionsSheet: View {
    let project: Project
    /// Writes the captions as a subtitle file, for the share sheet.
    let subtitles: @Sendable (SubtitleFormat) async throws -> URL
    let save: (ExportOptions) -> Void
    let cancel: () -> Void

    @AppStorage("export.codec") private var codec = ExportOptions.Codec.h264
    @AppStorage("export.resolution") private var resolution = ExportOptions.Resolution.original
    @AppStorage("export.keepHDR") private var keepHDR = true
    @AppStorage("export.fps") private var frameRate = ExportOptions.FrameRate.original
    @State private var greenScreen = false
    @State private var choicesHeight: CGFloat = 440
    @State private var buttonsHeight: CGFloat = 60
    @State private var freeBytes = DiskSpace.available()
    @State private var showPro = false
    @Environment(AppModel.self) private var app
    private var tier: Entitlements { app.entitlements }

    private var isHDR: Bool { project.hdrTransfer != nil }
    private var options: ExportOptions {
        ExportOptions(codec: codec, resolution: resolution, keepHDR: keepHDR, frameRate: frameRate, greenScreen: greenScreen)
    }

    /// The sizes this video can be saved at: its own, and every other, larger ones too.
    private var sizes: [ExportOptions.Resolution] {
        ExportOptions.Resolution.available(forShortSide: min(project.videoWidth ?? 1080, project.videoHeight ?? 1920))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scrolls when large text makes the choices taller than the screen; the buttons stay in reach.
            ScrollView {
                VStack(spacing: 18) {
                    HStack {
                        Text("Save video").scaledFont(22, weight: .heavy)
                        Spacer()
                        subtitlesMenu
                    }
                    if isHDR && !greenScreen { hdrSection }
                    if !isHDR || !keepHDR || greenScreen { formatSection }
                    sizeSection
                    if rates.count > 1 { frameRateSection }
                    backgroundSection
                    estimate
                }
                .padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 18)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { choicesHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(idealHeight: choicesHeight)
            HStack(spacing: 10) {
                Button("Cancel", action: cancel).buttonStyle(SecondaryButtonStyle())
                Button("Save") { save(options) }.buttonStyle(PrimaryButtonStyle())
                    .disabled(!fits).opacity(fits ? 1 : 0.4)
            }
            .padding(.horizontal, 18).padding(.bottom, 8)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { buttonsHeight = $0 }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(choicesHeight + buttonsHeight + 16)])
        .presentationDragIndicator(.visible)
        .tint(Theme.accent)
        .sheet(isPresented: $showPro) { ProSheet() }
        .onAppear {
            // What was chosen for another video may not exist for this one, or this tier.
            if !sizes.contains(resolution) { resolution = .original }
            if !rates.contains(frameRate) { frameRate = .original }
            let allowed = tier.limit(options, for: project)
            (resolution, frameRate, keepHDR) = (allowed.resolution, allowed.frameRate, allowed.keepHDR)
        }
    }

    private var hdrSection: some View {
        section("Range", note: keepHDR
            ? "Keeps the full brightness and colour of the original. Saved as HEVC."
            : "An ordinary video that looks right everywhere, including where HDR is not supported.") {
            SegmentedPills(
                options: [true, false], selection: $keepHDR, label: { $0 ? "Keep HDR" : "Standard (SDR)" },
                locked: { $0 && tier.locksHDR(for: project) }, onLocked: { showPro = true })
        }
    }

    private var backgroundSection: some View {
        section("Background", note: greenScreen ? "Only the captions, on green, to key out in your editor." : "The video, with the captions on it.") {
            SegmentedPills(options: [false, true], selection: $greenScreen, label: { $0 ? "Green screen" : "Video" })
        }
    }

    /// The subtitle files are a side door: a menu, not a section of the sheet.
    private var subtitlesMenu: some View {
        Menu {
            ForEach([SubtitleFormat.srt, .vtt], id: \.rawValue) { format in
                let name = format == .srt ? "SRT" : "VTT"
                ShareLink(item: SubtitleFile(format: format, write: subtitles), preview: SharePreview(name)) {
                    Label { Text(verbatim: name) } icon: { Image(systemName: "captions.bubble") }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .buttonStyle(CircleButtonStyle())
        .accessibilityLabel("Subtitles")
    }

    private var formatSection: some View {
        section("Format", note: codec == .h264
            ? "Plays everywhere."
            : "About a third smaller. Plays on recent phones and computers, not on some old players and sites.") {
            SegmentedPills(options: ExportOptions.Codec.allCases, selection: $codec, label: { $0 == .h264 ? "H.264" : "HEVC" })
        }
    }

    private var sizeSection: some View {
        section("Size", note: LocalizedStringKey(dimensions)) {
            SegmentedPills(
                options: sizes, selection: $resolution, label: label(for:),
                locked: { tier.locks(resolution: $0, for: project) }, onLocked: { showPro = true })
        }
    }

    /// The rates this video can be saved at: its own, and each lower one.
    private var rates: [ExportOptions.FrameRate] {
        ExportOptions.FrameRate.available(forSourceFps: project.videoFps ?? 30)
    }

    private var frameRateNote: LocalizedStringKey {
        let source = project.videoFps ?? 30
        guard let rate = frameRate.value else { return "As filmed (\(Int(source.rounded())) fps)." }
        return rate > source
            ? "The picture stays as filmed; the captions animate at \(Int(rate)) fps, smoother."
            : "Fewer frames: a smaller file."
    }

    private var frameRateSection: some View {
        section("Frame rate", note: frameRateNote) {
            SegmentedPills(
                options: rates, selection: $frameRate,
                label: { rate in
                    "\(Int((rate.value ?? project.videoFps ?? 30).rounded())) fps"
                },
                locked: { tier.locks(frameRate: $0, for: project) }, onLocked: { showPro = true })
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
                Text(ThisDevice.noRoom(need: Self.size(options.estimatedBytes(for: project) ?? 0), free: Self.size(free)))
                    .scaledFont(12, weight: .medium).foregroundStyle(Theme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var estimateRow: some View {
        HStack {
            Label("About", systemImage: "internaldrive").scaledFont(13, weight: .medium)
            Spacer()
            Text(options.estimatedBytes(for: project).map(Self.size) ?? "")
                .scaledFont(15, weight: .bold).monospacedDigit()
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 4)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, note: LocalizedStringKey? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            content()
            if let note {
                Text(note).scaledFont(12).foregroundStyle(Theme.textSecondary).padding(.horizontal, 4)
            }
        }
    }

    /// A size by its pixels. The video's own size is `.original`, named by its short side.
    private func label(for size: ExportOptions.Resolution) -> LocalizedStringKey {
        let side = size.shortSide ?? min(project.videoWidth ?? 1080, project.videoHeight ?? 1920)
        // As text: a number in a localized string is grouped, and "1,080p" is not the name of a size.
        return side == 2160 ? "4K" : "\(String(side))p"
    }

    /// The pixel size the choice makes, e.g. "1080 × 1920".
    private var dimensions: String {
        let size = options.outputSize(width: project.videoWidth ?? 0, height: project.videoHeight ?? 0)
        return project.videoWidth == nil ? "" : "\(size.width) × \(size.height)"
    }
}
