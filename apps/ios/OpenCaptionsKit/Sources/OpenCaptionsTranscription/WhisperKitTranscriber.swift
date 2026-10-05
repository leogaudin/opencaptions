import AVFoundation
import Foundation
import OpenCaptionsKit
import WhisperKit

/// On-device transcription with WhisperKit (Core ML, the Neural Engine). Models are
/// fetched on demand into `modelsDirectory` (the caller excludes it from backup) and
/// never bundled.
public final class WhisperKitTranscriber: Transcriber {
    public let modelsDirectory: URL

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
    }

    /// Where a downloaded model lives, if it is there.
    public func folder(for id: String) -> URL? {
        guard let model = WhisperModels.model(id) else { return nil }
        let folder = modelsDirectory.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/\(model.variant)", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return contents.contains { $0.hasSuffix(".mlmodelc") } ? folder : nil
    }

    public func isDownloaded(_ id: String) -> Bool {
        folder(for: id) != nil
    }

    /// Downloads a model, reporting the fraction done. Does nothing if it is there.
    @discardableResult
    public func download(
        _ id: String, progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard let model = WhisperModels.model(id) else { throw TranscriptionError.unknownModel(id) }
        if let folder = folder(for: id) { return folder }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let folder = try await WhisperKit.download(
            variant: model.variant, downloadBase: modelsDirectory
        ) { p in progress(p.fractionCompleted) }
        var excluded = modelsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return folder
    }

    public func transcribe(
        source: URL, language: String?, model: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Transcript {
        guard let info = WhisperModels.model(model) else { throw TranscriptionError.unknownModel(model) }
        guard let folder = folder(for: model) else { throw TranscriptionError.modelNotDownloaded(model) }

        progress(0, "Reading the audio…")
        let samples = try await AudioExtractor.samples(from: source)
        let duration = try await AVURLAsset(url: source).load(.duration).seconds

        progress(0, "Loading \(info.label)…")
        let pipe = try await WhisperKit(
            WhisperKitConfig(
                model: info.variant, downloadBase: modelsDirectory, modelFolder: folder.path,
                verbose: false, load: true, download: false))

        let lang = language.flatMap { $0 == "auto" ? nil : $0 }
        let options = DecodingOptions(
            task: .transcribe, language: lang, skipSpecialTokens: true, wordTimestamps: true)
        // Decoding reports per window, not per word; the pipeline's own progress
        // counts the audio covered.
        let covered = pipe.progress
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options) { _ in
            progress(min(1, covered.fractionCompleted), "Transcribing…")
            return nil
        }
        try Task.checkCancellation()
        progress(1, "Done")
        return TranscriptMapping.transcript(
            from: results, duration: duration.isFinite ? duration : 0, requestedLanguage: lang)
    }
}
