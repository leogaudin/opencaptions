import AVFoundation
import Foundation
import Testing
@testable import OpenCaptionsKit

@Suite struct TranscriptionSupportTests {
    @Test func theModelTableIsAscendingAndTheDefaultIsInIt() {
        let models = SpeechModels.all.filter { !$0.isBuiltIn }
        #expect(Set(SpeechModels.all.map(\.id)).count == SpeechModels.all.count)
        #expect(models.map(\.megabytes) == models.map(\.megabytes).sorted())
        #expect(SpeechModels.model(SpeechModels.defaultID)?.id == SpeechModels.parakeetUltraID)
        #expect(SpeechModels.model("large-v3") == nil, "the one Large v3 is the 627 MB build")
        #expect(SpeechModels.all.allSatisfy { !$0.englishOnly }, "multilingual models only")
        #expect(SpeechModels.model("nonsense") == nil)
        #expect(models.allSatisfy { $0.megabytes > 0 })
        #expect(models.filter { $0.engine == .whisperKit }.allSatisfy { !$0.variant.isEmpty }, "WhisperKit names a folder")
    }

    @Test func theModelChosenLastIsTheStartingOneIfThePhoneStillOffersIt() {
        #expect(SpeechModels.initial(stored: "small") == "small")
        #expect(SpeechModels.initial(stored: "large-v3-turbo") == "large-v3-turbo")
        #expect(SpeechModels.initial(stored: "") == SpeechModels.defaultID, "nothing chosen yet")
        #expect(SpeechModels.initial(stored: "large-v3") == SpeechModels.defaultID, "a model that is gone")
    }

    @Test func aModelThatCoversSomeLanguagesIsNeverAskedForAnother() throws {
        for id in [SpeechModels.parakeetUltraID, SpeechModels.parakeetReduxID] {
            let parakeet = try #require(SpeechModels.model(id))
            #expect(parakeet.engine == .parakeet)
            #expect(parakeet.covers("fr") && parakeet.covers("ru"))
            #expect(!parakeet.covers("ja") && !parakeet.covers("tr") && !parakeet.covers("zh"))
            #expect(parakeet.covers(nil) && parakeet.covers("auto"), "detecting is the model's business")
        }
        let whisper = try #require(SpeechModels.model("large-v3-turbo"))
        #expect(whisper.covers("ja") && whisper.covers("tr"))
    }

    @Test func appleSpeechIsBuiltInAndOnlyWhereIOSHasIt() {
        let apple = SpeechModels.model(SpeechModels.appleSpeechID)
        if #available(iOS 26.0, macOS 26.0, *) {
            #expect(apple?.isBuiltIn == true)
            #expect(apple?.engine == .appleSpeech)
        } else {
            #expect(apple == nil)
        }
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
