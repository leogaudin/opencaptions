import Foundation

extension Transcript {
    /// The transcript without what lies past the end of the recording. A speech model decodes in
    /// windows of 30 seconds padded with silence, and on a stretch with no speech (cheering, music)
    /// it can invent words there, at times the video does not have. A word that starts at or after
    /// the end is dropped, one that runs past it is cut short, and a segment left with no words goes.
    public func withinDuration() -> Transcript {
        guard duration > 0 else { return self }
        var result = self
        result.segments = segments.compactMap { segment in
            let words = segment.words.filter { $0.start < duration }.map { word -> Word in
                var kept = word
                kept.end = min(word.end, duration)
                return kept
            }
            guard let first = words.first, let last = words.last else { return nil }
            var kept = segment
            kept.words = words
            kept.start = first.start
            kept.end = last.end
            kept.text = words.map(\.text).joined(separator: " ")
            return kept
        }
        return result
    }
}
