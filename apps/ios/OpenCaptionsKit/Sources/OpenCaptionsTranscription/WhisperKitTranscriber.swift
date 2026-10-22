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

    /// Lets go of the model in memory, for work that needs the memory more (a save, with 4K frames in
    /// flight): the next transcription loads it again.
    public func releaseModels() {
        Task { [pipelines] in await pipelines.release() }
    }

    /// Starts loading a downloaded model into memory, so that it is ready (or nearly) by the time
    /// someone has picked a language and asked to transcribe. Loading is the longest wait there is,
    /// and the model stays loaded for the next transcription.
    public func preload(_ id: String) {
        guard let info = SpeechModels.model(id), let folder = folder(for: id) else { return }
        Task { _ = try? await pipeline(info, folder: folder) }
    }

    private func pipeline(_ info: SpeechModel, folder: URL) async throws -> WhisperKit {
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
        guard let model = SpeechModels.model(id) else { return nil }
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
        folder(for: id).map(DiskUsage.bytes(in:)) ?? 0
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
        guard let model = SpeechModels.model(id) else { throw TranscriptionError.unknownModel(id) }
        if let folder = folder(for: id) { return folder }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        // WhisperKit reports progress per file, and a model is a few dozen small files and
        // two or three huge ones, so its fraction races to ~75% and then crawls. Bytes on
        // disk (partial files are written as they arrive) against the model's known size
        // move steadily instead.
        let expected = Double(model.megabytes) * 1_000_000
        let baseline = DiskUsage.bytes(in: modelsDirectory)
        let directory = modelsDirectory
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                let done = Double(max(0, DiskUsage.bytes(in: directory) - baseline))
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

    public func transcribe(
        source: URL, language: String?, model: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Transcript {
        guard let info = SpeechModels.model(model) else { throw TranscriptionError.unknownModel(model) }
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

        progress(0, KitStrings.localized("Optimizing for this device… A few minutes, once. Later transcriptions are much faster."))
        let pipe = try await loading.value.pipe

        // The language is always chosen (the screen offers no "detect"): left alone WhisperKit would
        // assume English and translate other speech, so a missing one is the device's.
        let lang = language.flatMap { $0 == "auto" ? nil : $0 } ?? Locale.current.language.languageCode?.identifier ?? "en"
        let options = DecodingOptions(
            task: .transcribe, language: lang, temperatureFallbackCount: Self.fallbackRetries,
            skipSpecialTokens: true, wordTimestamps: true)
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
                in: transcript, samples: samples, duration: seconds, language: lang,
                pipe: pipe, progress: progress)
        }
        progress(1, KitStrings.localized("Done"))
        // Replacing someone's captions with nothing is never what they asked for.
        guard !transcript.segments.isEmpty else { throw TranscriptionError.noSpeech }
        return transcript
    }

    /// Decodes again each long stretch without words that is not quiet, without Whisper's "this
    /// window is silent" judgement, which skips a whole window of music or noisy speech (see
    /// `TranscriptGaps`). Each stretch is read twice, the second window shifted, and only the words
    /// both readings give are kept.
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

        /// The words of one window of the audio, with times from the start of the recording.
        func read(from lower: Double, to upper: Double) async -> [Word] {
            let start = max(0, lower)
            let first = Int(start * rate)
            let last = min(samples.count, Int(upper * rate))
            guard last - first > Int(rate) else { return [] }
            guard let results = try? await pipe.transcribe(audioArray: Array(samples[first..<last]), decodeOptions: options)
            else { return [] }
            let window = TranscriptMapping.transcript(
                from: results, duration: Double(last - first) / rate, requestedLanguage: language)
            return window.segments.flatMap(\.words).map {
                Word(text: $0.text, start: $0.start + start, end: $0.end + start, confidence: $0.confidence)
            }
        }

        var fills: [(gap: ClosedRange<Double>, transcript: Transcript)] = []
        for (index, gap) in gaps.enumerated() {
            try Task.checkCancellation()
            let inside = min(samples.count, Int(gap.lowerBound * rate))..<min(samples.count, Int(gap.upperBound * rate))
            guard !TranscriptGaps.isQuiet(samples[inside], rate: rate) else { continue }
            progress(1, KitStrings.localized("Second pass (\(index + 1) of \(gaps.count))…"))
            let first = await read(from: gap.lowerBound - 0.3, to: gap.upperBound + 0.3)
            guard !first.isEmpty else { continue }
            let second = await read(from: min(gap.lowerBound + 0.9, gap.upperBound - 2), to: gap.upperBound + 1.3)
            let words = TranscriptGaps.kept(first, second, in: gap)
                .map { Word(text: $0.text, start: max(0, $0.start - gap.lowerBound), end: max(0, $0.end - gap.lowerBound), confidence: $0.confidence) }
            guard let begin = words.first, let end = words.last else { continue }
            let segment = TranscriptSegment(
                id: "fill", words: words, start: begin.start, end: end.end,
                text: words.map(\.text).joined(separator: " "))
            fills.append((gap, Transcript(language: language, languageDetection: .manual, duration: gap.upperBound - gap.lowerBound, segments: [segment])))
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
