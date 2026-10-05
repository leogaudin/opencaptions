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

    /// The scroll offset that keeps `time` under `anchorX` (a position within the
    /// visible width) once the scale is `pointsPerSecond`.
    public static func scrollOffset(keeping time: Double, at anchorX: Double, pointsPerSecond: Double) -> Double {
        max(0, time * pointsPerSecond - anchorX)
    }

    /// The time under a position `x` within the visible width.
    public static func time(atX x: Double, scrollOffset: Double, pointsPerSecond: Double, span: Double) -> Double {
        min(span, max(0, (x + scrollOffset) / pointsPerSecond))
    }
}
