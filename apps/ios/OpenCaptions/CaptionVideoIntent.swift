import AppIntents
import UniformTypeIdentifiers

/// The Shortcuts action: a video from any shortcut opens on the import screen, the road a video from Photos
/// takes. With it a shortcut can put OpenCaptions in the share sheet of the Photos app.
struct CaptionVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Caption a Video"
    static let description = IntentDescription("Opens a video in OpenCaptions, ready to caption.")
    static let openAppWhenRun = true

    @Parameter(title: "Video", supportedContentTypes: [.movie])
    var video: IntentFile

    @Dependency private var app: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        let suffix = URL(fileURLWithPath: video.filename).pathExtension
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(suffix.isEmpty ? "mov" : suffix)
        // A file is copied as it is: reading a long video into memory could take the app down.
        if let source = video.fileURL {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: source, to: copy)
        } else {
            try video.data.write(to: copy)
        }
        app.incomingVideo = copy
        return .result()
    }
}
