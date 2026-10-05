import Foundation
import Testing
import WhisperKit
@testable import OpenCaptionsKit
@testable import OpenCaptionsTranscription

@Suite struct TranscriptMappingTests {
    func timing(_ word: String, _ start: Float, _ end: Float, _ p: Float = 0.9) -> WordTiming {
        WordTiming(word: word, tokens: [], start: start, end: end, probability: p)
    }

    func segment(_ text: String, _ start: Float, _ end: Float, words: [WordTiming]?) -> TranscriptionSegment {
        TranscriptionSegment(start: start, end: end, text: text, words: words)
    }

    func result(_ segments: [TranscriptionSegment], language: String = "en") -> TranscriptionResult {
        TranscriptionResult(text: "", segments: segments, language: language, timings: TranscriptionTimings())
    }

    func ids() -> () -> String {
        var n = 0
        return { n += 1; return "seg-\(n)" }
    }

    @Test func wordsAreTrimmedAndEmptyOnesDropped() {
        let r = result([
            segment(" Hello world", 0, 1, words: [
                timing(" Hello", 0, 0.4), timing(" ", 0.4, 0.5), timing(" world", 0.5, 1, 1.4),
            ])
        ])
        let t = TranscriptMapping.transcript(from: [r], duration: 5, requestedLanguage: nil, makeID: ids())
        #expect(t.segments.count == 1)
        let seg = t.segments[0]
        #expect(seg.id == "seg-1")
        #expect(seg.words.map(\.text) == ["Hello", "world"])
        #expect(seg.text == "Hello world")
        #expect((seg.start, seg.end) == (0, 1))
        #expect(seg.words[1].confidence == 1, "probability is clamped to 0...1")
        #expect(abs(seg.words[0].confidence - 0.9) < 1e-6)
    }

    @Test func specialTokensNeverReachTheCaptions() {
        let r = result([segment("<|0.00|> Hi <|1.00|>", 0, 1, words: [timing("<|0.00|>", 0, 0), timing(" Hi", 0, 1)])])
        let t = TranscriptMapping.transcript(from: [r], duration: 1, requestedLanguage: nil)
        #expect(t.words.map(\.text) == ["Hi"])
    }

    @Test func aSegmentWithoutWordTimingsIsSpreadAcrossItsOwnSpan() {
        let r = result([segment(" one two three four", 2, 6, words: nil)])
        let t = TranscriptMapping.transcript(from: [r], duration: 10, requestedLanguage: nil)
        let words = t.segments[0].words
        #expect(words.map(\.text) == ["one", "two", "three", "four"])
        #expect(words.map(\.start) == [2, 3, 4, 5])
        #expect(words.last?.end == 6)
        #expect(t.segments[0].start == 2 && t.segments[0].end == 6)
    }

    @Test func aSegmentWithNoWordsAtAllIsDropped() {
        let r = result([segment("  ", 0, 1, words: []), segment("kept", 1, 2, words: [timing("kept", 1, 2)])])
        let t = TranscriptMapping.transcript(from: [r], duration: 3, requestedLanguage: nil)
        #expect(t.segments.count == 1 && t.segments[0].text == "kept")
    }

    @Test func segmentsFromSeveralResultsComeOutInTimeOrder() {
        let a = result([segment("later", 5, 6, words: [timing("later", 5, 6)])])
        let b = result([segment("first", 0, 1, words: [timing("first", 0, 1)])])
        let t = TranscriptMapping.transcript(from: [a, b], duration: 6, requestedLanguage: nil)
        #expect(t.words.map(\.text) == ["first", "later"])
    }

    @Test func languageAndDetectionFollowTheRequest() {
        let r = result([segment("hola", 0, 1, words: [timing("hola", 0, 1)])], language: "es")
        let auto = TranscriptMapping.transcript(from: [r], duration: 1, requestedLanguage: nil)
        #expect(auto.language == "es" && auto.languageDetection == .auto)
        let manual = TranscriptMapping.transcript(from: [r], duration: 1, requestedLanguage: "es")
        #expect(manual.languageDetection == .manual)
        let explicitAuto = TranscriptMapping.transcript(from: [r], duration: 1, requestedLanguage: "auto")
        #expect(explicitAuto.languageDetection == .auto)
        #expect(auto.schemaVersion == 1 && auto.duration == 1)
    }

    @Test func theOutputRoundTripsThroughTheAPIsShape() throws {
        let r = result([segment("a b", 0, 1, words: [timing("a", 0, 0.5), timing("b", 0.5, 1)])])
        let t = TranscriptMapping.transcript(from: [r], duration: 1, requestedLanguage: nil)
        #expect(try JSONDecoder().decode(Transcript.self, from: JSONEncoder().encode(t)) == t)
    }
}
