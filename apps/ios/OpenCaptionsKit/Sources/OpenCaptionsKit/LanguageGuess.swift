import Foundation

/// Picking which stretches of audio a language is judged from, and combining the verdicts.
///
/// A model guesses the language from one 30-second window. In a long video the first window
/// may be silence, music or noise, and a guess from that can be wrong; so the loudest windows
/// are judged, not the first, and their verdicts are added up. (A clip shorter than a window
/// is judged whole either way, so this does not help a short clip that is simply hard.)
public enum LanguageGuess {
    /// 30 seconds of 16 kHz audio, what a model looks at once.
    public static let windowSamples = 480_000

    /// Up to `count` non-overlapping windows with the most energy (where the speech is), in
    /// time order. A clip shorter than a window is a single one.
    public static func loudestWindows(in samples: [Float], count: Int = 3) -> [Range<Int>] {
        guard samples.count > windowSamples else { return samples.isEmpty ? [] : [0..<samples.count] }
        var windows: [(range: Range<Int>, energy: Float)] = []
        var start = 0
        while start < samples.count {
            let end = min(start + windowSamples, samples.count)
            // A scrap of a window left at the end says little; the one before it covers that audio.
            if end - start >= windowSamples / 3 || windows.isEmpty {
                let slice = samples[start..<end]
                windows.append((start..<end, slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)))
            }
            start = end
        }
        return windows.sorted { $0.energy > $1.energy }.prefix(count).map(\.range).sorted { $0.lowerBound < $1.lowerBound }
    }

    /// A guess below this share of the weight is a coin toss, and forcing it on the model makes it
    /// translate the speech into the wrong language: better to ask.
    public static let minimumConfidence: Float = 0.5

    /// The language with the most weight across the windows, and how much of the weight that is (0 to 1,
    /// the average of its probability over the windows). A model reports either probabilities or log
    /// probabilities; values that are all at or below zero are taken as logs.
    public static func winner(of verdicts: [[String: Float]]) -> (language: String, confidence: Float)? {
        var totals: [String: Float] = [:]
        for verdict in verdicts {
            let isLog = verdict.values.allSatisfy { $0 <= 0 }
            for (language, value) in verdict { totals[language, default: 0] += isLog ? exp(value) : value }
        }
        guard let best = totals.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, min(1, best.value / Float(verdicts.count)))
    }
}
