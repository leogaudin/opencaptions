import AVFoundation
import Foundation
import Testing
@testable import OpenCaptionsKit

@Suite struct TranscriptionSupportTests {
    @Test func theModelTableIsAscendingAndTheDefaultIsInIt() {
        let models = WhisperModels.all
        #expect(Set(models.map(\.id)).count == models.count)
        #expect(models.map(\.megabytes) == models.map(\.megabytes).sorted())
        #expect(WhisperModels.model(WhisperModels.defaultID)?.id == "base")
        #expect(WhisperModels.model("base.en")?.englishOnly == true)
        #expect(WhisperModels.model("base")?.englishOnly == false)
        #expect(WhisperModels.model("nonsense") == nil)
        #expect(models.allSatisfy { !$0.variant.isEmpty && $0.megabytes > 0 })
    }

    @Test func audioComesOutAs16kHzMono() async throws {
        let samples = try await AudioExtractor.samples(from: try SampleVideo.tone(seconds: 2))
        #expect(abs(samples.count - 32_000) < 400, "two seconds at 16 kHz, got \(samples.count)")
        let rms = (samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count)).squareRoot()
        // The system's mixdown to mono keeps power (channels sum at -3 dB), so a
        // correlated stereo tone comes out ~1.4x louder; what matters is that it is there.
        #expect(rms > 0.3 && rms < 0.8, "the tone survives resampling, got \(rms)")
    }

    @Test func aVideoWithoutAudioIsReportedNotSilentlyEmpty() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        try await SampleVideo.write(to: url)
        await #expect(throws: TranscriptionError.noAudio) {
            try await AudioExtractor.samples(from: url)
        }
    }

    // MARK: Language detection

    @Test func theLoudestStretchesAreJudgedNotTheFirst() {
        let w = LanguageGuess.windowSamples
        // Five windows: silent, quiet, loud, silent, loudest.
        var samples = [Float](repeating: 0, count: 5 * w)
        for i in w..<(2 * w) { samples[i] = 0.05 }
        for i in (2 * w)..<(3 * w) { samples[i] = 0.4 }
        for i in (4 * w)..<(5 * w) { samples[i] = 0.8 }
        let picked = LanguageGuess.loudestWindows(in: samples, count: 2)
        #expect(picked == [(2 * w)..<(3 * w), (4 * w)..<(5 * w)], "in time order, the loud ones")
        #expect(!picked.contains(0..<w), "never just the silent start")
    }

    @Test func aShortClipIsOneWindowAndNothingIsNothing() {
        let short = [Float](repeating: 0.1, count: 16_000 * 5)
        #expect(LanguageGuess.loudestWindows(in: short) == [0..<short.count])
        #expect(LanguageGuess.loudestWindows(in: []).isEmpty)
    }

    @Test func aScrapAtTheEndIsNotAWindowOfItsOwn() {
        let w = LanguageGuess.windowSamples
        var samples = [Float](repeating: 0.01, count: w + 1_000)  // a window and a 1000-sample scrap
        for i in w..<samples.count { samples[i] = 0.9 }  // the scrap is loud, but says little
        #expect(LanguageGuess.loudestWindows(in: samples, count: 3) == [0..<w])
    }

    @Test func theVerdictsOfSeveralWindowsAreAddedUp() {
        // One window leans French, two lean Spanish: Spanish wins on the sum.
        let probabilities: [[String: Float]] = [["fr": 0.5, "es": 0.4], ["es": 0.6, "fr": 0.1], ["es": 0.45, "nl": 0.3]]
        #expect(LanguageGuess.winner(of: probabilities) == "es")
        // Log probabilities (all at or below zero) are exponentiated first.
        let logs: [[String: Float]] = [["fr": log(0.2), "es": log(0.7)], ["fr": log(0.6), "es": log(0.3)]]
        #expect(LanguageGuess.winner(of: logs) == "es")
        #expect(LanguageGuess.winner(of: []) == nil)
    }
}
