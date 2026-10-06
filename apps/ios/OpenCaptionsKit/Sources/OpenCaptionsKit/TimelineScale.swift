import Foundation

/// The timeline's scale, as the web's `timelineScale.ts`: tick spacing, the zoom
/// limits, and the maths that keeps the time under a pinch where it was.
public enum TimelineScale {
    /// The most the timeline zooms in, in points per second.
    public static let maxPointsPerSecond = 400.0

    private static let tickSteps = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]

    /// The finest tick step whose labels stay at least `minSpacing` apart.
    public static func tickStep(pointsPerSecond: Double, minSpacing: Double = 70) -> Double {
        tickSteps.first { $0 * pointsPerSecond >= minSpacing } ?? tickSteps[tickSteps.count - 1]
    }

    /// A tick's label: whole seconds as `m:ss`, finer steps with a tenth.
    public static func tickLabel(_ seconds: Double, step: Double) -> String {
        let m = Int(seconds / 60)
        let s = seconds - Double(m) * 60
        if step < 1 { return String(format: "%d:%04.1f", m, s) }
        return String(format: "%d:%02d", m, Int(s.rounded()))
    }

    /// A zoom kept between "fit" and the most the timeline may zoom.
    public static func clampZoom(_ pointsPerSecond: Double, fit: Double) -> Double {
        min(max(pointsPerSecond, fit), max(fit, maxPointsPerSecond))
    }

    /// The zoom a video opens at, in points per second: close enough to work on a caption.
    public static let defaultPointsPerSecond = 80.0

    /// The most zoomed out the timeline goes: the whole video spans half the view, so that with
    /// the playhead in the middle all of it is in view wherever the playhead is.
    public static func fit(viewport: Double, span: Double) -> Double {
        viewport / (2 * max(span, 0.001))
    }

    /// Where `time` (the playhead's) puts the start of the track, in the view: the playhead is in
    /// the middle, and the track moves under it.
    public static func trackOrigin(time: Double, pointsPerSecond: Double, viewport: Double) -> Double {
        viewport / 2 - time * pointsPerSecond
    }

    /// The time a drag of `translation` points leads to from `start`: dragging the track to the left
    /// shows what comes later.
    public static func scrubbed(from start: Double, translation: Double, pointsPerSecond: Double, span: Double) -> Double {
        min(span, max(0, start - translation / pointsPerSecond))
    }

    /// The time under a position `x` in the view, when the playhead (in the middle) is at `time`.
    public static func time(atX x: Double, playheadTime time: Double, pointsPerSecond: Double, viewport: Double, span: Double) -> Double {
        min(span, max(0, time + (x - viewport / 2) / pointsPerSecond))
    }
}

extension TimelineScale {
    /// A position in a video as `m:ss.cc`, the hundredths a caption edit is judged by.
    public static func timecode(_ seconds: Double) -> String {
        let cs = Int((seconds.isFinite ? max(0, seconds) : 0) * 100)
        return String(format: "%d:%02d.%02d", cs / 6000, (cs % 6000) / 100, cs % 100)
    }
}
