import Foundation
import OpenCaptionsKit

/// The phone's own transcription: the model that was chosen, run by the engine that goes with it
/// (`WhisperModel.engine`). The app talks to this and never to an engine, so a model is added by listing
/// it in `WhisperModels` and, if it needs one, an engine here.
public final class LocalTranscriber: Transcriber {
    private let whisper: WhisperKitTranscriber
    private let parakeet = ParakeetTranscriber()

    public init(modelsDirectory: URL) {
        whisper = WhisperKitTranscriber(modelsDirectory: modelsDirectory)
    }

    private func engine(_ id: String) -> SpeechEngine {
        WhisperModels.model(id)?.engine ?? .whisperKit
    }

    public func isDownloaded(_ id: String) -> Bool {
        switch engine(id) {
        case .whisperKit: whisper.isDownloaded(id)
        case .parakeet: parakeet.isDownloaded()
        case .appleSpeech: true  // iOS holds it, and Apple fetches a language the first time it is used
        }
    }

    /// What a downloaded model takes on disk, in bytes (0 if it is not downloaded, or is built in).
    public func sizeOnDisk(_ id: String) -> Int64 {
        switch engine(id) {
        case .whisperKit: whisper.sizeOnDisk(id)
        case .parakeet: parakeet.sizeOnDisk()
        case .appleSpeech: 0
        }
    }

    /// Removes a downloaded model. It downloads again the next time it is chosen.
    public func delete(_ id: String) throws {
        switch engine(id) {
        case .whisperKit: try whisper.delete(id)
        case .parakeet: try parakeet.delete()
        case .appleSpeech: break
        }
    }

    /// Downloads a model, reporting the fraction done. Does nothing if it is there, or built in.
    public func download(_ id: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let model = WhisperModels.model(id) else { throw TranscriptionError.unknownModel(id) }
        switch model.engine {
        case .whisperKit: try await whisper.download(id, progress: progress)
        case .parakeet: try await parakeet.download(megabytes: model.megabytes, progress: progress)
        case .appleSpeech: break
        }
    }

    /// Starts loading a downloaded model into memory, so that it is ready by the time someone has picked a
    /// language and asked to transcribe.
    public func preload(_ id: String) {
        switch engine(id) {
        case .whisperKit: whisper.preload(id)
        case .parakeet: parakeet.preload()
        case .appleSpeech: break
        }
    }

    /// Lets go of the models in memory, for work that needs the memory more (a save, with 4K frames in
    /// flight): the next transcription loads one again.
    public func releaseModels() {
        whisper.releaseModels()
        parakeet.releaseModels()
    }

    public func transcribe(
        source: URL, language: String?, model: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Transcript {
        switch engine(model) {
        case .whisperKit:
            return try await whisper.transcribe(source: source, language: language, model: model, progress: progress)
        case .parakeet:
            return try await parakeet.transcribe(source: source, language: language, model: model, progress: progress)
        case .appleSpeech:
            #if canImport(Speech) && compiler(>=6.2)
                if #available(iOS 26.0, macOS 26.0, *) {
                    return try await AppleSpeechTranscriber().transcribe(
                        source: source, language: language, model: model, progress: progress)
                }
            #endif
            throw TranscriptionError.unknownModel(model)
        }
    }
}
