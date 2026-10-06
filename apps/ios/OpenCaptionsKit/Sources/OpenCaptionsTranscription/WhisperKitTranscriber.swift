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

    /// When Whisper dislikes a window (repetitive, or low confidence) it decodes it again hotter,
    /// five times by default, and every retry costs as much as the first decode: on music, which
    /// trips those checks all the time, that is the pause of tens of seconds. Two retries keep the
    /// recovery and bound the wait to three decodes of a window.
    static let fallbackRetries = 2

    public func isDownloaded(_ id: String) -> Bool {
        folder(for: id) != nil
    }

    /// What a downloaded model takes on disk, in bytes (0 if it is not downloaded).
    public func sizeOnDisk(_ id: String) -> Int64 {
        folder(for: id).map(Self.bytes(in:)) ?? 0
    }

    /// Removes a downloaded model. It downloads again the next time it is chosen.
    public func delete(_ id: String) throws {
        guard let folder = folder(for: id) else { return }
        try FileManager.default.removeItem(at: folder)
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

    /// The language of the loudest stretches of audio, or nil if the model cannot say.
    private func detectLanguage(of samples: [Float], with pipe: WhisperKit) async -> String? {
        var verdicts: [[String: Float]] = []
        for window in LanguageGuess.loudestWindows(in: samples) {
            if let verdict = try? await pipe.detectLangauge(audioArray: Array(samples[window])) {
                verdicts.append(verdict.langProbs)
            }
        }
        return LanguageGuess.winner(of: verdicts)
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

        progress(0, "Loading model into RAM…")
        let pipe = try await WhisperKit(
            WhisperKitConfig(
                model: info.variant, downloadBase: modelsDirectory, modelFolder: folder.path,
                verbose: false, load: true, download: false))

        var lang = language.flatMap { $0 == "auto" ? nil : $0 }
        // Judge the language from where the speech is, not from the first 30 seconds. An
        // English-only model has nothing to detect.
        if lang == nil, !info.englishOnly {
            progress(0, "Detecting the language…")
            lang = await detectLanguage(of: samples, with: pipe)
        }
        // `detectLanguage` must be asked for when nothing else decided: left alone WhisperKit
        // assumes English, and the model then transcribes other speech as an English translation.
        let options = DecodingOptions(
            task: .transcribe, language: lang, temperatureFallbackCount: Self.fallbackRetries,
            detectLanguage: lang == nil && !info.englishOnly, skipSpecialTokens: true, wordTimestamps: true)
        // Decoding reports per 30-second window, so a short clip is one step and the fraction
        // stays 0 until it ends; the screen shows a spinner until there is a fraction.
        let covered = pipe.progress
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options) { _ in
            progress(min(1, covered.fractionCompleted), "Transcribing…")
            return nil
        }
        try Task.checkCancellation()
        progress(1, "Done")
        let transcript = TranscriptMapping.transcript(
            from: results, duration: duration.isFinite ? duration : 0, requestedLanguage: language.flatMap { $0 == "auto" ? nil : $0 })
        // Replacing someone's captions with nothing is never what they asked for.
        guard !transcript.segments.isEmpty else { throw TranscriptionError.noSpeech }
        return transcript
    }
}
