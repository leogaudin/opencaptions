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
        // WhisperKit reports progress per file, and a model is a few dozen small files and
        // two or three huge ones, so its fraction races to ~75% and then crawls. Bytes on
        // disk (partial files are written as they arrive) against the model's known size
        // move steadily instead.
        let expected = Double(model.megabytes) * 1_000_000
        let baseline = Self.bytes(in: modelsDirectory)
        let directory = modelsDirectory
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                let done = Double(max(0, Self.bytes(in: directory) - baseline))
                progress(min(0.99, done / expected))
            }
        }
        defer { watcher.cancel() }
        let folder = try await WhisperKit.download(variant: model.variant, downloadBase: modelsDirectory) { _ in }
        progress(1)
        var excluded = modelsDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return folder
    }

    /// The size of everything under `directory`, partial downloads included.
    private static func bytes(in directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey]
        guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        return files.reduce(into: Int64(0)) { total, file in
            total += Int64((try? (file as? URL)?.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)
        }
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
        // `detectLanguage` must be asked for: left alone WhisperKit assumes English, and the
        // model then transcribes speech in any other language as an English translation.
        let options = DecodingOptions(
            task: .transcribe, language: lang, detectLanguage: lang == nil, skipSpecialTokens: true,
            wordTimestamps: true)
        // Decoding reports per 30-second window, so a short clip has one step and the
        // fraction stays 0 until it ends. The words decoded so far are the honest progress.
        let covered = pipe.progress
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options) { step in
            let tail = step.text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines).suffix(70)
            progress(min(1, covered.fractionCompleted), tail.isEmpty ? "Transcribing…" : "…\(tail)")
            return nil
        }
        try Task.checkCancellation()
        progress(1, "Done")
        let transcript = TranscriptMapping.transcript(
            from: results, duration: duration.isFinite ? duration : 0, requestedLanguage: lang)
        // Replacing someone's captions with nothing is never what they asked for.
        guard !transcript.segments.isEmpty else { throw TranscriptionError.noSpeech }
        return transcript
    }
}
