import Foundation

/// Long stretches with no words, and filling them from a second look.
///
/// Whisper skips a whole 30-second window it judges silent (a high no-speech probability and a low
/// confidence together), and music, singing, and speech over noise trip that often. The result
/// reads as a long hole in the timeline with good captions on either side. Real silence is rare
/// in a clip someone wants captioned, so every long hole that is not quiet is decoded again without
/// that judgement, twice with the window shifted, and only the words both readings give are kept:
/// text invented over music differs from one window to the next, speech does not. (The server does
/// the same, `chunking.second_look`, measured in docs/project/speech-model-benchmarks.md.)
public enum TranscriptGaps {
    /// The shortest stretch of audio without a word that is looked at again.
    public static let minimum: Double = 6

    /// Below this mean level (dBFS) a stretch is silence, and no words in it are expected.
    static let quietLevel: Double = -55

    /// Whether the audio is so quiet that decoding it again is not worth it.
    public static func isQuiet(_ samples: ArraySlice<Float>, rate: Double = 16_000) -> Bool {
        let frame = Int(rate * 0.05)
        guard samples.count >= frame else { return true }
        var total = 0.0
        var count = 0
        var index = samples.startIndex
        while index + frame <= samples.endIndex {
            var sum: Float = 0
            for sample in samples[index..<index + frame] { sum += sample * sample }
            total += 20 * log10(Double(sum / Float(frame)).squareRoot() + 1e-9)
            count += 1
            index += frame
        }
        return total / Double(count) < quietLevel
    }

    /// The words of `first` that `second` also has: the same word, starting within `tolerance` seconds.
    /// Times are from the same origin in both.
    public static func agreed(_ first: [Word], _ second: [Word], tolerance: Double = 1.5) -> [Word] {
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        return first.filter { word in
            let wanted = key(word.text)
            return !wanted.isEmpty && second.contains { key($0.text) == wanted && abs($0.start - word.start) <= tolerance }
        }
    }

    /// The stretches of `0...duration` of at least `minimum` seconds that no word covers.
    public static func find(in transcript: Transcript, duration: Double, minimum: Double = minimum) -> [ClosedRange<Double>] {
        guard duration > 0 else { return [] }
        let spans = transcript.segments.flatMap(\.words).map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        var gaps: [ClosedRange<Double>] = []
        var cursor = 0.0
        for (start, end) in spans {
            if start - cursor >= minimum { gaps.append(cursor...start) }
            cursor = max(cursor, end)
        }
        if duration - cursor >= minimum { gaps.append(cursor...duration) }
        return gaps
    }

    /// `base` with each fill's segments added, the fill's times being relative to `offset`
    /// seconds into the audio. Only what lies inside the gap it was made for is kept.
    public static func merge(
        _ base: Transcript, fills: [(gap: ClosedRange<Double>, transcript: Transcript)]
    ) -> Transcript {
        var result = base
        for (gap, fill) in fills where !fill.segments.isEmpty {
            for segment in fill.segments {
                var moved = segment
                moved.start += gap.lowerBound
                moved.end += gap.lowerBound
                moved.words = segment.words.map {
                    Word(text: $0.text, start: $0.start + gap.lowerBound, end: $0.end + gap.lowerBound, confidence: $0.confidence)
                }
                moved.words.removeAll { $0.start < gap.lowerBound - 0.01 || $0.end > gap.upperBound + 0.5 }
                guard !moved.words.isEmpty else { continue }
                moved.start = moved.words.first!.start
                moved.end = moved.words.last!.end
                result.segments.append(moved)
            }
        }
        result.segments.sort { $0.start < $1.start }
        result.segments = result.segments.enumerated().map {
            var segment = $0.element
            segment.id = "seg-\($0.offset)"
            return segment
        }
        return result
    }
}
