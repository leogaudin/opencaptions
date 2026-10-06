import CoreGraphics
import Foundation

/// The maths behind the preview's gestures, kept out of the views so it is tested.
public enum CaptionGestures {
    /// The caption block's new normalised centre after a drag of `translation` points
    /// on a preview `size` points across, from where it started.
    public static func draggedPosition(
        from start: (x: Double, y: Double), translation: CGSize, size: CGSize
    ) -> (x: Double, y: Double) {
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        guard size.width > 0, size.height > 0 else { return start }
        return (
            clamp(start.x + translation.width / size.width),
            clamp(start.y + translation.height / size.height)
        )
    }

    /// The font sizes a pinch and the size slider can reach.
    public static let fontSizeRange = 20.0...160.0

    /// The font size after a pinch of `scale` (1 = no change) from `start`.
    public static func pinchedFontSize(from start: Int, scale: Double) -> Int {
        guard scale.isFinite, scale > 0 else { return start }
        let size = (Double(start) * scale).rounded()
        return Int(min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, size)))
    }

    /// Where a finger may land to drag the caption, in frame pixels: the caption's own box, or
    /// where it would be when nothing is showing, made at least `minimumPoints` across and a
    /// `slopPoints` wider all round, so a small caption can be grabbed (a finger is not a cursor).
    public static func dragRegion(
        caption: FrameRect?, position: (x: Double, y: Double), frame: CGSize, pixelsPerPoint: Double,
        minimumPoints: Double = 48, slopPoints: Double = 24
    ) -> FrameRect {
        let base = caption ?? FrameRect(
            x: position.x * frame.width - frame.width * 0.3, y: position.y * frame.height - frame.height * 0.04,
            width: frame.width * 0.6, height: frame.height * 0.08)
        let slop = slopPoints * pixelsPerPoint
        let minimum = minimumPoints * pixelsPerPoint
        let width = max(base.width + 2 * slop, minimum)
        let height = max(base.height + 2 * slop, minimum)
        return FrameRect(
            x: base.x + base.width / 2 - width / 2, y: base.y + base.height / 2 - height / 2,
            width: width, height: height)
    }

    /// The transcript word under a tap at `point` (frame pixels), if it is on a word of
    /// the active caption: word N of line L is flat word `L * wordsPerLine + N`.
    public static func wordIndex(at point: CGPoint, in caption: ActiveCaption, wordsPerLine: Int) -> Int? {
        caption.words.firstIndex { $0.contains(x: point.x, y: point.y) }
            .map { caption.index * max(1, wordsPerLine) + $0 }
    }

    /// A word as typed in the edit field: runs of whitespace become one space and the ends are
    /// trimmed. Several words in it are kept, and the engine shares the word's time between them.
    public static func normalizedWord(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
