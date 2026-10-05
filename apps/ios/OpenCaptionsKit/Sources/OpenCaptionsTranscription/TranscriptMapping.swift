import Foundation
import OpenCaptionsKit
import WhisperKit

/// WhisperKit's result in the API's `Transcript` shape, so its transcripts and the
/// server's are interchangeable. Pure, so it is tested without a model. It follows
/// the server's local provider: words are trimmed and empties dropped, a segment
/// whose word alignment came back empty is kept by spreading its text across its own
/// span, and a segment with no words at all is dropped.
public enum TranscriptMapping {
    public static func transcript(
        from results: [TranscriptionResult], duration: Double, requestedLanguage: String?,
        makeID: () -> String = { UUID().uuidString }
    ) -> Transcript {
        let segments = results.flatMap(\.segments).sorted { $0.start < $1.start }.compactMap {
            segment(from: $0, id: makeID())
        }
        let requested = requestedLanguage.map { $0 != "auto" } ?? false
        return Transcript(
            language: results.first?.language ?? requestedLanguage ?? "en",
            languageDetection: requested ? .manual : .auto, duration: duration, segments: segments)
    }

    private static func segment(from source: TranscriptionSegment, id: String) -> TranscriptSegment? {
        var words = (source.words ?? []).compactMap { timing -> Word? in
            let text = clean(timing.word)
            guard !text.isEmpty else { return nil }
            let start = max(0, Double(timing.start))
            return Word(
                text: text, start: start, end: max(start, Double(timing.end)),
                confidence: min(1, max(0, Double(timing.probability))))
        }
        if words.isEmpty { words = spread(clean(source.text), from: Double(source.start), to: Double(source.end)) }
        guard let first = words.first, let last = words.last else { return nil }
        return TranscriptSegment(
            id: id, words: words, start: first.start, end: last.end,
            text: words.map(\.text).joined(separator: " "))
    }

    /// Trimmed, with Whisper's special tokens (`<|0.00|>`) removed.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A segment's text spread evenly over its own span: captions need a timing per
    /// word, and even spacing reads far better than dropping recognised speech.
    private static func spread(_ text: String, from start: Double, to end: Double) -> [Word] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let span = max(0, end - start)
        let length = span > 0 ? span : Double(tokens.count) * 0.3
        let step = length / Double(tokens.count)
        return tokens.enumerated().map { i, token in
            Word(text: token, start: max(0, start) + step * Double(i), end: max(0, start) + step * Double(i + 1))
        }
    }
}
