import Foundation
import Testing
@testable import OpenCaptionsKit

/// A speech model decodes padded windows and can invent words past the end of the video.
@Suite struct TranscriptBoundsTests {
    func segment(_ id: String, _ words: [(String, Double, Double)]) -> TranscriptSegment {
        let list = words.map { Word(text: $0.0, start: $0.1, end: $0.2) }
        return TranscriptSegment(
            id: id, words: list, start: list.first?.start ?? 0, end: list.last?.end ?? 0,
            text: list.map(\.text).joined(separator: " "))
    }

    @Test func wordsPastTheEndGoAndOneThatRunsPastIsCutShort() {
        let t = Transcript(
            language: "es", languageDetection: .manual, duration: 30,
            segments: [
                segment("a", [("hola", 1, 2), ("mundo", 29.5, 31)]),
                segment("b", [("gracias", 32, 33), ("adiós", 34, 35)]),
            ])
        let kept = t.withinDuration()
        #expect(kept.segments.count == 1)
        #expect(kept.segments[0].words.map(\.text) == ["hola", "mundo"])
        #expect(kept.segments[0].words[1].end == 30)
        #expect(kept.segments[0].end == 30)
        #expect(kept.segments[0].text == "hola mundo")
    }

    @Test func aTranscriptWithinItsDurationIsUntouched() {
        let t = Transcript(
            language: "en", languageDetection: .manual, duration: 10, segments: [segment("a", [("hi", 1, 2)])])
        #expect(t.withinDuration() == t)
    }

    @Test func aTranscriptOfNothingButInventedWordsIsEmpty() {
        let t = Transcript(
            language: "en", languageDetection: .manual, duration: 5, segments: [segment("a", [("thanks", 6, 7)])])
        #expect(t.withinDuration().segments.isEmpty)
    }

    @Test func anUnknownDurationLeavesItAlone() {
        let t = Transcript(
            language: "en", languageDetection: .manual, duration: 0, segments: [segment("a", [("hi", 6, 7)])])
        #expect(t.withinDuration() == t)
    }
}
