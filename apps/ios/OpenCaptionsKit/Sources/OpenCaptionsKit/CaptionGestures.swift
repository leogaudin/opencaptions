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
    public static let fontSizeRange = 20.0...300.0

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

    /// Where the engine puts the middle of a block `extent` long when asked for `position` (0...1) in a
    /// frame `limit` long: centred on the position, but kept inside the frame (and against its start
    /// if it is longer than the frame). The preview needs it to show a drag or a pinch where the
    /// release will land, which at a big size is not where the finger is.
    public static func blockCentre(position: Double, extent: Double, limit: Double) -> Double {
        let start = min(max(position * limit - extent / 2, 0), max(limit - extent, 0))
        return start + extent / 2
    }

    /// The transform that shows a drag or a pinch in progress on the caption layer, which covers a
    /// view of `size`: scaled by `scale` about `pivot` (the caption's middle, in the view's points,
    /// from its top-left corner), then moved by `offset`. A layer's transform turns about the
    /// layer's middle, not its corner, so the pivot is taken from there.
    public static func liveTransform(offset: CGSize, scale: CGFloat, pivot: CGPoint, in size: CGSize) -> CGAffineTransform {
        let p = CGPoint(x: pivot.x - size.width / 2, y: pivot.y - size.height / 2)
        return CGAffineTransform(translationX: offset.width, y: offset.height)
            .translatedBy(x: p.x, y: p.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -p.x, y: -p.y)
    }
}
