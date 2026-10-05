import Foundation
import Testing
@testable import OpenCaptionsKit
@testable import OpenCaptionsTranscription

/// The real thing: a spoken sentence, a downloaded model, Core ML. It needs the
/// network and a minute, so it only runs when asked: `OC_WHISPER_E2E=1 swift test`.
/// `OC_WHISPER_MODELS` keeps the downloaded model between runs.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OC_WHISPER_E2E"] != nil))
struct WhisperKitEndToEndTests {
    func speech(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        return url
    }

    @Test func aSpokenSentenceBecomesATimedTranscript() async throws {
        let models = ProcessInfo.processInfo.environment["OC_WHISPER_MODELS"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("oc-models")
        let transcriber = WhisperKitTranscriber(modelsDirectory: models)
        try await transcriber.download("tiny")
        #expect(transcriber.isDownloaded("tiny"))

        let audio = try speech("Hello world. This is a test of open captions.")
        let progress = ProgressLog()
        let transcript = try await transcriber.transcribe(
            source: audio, language: "en", model: "tiny", progress: { f, m in progress.add(f, m) })

        let spoken = transcript.words.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        #expect(spoken.contains("hello"), "heard: \(spoken)")
        #expect(spoken.contains("test"), "heard: \(spoken)")
        #expect(transcript.languageDetection == .manual && transcript.language == "en")
        let words = transcript.words
        #expect(!words.isEmpty && words.allSatisfy { $0.end >= $0.start && $0.start >= 0 })
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.end <= $1.start + 0.5 }, "in time order")
        #expect(transcript.duration > 1)
        #expect(progress.fractions.last == 1 && progress.fractions == progress.fractions.sorted())
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    var fractions: [Double] { lock.withLock { values } }
    func add(_ fraction: Double, _ message: String = "") { lock.withLock { values.append(fraction) } }
}
