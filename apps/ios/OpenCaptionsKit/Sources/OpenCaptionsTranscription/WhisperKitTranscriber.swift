import AVFoundation
import Foundation
import OpenCaptionsKit
import WhisperKit
#if canImport(UIKit)
    import UIKit
#endif

/// On-device transcription with WhisperKit (Core ML, the Neural Engine). Models are
/// fetched on demand into `modelsDirectory` (the caller excludes it from backup) and
/// never bundled.
public final class WhisperKitTranscriber: Transcriber {
    public let modelsDirectory: URL
    private let pipelines = PipelineCache()

    public init(modelsDirectory: URL) {
        self.modelsDirectory = modelsDirectory
        #if canImport(UIKit)
            // A loaded model is a few hundred MB to a GB: it is let go when memory is wanted, and when
            // the app leaves the screen, where a big one is what gets it killed.
            for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [pipelines] _ in
                    Task { await pipelines.release() }
                }
            }
        #endif
    }

    /// Starts loading a downloaded model into memory, so that it is ready (or nearly) by the time
    /// someone has picked a language and asked to transcribe. Loading is the longest wait there is,
    /// and the model stays loaded for the next transcription.
    public func preload(_ id: String) {
        guard let info = WhisperModels.model(id), let folder = folder(for: id) else { return }
        Task { _ = try? await pipeline(info, folder: folder) }
    }

    private func pipeline(_ info: WhisperModel, folder: URL) async throws -> WhisperKit {
        let base = modelsDirectory
        return try await pipelines.pipeline(for: info.id) {
            Loaded(
                pipe: try await WhisperKit(
                    WhisperKitConfig(
                        model: info.variant, downloadBase: base, modelFolder: folder.path,
                        verbose: false, load: true, download: false)))
        }.pipe
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
        // Stopped before the last report, or one more of "99%" could follow it.
        watcher.cancel()
        _ = await watcher.result
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
    private func detectLanguage(of samples: [Float], with pipe: WhisperKit) async throws -> String? {
        var verdicts: [[String: Float]] = []
        for window in LanguageGuess.loudestWindows(in: samples) {
            if let verdict = try? await pipe.detectLangauge(audioArray: Array(samples[window])) {
                verdicts.append(verdict.langProbs)
            }
        }
        let winner = LanguageGuess.winner(of: verdicts)
        // Kept in the diagnostics: a wrong guess makes the model translate the speech into that language.
        let tops = verdicts.map { v in v.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: ", ") }
        Diagnostics.log("language detection: \(winner.map { "\($0.language) \(String(format: "%.2f", $0.confidence))" } ?? "none") from \(tops.map { "[\($0)]" }.joined(separator: " "))")
        guard let winner else { return nil }
        // Too unsure to force on the model: the user is asked, and the loaded model is kept for the retry.
        guard winner.confidence >= LanguageGuess.minimumConfidence else {
            throw TranscriptionError.unsureLanguage(guess: winner.language)
        }
        return winner.language
    }

    public func transcribe(
        source: URL, language: String?, model: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Transcript {
        guard let info = WhisperModels.model(model) else { throw TranscriptionError.unknownModel(model) }
        guard let folder = folder(for: model) else { throw TranscriptionError.modelNotDownloaded(model) }

        // The model loads while the audio is read (and may already be loaded, or loading, from
        // `preload`).
        let loading = Task { Loaded(pipe: try await pipeline(info, folder: folder)) }
        progress(0, KitStrings.localized("Reading the audio…"))
        let samples: [Float]
        let duration: Double
        do {
            samples = try await AudioExtractor.samples(from: source)
            duration = try await AVURLAsset(url: source).load(.duration).seconds
        } catch {
            loading.cancel()
            throw error
        }

        progress(0, KitStrings.localized("Loading the model… the first time on this phone can take a few minutes."))
        let pipe = try await loading.value.pipe

        var lang = language.flatMap { $0 == "auto" ? nil : $0 }
        // Judge the language from where the speech is, not from the first 30 seconds. An
        // English-only model has nothing to detect.
        if lang == nil, !info.englishOnly {
            progress(0, KitStrings.localized("Detecting the language…"))
            lang = try await detectLanguage(of: samples, with: pipe)
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
            progress(min(1, covered.fractionCompleted), KitStrings.localized("Transcribing…"))
            return nil
        }
        try Task.checkCancellation()
        let requested = language.flatMap { $0 == "auto" ? nil : $0 }
        let seconds = duration.isFinite ? duration : 0
        var transcript = TranscriptMapping.transcript(from: results, duration: seconds, requestedLanguage: requested)
        if !transcript.segments.isEmpty {
            transcript = try await fillGaps(
                in: transcript, samples: samples, duration: seconds, language: lang ?? transcript.language,
                pipe: pipe, progress: progress)
        }
        progress(1, KitStrings.localized("Done"))
        // Replacing someone's captions with nothing is never what they asked for.
        guard !transcript.segments.isEmpty else { throw TranscriptionError.noSpeech }
        return transcript
    }

    /// Decodes again each long stretch without words, without Whisper's "this window is silent"
    /// judgement, which skips a whole window of music or noisy speech (see `TranscriptGaps`).
    private func fillGaps(
        in transcript: Transcript, samples: [Float], duration: Double, language: String,
        pipe: WhisperKit, progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Transcript {
        let rate = AudioExtractor.sampleRate
        let gaps = TranscriptGaps.find(in: transcript, duration: duration).prefix(12)
        guard !gaps.isEmpty else { return transcript }
        var options = DecodingOptions(
            task: .transcribe, language: language, temperatureFallbackCount: Self.fallbackRetries,
            skipSpecialTokens: true, wordTimestamps: true)
        options.noSpeechThreshold = nil
        options.logProbThreshold = nil
        options.firstTokenLogProbThreshold = nil
        var fills: [(gap: ClosedRange<Double>, transcript: Transcript)] = []
        for (index, gap) in gaps.enumerated() {
            try Task.checkCancellation()
            progress(1, KitStrings.localized("Checking for missed speech (\(index + 1) of \(gaps.count))…"))
            let from = max(0, Int(gap.lowerBound * rate))
            let to = min(samples.count, Int(gap.upperBound * rate))
            guard to - from > Int(rate) else { continue }
            guard let results = try? await pipe.transcribe(audioArray: Array(samples[from..<to]), decodeOptions: options)
            else { continue }
            fills.append((gap, TranscriptMapping.transcript(from: results, duration: gap.upperBound - gap.lowerBound, requestedLanguage: language)))
        }
        return TranscriptGaps.merge(transcript, fills: fills)
    }
}

/// A loaded pipeline, which WhisperKit does not mark as sendable. It is used by one transcription at
/// a time, which the app guarantees (a second one is refused while one runs).
private struct Loaded: @unchecked Sendable { let pipe: WhisperKit }

/// The one model that is loaded, shared by whoever asks for it while it loads and afterwards, so
/// that a model is loaded once and not for every transcription.
private actor PipelineCache {
    private var current: (id: String, task: Task<Loaded, Error>)?

    func pipeline(for id: String, load: @escaping @Sendable () async throws -> Loaded) async throws -> Loaded {
        if let current, current.id == id { return try await value(of: current.task, id: id) }
        let task = Task { try await load() }
        current = (id, task)
        return try await value(of: task, id: id)
    }

    private func value(of task: Task<Loaded, Error>, id: String) async throws -> Loaded {
        do {
            return try await task.value
        } catch {
            // A failed load is not kept: the next one tries again.
            if current?.id == id { current = nil }
            throw error
        }
    }

    func release() { current = nil }
}
