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
}
