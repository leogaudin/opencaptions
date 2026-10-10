import Foundation
import Testing
@testable import OpenCaptionsKit

@Suite struct TokenMappingTests {
    private func token(_ text: String, _ start: Double, _ end: Double, _ confidence: Double = 1) -> SpeechToken {
        SpeechToken(text: text, start: start, end: end, confidence: confidence)
    }

    @Test func piecesAreJoinedIntoWordsAtASpaceOrASentencePieceMarker() {
        let words = TokenMapping.words(from: [
            token(" C", 0.16, 0.24, 0.9), token("ute", 0.24, 0.40, 0.7),
            token("▁little", 0.40, 0.72), token(".", 0.72, 0.80),
        ])
        #expect(words.map(\.text) == ["Cute", "little."])
        #expect(words[0].start == 0.16 && words[0].end == 0.40)
        #expect(abs(words[0].confidence - 0.8) < 1e-9, "the pieces' mean")
        #expect(words[1].start == 0.40 && words[1].end == 0.80)
    }

    @Test func specialPiecesAndEmptyOnesMakeNoWords() {
        #expect(TokenMapping.words(from: [token("<blank>", 0, 1), token(" ", 1, 2)]).isEmpty)
    }

    @Test func aWordNeverOverrunsTheNextOne() {
        let words = TokenMapping.words(from: [token(" one", 0, 1.2), token(" two", 1.0, 2)])
        #expect(words[0].end == 1.0)
    }

    @Test func segmentsEndAtSentencesAndTheRestFormsTheLast() {
        let tokens = [
            token(" Hello", 0, 0.4), token(" there.", 0.4, 0.9),
            token(" How", 1.2, 1.4), token(" are", 1.4, 1.6), token(" you?", 1.6, 2.0),
            token(" Fine", 2.4, 2.8),
        ]
        var n = 0
        let transcript = TokenMapping.transcript(from: tokens, duration: 3, requestedLanguage: nil, makeID: { n += 1; return "s\(n)" })
        #expect(transcript.segments.map(\.text) == ["Hello there.", "How are you?", "Fine"])
        #expect(transcript.segments.map(\.id) == ["s1", "s2", "s3"])
        #expect(transcript.segments[1].start == 1.2 && transcript.segments[1].end == 2.0)
        #expect(transcript.duration == 3)
    }

    @Test func aRequestedLanguageIsKeptAndMarkedManual() {
        let transcript = TokenMapping.transcript(from: [token(" hi", 0, 1)], duration: 1, requestedLanguage: "fr")
        #expect(transcript.language == "fr")
        #expect(transcript.languageDetection == .manual)
    }

    @Test func withNoLanguageTheTextSaysWhichOneAmongTheOnesTheModelCovers() {
        let french = "Bonjour à tous, nous sommes réunis aujourd’hui pour parler de la forêt."
            .split(separator: " ").enumerated().map { token(" " + $1, Double($0), Double($0) + 0.5) }
        let transcript = TokenMapping.transcript(
            from: french, duration: 12, requestedLanguage: "auto", languages: WhisperModels.parakeetLanguages)
        #expect(transcript.language == "fr")
        #expect(transcript.languageDetection == .auto)
    }

    @Test func textInALanguageTheModelDoesNotCoverIsNotLabelledWithIt() {
        // Whatever the text is recognised as, the answer is one of the languages offered.
        let language = TokenMapping.language(of: "Bonjour à tous, nous sommes réunis aujourd’hui.", among: ["de"])
        #expect(language == nil || language == "de")
    }
}
