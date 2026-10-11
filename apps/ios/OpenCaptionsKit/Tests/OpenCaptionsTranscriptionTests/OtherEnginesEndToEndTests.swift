import Foundation
import Testing
@testable import OpenCaptionsKit
@testable import OpenCaptionsTranscription

/// Parakeet and Apple's model on real speech, as the Whisper one is in `WhisperKitEndToEndTests`:
/// `OC_WHISPER_E2E=1 swift test`. Parakeet downloads about 480 MB the first time; Apple's needs macOS 26.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OC_WHISPER_E2E"] != nil), .serialized)
struct OtherEnginesEndToEndTests {
    func speech(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        return url
    }

    func heard(_ transcript: Transcript) -> [String] {
        transcript.words.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }
    }

    @Test func parakeetTranscribesASpokenSentence() async throws {
        let transcriber = LocalTranscriber(
            modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("oc-models"))
        try await transcriber.download("parakeet-tdt-0.6b-v3")
        let transcript = try await transcriber.transcribe(
            source: try speech("Hello world. This is a test of open captions."), language: "en",
            model: "parakeet-tdt-0.6b-v3", progress: { _, _ in })
        let spoken = heard(transcript)
        #expect(spoken.contains("hello") && spoken.contains("test"), "heard: \(spoken)")
        #expect(transcript.words.allSatisfy { $0.end >= $0.start && $0.start >= 0 })
    }

    @Test func appleSpeechTranscribesASpokenSentence() async throws {
        guard #available(macOS 26.0, iOS 26.0, *) else { return }
        let transcriber = LocalTranscriber(
            modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("oc-models"))
        let transcript = try await transcriber.transcribe(
            source: try speech("Hello world. This is a test of open captions."), language: "en",
            model: SpeechModels.appleSpeechID, progress: { _, _ in })
        let spoken = heard(transcript)
        #expect(spoken.contains("hello") && spoken.contains("test"), "heard: \(spoken)")
        #expect(transcript.words.allSatisfy { $0.end >= $0.start && $0.start >= 0 })
    }
}
