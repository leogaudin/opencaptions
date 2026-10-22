import AVFoundation
import FluidAudio
import Foundation
import OpenCaptionsKit
#if canImport(UIKit)
    import UIKit
#endif

/// On-device transcription with Parakeet (Ultra, Redux) through FluidAudio (Core ML, the Neural Engine). The
/// model is fetched on demand into FluidAudio's own cache (excluded from backup) and never bundled.
/// FluidAudio cuts long audio into windows itself, and decodes again a window that came back empty.
public final class ParakeetTranscriber: Transcriber {
    /// The FluidAudio build of a model id; Ultra for any other.
    static func version(of id: String) -> AsrModelVersion {
        id == SpeechModels.parakeetReduxID ? .redux : .ultra
    }

    private static func folder(_ id: String) -> URL { AsrModels.defaultCacheDirectory(for: version(of: id)) }
    private let managers = ManagerCache()

    public init() {
        #if canImport(UIKit)
            // A loaded model is a few hundred MB: it is let go when memory is wanted, and when the app
            // leaves the screen, as WhisperKit's is.
            for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [managers] _ in
                    Task { await managers.release() }
                }
            }
        #endif
    }

    public func isDownloaded(_ id: String) -> Bool {
        AsrModels.modelsExist(at: Self.folder(id), version: Self.version(of: id))
    }

    /// What the model takes on disk, in bytes (0 if it is not downloaded).
    public func sizeOnDisk(_ id: String) -> Int64 {
        isDownloaded(id) ? DiskUsage.bytes(in: Self.folder(id)) : 0
    }

    /// Removes the model. It downloads again the next time it is chosen.
    public func delete(_ id: String) throws {
        let folder = Self.folder(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public func releaseModels() {
        Task { [managers] in await managers.release() }
    }

    /// Starts loading the downloaded model, so it is ready (or nearly) by the time someone has picked a
    /// language. Loading is the longest wait there is, and the model stays loaded.
    public func preload(_ id: String) {
        guard isDownloaded(id) else { return }
        Task { _ = try? await managers.manager(Self.version(of: id)) }
    }

    /// Downloads the model, reporting the fraction done against its known size (megabytes), as bytes
    /// arrive on disk. Does nothing if it is there.
    public func download(_ id: String, megabytes: Int, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !isDownloaded(id) else { return }
        let expected = Double(megabytes) * 1_000_000
        let folder = Self.folder(id)
        let baseline = DiskUsage.bytes(in: folder)
        let watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                progress(min(0.99, Double(max(0, DiskUsage.bytes(in: folder) - baseline)) / expected))
            }
        }
        defer { watcher.cancel() }
        // Only the files: `AsrModels.download` also loads (compiles) each model, minutes of waiting with
        // nothing to show. Loading is the first transcription's, which says what it is doing.
        try await ModelHub.download(
            id == SpeechModels.parakeetReduxID ? .parakeetRedux : .parakeetUltra, to: folder.deletingLastPathComponent())
        watcher.cancel()
        _ = await watcher.result
        progress(1)
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
    }

    public func transcribe(
        source: URL, language: String?, model: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Transcript {
        guard isDownloaded(model) else { throw TranscriptionError.modelNotDownloaded(model) }
        let version = Self.version(of: model)
        let requested = language.flatMap { $0 == "auto" ? nil : $0 }
        if let requested, !SpeechModels.parakeetLanguages.contains(requested) {
            throw TranscriptionError.unsupportedLanguage(requested)
        }

        // The model loads while the audio is read (and may already be loaded, or loading, from `preload`).
        let loading = Task { try await managers.manager(version) }
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

        // The first load of a build on a device is Core ML preparing the Neural Engine plan, which takes up to
        // minutes and shows nothing: the screen says what it is doing.
        progress(0, KitStrings.localized("Optimizing for this device… A few minutes, once. Later transcriptions are much faster."))
        let manager = try await loading.value

        let fractions = await manager.transcriptionProgressStream
        let reporting = Task {
            do {
                for try await fraction in fractions {
                    progress(min(1, fraction), KitStrings.localized("Transcribing…"))
                }
            } catch {}
        }
        defer { reporting.cancel() }

        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        try Task.checkCancellation()

        let seconds = duration.isFinite ? duration : Double(samples.count) / AudioExtractor.sampleRate
        let transcript = TokenMapping.transcript(
            from: Self.tokens(of: result, duration: seconds), duration: seconds, requestedLanguage: requested,
            languages: SpeechModels.parakeetLanguages)
        progress(1, KitStrings.localized("Done"))
        // Replacing someone's captions with nothing is never what they asked for.
        guard !transcript.segments.isEmpty else { throw TranscriptionError.noSpeech }
        return transcript
    }

    /// The model's token timings; if it gave none, its text spread evenly over the audio, which reads far
    /// better than dropping recognised speech.
    private static func tokens(of result: ASRResult, duration: Double) -> [SpeechToken] {
        if let timings = result.tokenTimings, !timings.isEmpty {
            return timings.map {
                SpeechToken(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: Double($0.confidence))
            }
        }
        let words = result.text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        let step = duration / Double(words.count)
        return words.enumerated().map { index, word in
            SpeechToken(text: " " + word, start: step * Double(index), end: step * Double(index + 1))
        }
    }
}

/// The one loaded model, shared by whoever asks for it while it loads and afterwards, so that it is loaded
/// once and not for every transcription.
private actor ManagerCache {
    private var current: Task<AsrManager, Error>?
    private var currentVersion: AsrModelVersion?

    /// The loaded model; another version's is let go first (a model is hundreds of MB, so only one is held).
    func manager(_ version: AsrModelVersion) async throws -> AsrManager {
        if let current, currentVersion == version { return try await value(of: current) }
        await release()
        let task = Task { () throws -> AsrManager in
            let models = try await AsrModels.loadFromCache(version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        current = task
        currentVersion = version
        return try await value(of: task)
    }

    private func value(of task: Task<AsrManager, Error>) async throws -> AsrManager {
        do {
            return try await task.value
        } catch {
            // A failed load is not kept: the next one tries again.
            current = nil
            currentVersion = nil
            throw error
        }
    }

    func release() async {
        guard let task = current else { return }
        current = nil
        currentVersion = nil
        task.cancel()
        if let manager = try? await task.value { await manager.cleanup() }
    }
}
