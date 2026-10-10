import Foundation
import NaturalLanguage

/// A piece of text with the time it was spoken, as a transducer model (Parakeet) reports it:
/// SentencePiece pieces, a leading space (or ▁) marking the start of a word.
public struct SpeechToken: Equatable, Sendable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Double

    public init(text: String, start: Double, end: Double, confidence: Double = 1) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// A model's tokens in the API's `Transcript` shape, so its transcripts and the server's are
/// interchangeable. Pure, so it is tested without a model. It follows the server's Parakeet engine
/// (`sherpa.py`): pieces joined into words, words ended before the next begins, segments ended at a
/// sentence's end.
public enum TokenMapping {
    public static func transcript(
        from tokens: [SpeechToken], duration: Double, requestedLanguage: String?, languages: Set<String>? = nil,
        makeID: () -> String = { UUID().uuidString }
    ) -> Transcript {
        let spoken = words(from: tokens)
        let requested = requestedLanguage.flatMap { $0 == "auto" ? nil : $0 }
        let language = requested ?? Self.language(of: spoken.map(\.text).joined(separator: " "), among: languages) ?? "en"
        return Transcript(
            language: language, languageDetection: requested == nil ? .auto : .manual, duration: duration,
            segments: segments(from: spoken, makeID: makeID))
    }

    /// Pieces joined into words, each ending no later than the next one starts.
    static func words(from tokens: [SpeechToken]) -> [Word] {
        struct Open {
            var text: String
            var start: Double
            var end: Double
            var confidences: [Double]
        }
        var building: [Open] = []
        for token in tokens {
            let startsWord = token.text.hasPrefix(" ") || token.text.hasPrefix("▁") || building.isEmpty
            let piece = token.text.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, !(piece.hasPrefix("<") && piece.hasSuffix(">")) else { continue }
            if startsWord {
                building.append(Open(text: piece, start: token.start, end: token.end, confidences: [token.confidence]))
            } else {
                building[building.count - 1].text += piece
                building[building.count - 1].end = token.end
                building[building.count - 1].confidences.append(token.confidence)
            }
        }
        var words = building.map { word in
            let start = max(0, word.start)
            let confidence = word.confidences.reduce(0, +) / Double(word.confidences.count)
            return Word(text: word.text, start: start, end: max(start, word.end), confidence: min(1, max(0, confidence)))
        }
        for index in words.indices.dropLast() where words[index].end > words[index + 1].start {
            words[index].end = max(words[index].start, words[index + 1].start)
        }
        return words
    }

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]

    /// Segments that end at a sentence's end; whatever follows the last one forms the final segment.
    static func segments(from words: [Word], makeID: () -> String) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var current: [Word] = []
        func close() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(
                TranscriptSegment(
                    id: makeID(), words: current, start: first.start, end: last.end,
                    text: current.map(\.text).joined(separator: " ")))
            current = []
        }
        for word in words {
            current.append(word)
            if let end = word.text.last, sentenceEnds.contains(end) { close() }
        }
        close()
        return segments
    }

    /// The language of some text, among the ones a model covers (any, if it covers any); nil if the
    /// text says nothing.
    public static func language(of text: String, among languages: Set<String>?) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let ranked = recognizer.languageHypotheses(withMaximum: 5).sorted { $0.value > $1.value }
        for (language, _) in ranked {
            let code = language.rawValue.split(separator: "-").first.map(String.init) ?? language.rawValue
            if languages?.contains(code) ?? true { return code }
        }
        return nil
    }
}
