import Foundation
import Testing
@testable import OpenCaptionsKit
@testable import OpenCaptionsTranscription

@Suite struct LanguagesTests {
    @Test func aLanguageHasAFlagAndTheOnesWithoutACountryAGlobe() {
        #expect(TranscriptionLanguages.flag(for: "fr") == "\u{1F1EB}\u{1F1F7}")
        #expect(TranscriptionLanguages.flag(for: "ja") == "\u{1F1EF}\u{1F1F5}")
        #expect(TranscriptionLanguages.flag(for: "bo") == "\u{1F310}")
        let withNone = TranscriptionLanguages.all.filter { $0.flag == "\u{1F310}" }.map(\.code)
        #expect(withNone.count < 6, "most languages have a flag: \(withNone)")
    }

    @Test func aModelIsOnlyOfferedItsLanguages() async throws {
        let parakeet = try #require(SpeechModels.model("parakeet-tdt-0.6b-v3"))
        let offered = await TranscriptionLanguages.offered(by: parakeet).map(\.code)
        #expect(offered.contains("fr") && !offered.contains("ja"))
        let whisper = try #require(SpeechModels.model("large-v3-turbo"))
        #expect(await TranscriptionLanguages.offered(by: whisper).count == TranscriptionLanguages.all.count)
    }
}
