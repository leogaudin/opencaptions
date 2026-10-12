import Foundation
import Testing
@testable import OpenCaptionsKit

@Suite struct TranscriptGapsTests {
    func transcript(_ spans: [(Double, Double)], duration: Double = 100) -> Transcript {
        Transcript(
            language: "en", languageDetection: .manual, duration: duration,
            segments: spans.enumerated().map { i, span in
                TranscriptSegment(
                    id: "s\(i)", words: [Word(text: "w\(i)", start: span.0, end: span.1)], start: span.0, end: span.1,
                    text: "w\(i)")
            })
    }

    @Test func longHolesAreFoundAtTheStartBetweenWordsAndAtTheEnd() {
        let t = transcript([(15, 16), (17, 18), (40, 41)], duration: 60)
        #expect(TranscriptGaps.find(in: t, duration: 60) == [0...15, 18...40, 41...60])
        #expect(TranscriptGaps.find(in: transcript([(0, 5), (10, 15)], duration: 20), duration: 20).isEmpty)
        #expect(TranscriptGaps.find(in: t, duration: 0).isEmpty)
    }

    @Test func aFillIsMovedIntoItsGapAndKeptInOrder() {
        let base = transcript([(0, 1), (30, 31)], duration: 31)
        let fill = Transcript(
            language: "en", languageDetection: .manual, duration: 29,
            segments: [
                TranscriptSegment(
                    id: "x",
                    words: [Word(text: "la", start: 1, end: 2), Word(text: "la", start: 2, end: 3), Word(text: "land", start: 3, end: 4)],
                    start: 1, end: 4, text: "la la land")
            ])
        let merged = TranscriptGaps.merge(base, fills: [(1...30, fill)])
        #expect(merged.segments.map(\.start) == [0, 2, 30])
        #expect(merged.segments.map(\.id) == ["seg-0", "seg-1", "seg-2"])
        #expect(merged.segments[1].words.map(\.start) == [2, 3, 4])
    }

    @Test func onlyWordsBothReadingsGiveAreKept() {
        let first = [Word(text: "Guys?", start: 5, end: 6), Word(text: "Boom", start: 8, end: 9), Word(text: "run", start: 10, end: 11)]
        let second = [Word(text: "guys!", start: 5.4, end: 6), Word(text: "run", start: 20, end: 21)]
        #expect(TranscriptGaps.agreed(first, second).map(\.text) == ["Guys?"], "Boom is in one reading, run is at another time")
        #expect(TranscriptGaps.agreed(first, []).isEmpty)
    }

    /// The server's version (`chunking.agreed_in_gap`) is held to the same cases.
    @Test func theSharedCasesOfTwoReadingsOfAGapHold() throws {
        struct Case: Decodable {
            struct Reading: Decodable { var text: String; var start: Double }
            var name: String
            var gap: [Double]
            var first: [Reading]
            var second: [Reading]
            var kept: [String]
        }
        struct File: Decodable { var cases: [Case] }
        let url = Bundle.module.url(forResource: "second-look", withExtension: "json", subdirectory: "Fixtures")!
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        #expect(file.cases.count >= 8)
        for item in file.cases {
            func words(_ readings: [Case.Reading]) -> [Word] {
                readings.map { Word(text: $0.text, start: $0.start, end: $0.start + 0.5) }
            }
            let kept = TranscriptGaps.kept(words(item.first), words(item.second), in: item.gap[0]...item.gap[1])
            #expect(kept.map(\.text) == item.kept, "\(item.name)")
        }
    }

    @Test func quietAudioIsQuietAndLoudAudioIsNot() {
        let silence = [Float](repeating: 0, count: 160_000)
        let loud = (0..<160_000).map { Float(0.1 * sin(Double($0) * 0.1)) }
        #expect(TranscriptGaps.isQuiet(silence[...]))
        #expect(!TranscriptGaps.isQuiet(loud[...]))
        #expect(TranscriptGaps.isQuiet(loud[0..<100]), "too short to judge is not worth decoding")
    }
}
