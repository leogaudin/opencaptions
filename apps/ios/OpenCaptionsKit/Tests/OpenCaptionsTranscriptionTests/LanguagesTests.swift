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
        let parakeet = try #require(SpeechModels.model(SpeechModels.parakeetUltraID))
        let offered = await TranscriptionLanguages.offered(by: parakeet).map(\.code)
        #expect(offered.contains("fr") && !offered.contains("ja"))
        let whisper = try #require(SpeechModels.model("large-v3-turbo"))
        #expect(await TranscriptionLanguages.offered(by: whisper).count == TranscriptionLanguages.all.count)
    }

    @Test func aModelShowsAFewFlagsAndHowManyLanguagesAreLeft() async throws {
        let parakeet = try #require(SpeechModels.model(SpeechModels.parakeetUltraID))
        let some = TranscriptionLanguages.glance(of: await TranscriptionLanguages.offered(by: parakeet))
        #expect(some.flags == ["\u{1F1EC}\u{1F1E7}", "\u{1F1EA}\u{1F1F8}", "\u{1F1EB}\u{1F1F7}"], "English, Spanish, French: the first it covers")
        #expect(some.more == 25 - 3)
        let few = [TranscriptionLanguage(code: "de", label: "German")]
        #expect(TranscriptionLanguages.glance(of: few).more == 0)
        #expect(TranscriptionLanguages.glance(of: []).flags.isEmpty)
    }

    @Test func theStartingLanguageIsTheRememberedOneElseTheDevicesElseTheFirst() {
        let list = [TranscriptionLanguage(code: "de", label: "German"), TranscriptionLanguage(code: "fr", label: "French")]
        #expect(TranscriptionLanguages.initial(stored: "fr", among: list, device: "de") == "fr")
        #expect(TranscriptionLanguages.initial(stored: "", among: list, device: "fr") == "fr", "nothing remembered: the device's")
        #expect(TranscriptionLanguages.initial(stored: "auto", among: list, device: "de") == "de", "the old auto choice is dropped")
        #expect(TranscriptionLanguages.initial(stored: "ja", among: list, device: "es") == "de", "not offered: the first")
    }
}
