import Foundation

/// Long stretches with no words, and filling them from a second look.
///
/// Whisper skips a whole 30-second window it judges silent (a high no-speech probability and a low
/// confidence together), and music, singing, and speech over noise trip that often. The result
/// reads as a long hole in the timeline with good captions on either side. Real silence is rare
/// in a clip someone wants captioned, so every long hole is decoded again without that judgement.
public enum TranscriptGaps {
    /// The longest stretch of audio without a word that is believable as silence.
    public static let minimum: Double = 12

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

    /// Whether a second look found speech and not Whisper's habit of inventing some for noise: at
    /// least a few words, and not the same line over and over.
    public static func believable(_ fill: Transcript) -> Bool {
        let words = fill.segments.flatMap(\.words)
        guard words.count >= 3 else { return false }
        let lines = fill.segments.map { $0.text.trimmingCharacters(in: .whitespaces).lowercased() }
        return Set(lines).count > 1 || lines.count == 1
    }

    /// `base` with each fill's segments added, the fill's times being relative to `offset`
    /// seconds into the audio. Only what lies inside the gap it was made for is kept.
    public static func merge(
        _ base: Transcript, fills: [(gap: ClosedRange<Double>, transcript: Transcript)]
    ) -> Transcript {
        var result = base
        for (gap, fill) in fills where believable(fill) {
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
