import AVFoundation
import CoreImage
import OpenCaptionsKit
import SwiftUI
import UIKit

/// The preview: the source video with the caption engine's frame drawn over it, on
/// the same code and the same fonts as the export. While paused, the caption block
/// can be dragged and a word double-tapped to edit it; a tap plays or pauses.
struct PreviewView: UIViewRepresentable {
    let playback: Playback
    let project: Project
    let fonts: FontCache
    /// The video's width over its height: the preview takes this shape in the room it is given.
    let ratio: Double
    /// Held while an export owns the engine.
    var suspended = false
    /// A mark drawn on the picture by the engine (a free tier's), as in the saved video.
    var watermark: String?
    let onTogglePlay: () -> Void
    /// Where a drag and a pinch settled (either may be nil), once the fingers are up.
    let onAdjust: (_ position: (x: Double, y: Double)?, _ fontSize: Int?) -> Void
    let onEditWord: (_ index: Int) -> Void

    func makeUIView(context: Context) -> PreviewArea {
        let area = PreviewArea(player: playback.player)
        let view = area.preview
        view.onTogglePlay = onTogglePlay
        view.onAdjust = onAdjust
        view.onEditWord = onEditWord
        return area
    }

    func updateUIView(_ area: PreviewArea, context: Context) {
        area.ratio = ratio
        let view = area.preview
        view.onTogglePlay = onTogglePlay
        view.onAdjust = onAdjust
        view.onEditWord = onEditWord
        view.configure(
            project: project, fonts: fonts, suspended: suspended, isPlaying: playback.isPlaying, watermark: watermark)
    }
}

/// All the room the preview is given, with the video fitted in the middle of it. A pinch anywhere in
/// it, over the video or the black around it, changes the caption's size: a thumb and finger rarely
/// land on the picture itself. A drag, a tap and a double tap stay on the picture.
final class PreviewArea: UIView {
    let preview: PreviewUIView
    var ratio = 9.0 / 16.0 { didSet { setNeedsLayout() } }

    init(player: AVPlayer) {
        preview = PreviewUIView(player: player)
        super.init(frame: .zero)
        backgroundColor = .black
        addSubview(preview)
        addGestureRecognizer(preview.pinchRecogniser)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, ratio > 0 else { return }
        let size = bounds.width / bounds.height > ratio
            ? CGSize(width: bounds.height * ratio, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / ratio)
        preview.frame = CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height)
    }
}

final class PreviewUIView: UIView, UIGestureRecognizerDelegate {
    private let playerLayer: AVPlayerLayer
    /// The caption's picture, which moves and scales with the fingers. The watermark's place is cut out of it
    /// by a mask that moves with it, so the picture carries no mark and the one on `markLayer`, still, is
    /// the only one: moving or scaling the caption leaves the watermark where it is.
    private let overlay = CALayer()
    private let markLayer = CALayer()
    private let hole = CAShapeLayer()
    private var markRect: FrameRect?
    private let player: AVPlayer
    private let engine = CaptionEngine.shared
    private let ciContext = CIContext()
    nonisolated(unsafe) private var timeObserver: Any?

    var onTogglePlay: () -> Void = {}
    var onAdjust: ((x: Double, y: Double)?, Int?) -> Void = { _, _ in }
    var onEditWord: (Int) -> Void = { _ in }

    // The scene the engine holds is rebuilt when any of this changes. Cheap to compare, because this
    // is asked on every update of the view: the project's own stamp stands for its words, and what is
    // compared is never the transcript itself.
    private struct SceneKey: Equatable {
        var project: UUID
        var stamp: Date
        var style: StyleConfig
        var offsetMs: Int
        var watermark: String?
        var segments: Int
        var width: Int
        var height: Int
    }
    private var sceneKey: SceneKey?
    private var generation = 0
    private var ready = false
    private var suspended = false
    private var isPlaying = false
    /// An HDR video's captions are drawn brighter than SDR white (see `CaptionFrame.hdrWhiteScale`).
    private var hdr = false
    private var wordsPerLine = 3
    private var style: StyleConfig?
    private var frameSize = CGSize.zero
    private var caption: ActiveCaption?
    private var drawing = false
    private var pendingTime: Double?
    private var dragStart: (x: Double, y: Double)?
    /// Where the dragging finger went down, and the caption it went down on. UIKit reports a pan's
    /// translation from where it recognised the pan, which can be well after the finger landed
    /// (right after a tap, while the double tap is still possible), so a drag is measured from here.
    private var touchDown: (point: CGPoint, caption: FrameRect?)?

    /// What a drag or a pinch has settled on so far (nil: not touched). The caption layer follows the
    /// fingers by being moved and scaled (the picture the engine already drew, so nothing for the
    /// engine to do), and this is committed once, when they lift. Changing the style on every touch
    /// event made the engine lay the whole transcript out again each time, while it was drawing the
    /// playing video.
    private struct Live {
        var position: (x: Double, y: Double)?
        var fontSize: Int?
    }
    private var live = Live()
    private var panning = false
    private var pinching = false
    /// Added by the area around the picture, so that it reaches past it.
    let pinchRecogniser = UIPinchGestureRecognizer()
    private var waitingForFingers = false
    /// Where the dragging finger last was, relative to where it went down, while it was alone.
    private var lastTravel = CGPoint.zero
    private var pinchStartSize = 0
    /// Where the caption and how big it was in the scene that drew the picture on screen, by the
    /// scene's generation. The layer is moved and scaled by the difference between this and where
    /// the caption now should be (the fingers', or the committed style's), so it is right whatever
    /// order the engine's pictures arrive in: there is no state to reset when a new one does.
    private struct Placement { var x: Double; var y: Double; var fontSize: Int }
    private var placements: [Int: Placement] = [:]
    private var drawnGeneration = 0
    private let verticalGuide = CALayer()
    private let horizontalGuide = CALayer()
    private let haptic = UISelectionFeedbackGenerator()
    /// How close the caption's centre comes to a centre line of the video before it snaps, in points.
    private static let snapPull = 8.0

    init(player: AVPlayer) {
        self.player = player
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        backgroundColor = .black
        #if DEBUG
            // Found by the UI tests, which drive the gestures.
            isAccessibilityElement = true
            accessibilityIdentifier = "preview"
            accessibilityLabel = "Video preview"
        #endif
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        overlay.contentsGravity = .resize
        overlay.magnificationFilter = .trilinear
        overlay.mask = hole
        hole.fillRule = .evenOdd
        hole.fillColor = UIColor.black.cgColor
        markLayer.contentsGravity = .resize
        markLayer.magnificationFilter = .trilinear
        layer.addSublayer(overlay)
        layer.addSublayer(markLayer)
        for guide in [verticalGuide, horizontalGuide] {
            guide.backgroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
            guide.shadowColor = UIColor.black.cgColor
            guide.shadowOpacity = 0.35
            guide.shadowRadius = 0.5
            guide.shadowOffset = .zero
            guide.isHidden = true
            layer.addSublayer(guide)
        }

        // The player's own clock: every frame while playing, and on a seek.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.requestDraw(at: time.seconds) }
        }

        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        double.numberOfTapsRequired = 2
        single.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
        // One finger drags; a second one joining it stops the drag and pinches (below).
        pan.maximumNumberOfTouches = 1
        // Two fingers anywhere on the video change the font size: pinching out is bigger. It
        // works while the video plays, like the drag.
        let pinch = pinchRecogniser
        pinch.addTarget(self, action: #selector(pinched))
        // A finger already dragging can be joined by a second to pinch: the pinch is not held back
        // by the drag that began first.
        pan.delegate = self
        pinch.delegate = self
        [single, double, pan].forEach(addGestureRecognizer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer, gestureRecognizer.state == .possible,
            gestureRecognizer.numberOfTouches == 0
        {
            touchDown = (touch.location(in: self), caption?.bounds)
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
            || (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
        // Not `frame`, which means nothing while the layer is being transformed.
        hole.frame = CGRect(origin: .zero, size: bounds.size)
        overlay.bounds = CGRect(origin: .zero, size: bounds.size)
        overlay.position = CGPoint(x: bounds.midX, y: bounds.midY)
        placeMark()
        verticalGuide.frame = CGRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
        horizontalGuide.frame = CGRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        // The scene is sized to the view, so a new size lays it out again.
        if let lastProject, let lastFonts {
            configure(project: lastProject, fonts: lastFonts, suspended: suspended, isPlaying: isPlaying, watermark: lastWatermark)
        }
    }

    private var lastProject: Project?
    private var lastFonts: FontCache?
    private var lastWatermark: String?
    private var lastFallbacks: [String] = []
    private var rescening = false
    private var wantedSize: Int?

    @MainActor
    func configure(project: Project, fonts: FontCache, suspended: Bool, isPlaying: Bool, watermark: String?) {
        lastProject = project
        lastWatermark = watermark
        lastFonts = fonts
        // An export replaced the engine's scene; ours must be laid out again.
        if self.suspended, !suspended { sceneKey = nil }
        self.suspended = suspended
        self.isPlaying = isPlaying
        let isHDR = project.hdrTransfer != nil
        if isHDR != hdr {
            hdr = isHDR
            overlay.wantsExtendedDynamicRangeContent = isHDR
            markLayer.wantsExtendedDynamicRangeContent = isHDR
            sceneKey = nil  // draw it again in the new format
        }
        style = project.styleConfig
        wordsPerLine = project.styleConfig.wordsPerLine
        applyLive()
        guard let transcript = project.transcript, bounds.width > 0, bounds.height > 0 else { return }

        // Drawn at the size it is shown at, never above the video's: layout is
        // proportional to frame height, so this is the export's picture at screen size.
        let ratio = Double(project.videoWidth ?? 1080) / Double(project.videoHeight ?? 1920)
        let scale = min(UIScreen.main.scale, 2)
        let natural = Double(project.videoHeight ?? 1920)
        let height = max(2, Int(min(natural, bounds.height * scale).rounded()))
        let width = max(2, Int((Double(height) * ratio).rounded()))
        frameSize = CGSize(width: width, height: height)

        let key = SceneKey(
            project: project.id, stamp: project.updatedAt, style: project.styleConfig,
            offsetMs: project.captionOffsetMs, watermark: watermark, segments: transcript.segments.count, width: width, height: height)
        guard key != sceneKey else { return }
        sceneKey = key
        ready = false
        generation += 1
        let mine = generation
        let style = project.styleConfig
        placements[mine] = Placement(x: style.positionX, y: style.positionY, fontSize: style.fontSize)
        placements = placements.filter { $0.key > mine - 6 }
        let offsetMs = project.captionOffsetMs
        Task { [engine] in
            let fallbacks = await engine.ensureFonts(for: transcript, style: style, cache: fonts)
            guard mine == generation else { return }
            lastFallbacks = fallbacks
            try? await engine.setScene(
                transcript: transcript, style: style, width: width, height: height, captionOffsetMs: offsetMs,
                watermark: watermark, fallbackFonts: fallbacks)
            guard mine == generation else { return }
            ready = true
            requestDraw(at: player.currentTime().seconds)
        }
    }

    /// While a pinch is going on, lays the caption out again at the size it asks for, so that what is on
    /// screen is the engine's own picture of that size (where it wraps, how it is kept inside the frame),
    /// not only the old picture scaled, which is what the caption would jump away from when released.
    /// The scaled picture still bridges the moments the engine takes. The newest size wins.
    @MainActor
    private func layOutAgain(fontSize: Int) {
        wantedSize = fontSize
        guard !rescening, let project = lastProject else { return }
        rescening = true
        Task { [engine] in
            defer { rescening = false }
            while let size = wantedSize, pinching, let transcript = project.transcript {
                wantedSize = nil
                var style = project.styleConfig
                style.fontSize = size
                if let position = live.position { (style.positionX, style.positionY) = position }
                generation += 1
                let mine = generation
                placements[mine] = Placement(x: style.positionX, y: style.positionY, fontSize: size)
                placements = placements.filter { $0.key > mine - 6 }
                try? await engine.setScene(
                    transcript: transcript, style: style, width: Int(frameSize.width), height: Int(frameSize.height),
                    captionOffsetMs: project.captionOffsetMs, watermark: lastWatermark, fallbackFonts: lastFallbacks)
                guard mine == generation else { continue }
                ready = true
                requestDraw(at: player.currentTime().seconds)
            }
        }
    }

    /// Draws the frame for `time`, one at a time; a newer request replaces one waiting.
    @MainActor
    private func requestDraw(at time: Double) {
        guard ready, !suspended, time.isFinite else { return }
        if drawing {
            pendingTime = time
            return
        }
        drawing = true
        Task { [engine] in
            var next: Double? = time
            while let t = next {
                pendingTime = nil
                // The scene that draws this frame, even if a newer one is set while it is drawn.
                let sceneOfFrame = generation
                let frame = await engine.render(at: t)
                let active = await engine.activeCaption()
                let mark = await engine.watermarkRect()
                if !suspended {
                    caption = active
                    drawnGeneration = sceneOfFrame
                    if let frame {
                        let image = hdr ? frame.hdrCGImage(using: ciContext) : frame.cgImage(using: ciContext)
                        overlay.contents = image
                        markLayer.contents = image
                    }
                    markRect = mark
                    placeMark()
                    #if DEBUG
                        if frame != nil { accessibilityValue = "drawn" }  // the UI tests wait for this
                    #endif
                    applyLive()
                }
                next = pendingTime
            }
            drawing = false
        }
    }

    // MARK: Gestures

    /// A point in the view as frame pixels, the engine's coordinates.
    private func framePoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * frameSize.width / bounds.width, y: p.y * frameSize.height / bounds.height)
    }

    @objc private func tapped() { onTogglePlay() }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        guard !isPlaying, let caption,
            let index = CaptionGestures.wordIndex(
                at: framePoint(g.location(in: self)), in: caption, wordsPerLine: wordsPerLine)
        else { return }
        onEditWord(index)
    }

    // MARK: Live drag and pinch

    /// Moves and scales the caption layer from where the picture on screen has the caption to where it
    /// should be: where the fingers have taken it, or else where the style puts it. Settled, the two
    /// are the same and the layer is not transformed.
    private func applyLive() {
        var transform = CGAffineTransform.identity
        if let style, let drawn = placements[drawnGeneration], drawn.fontSize > 0, bounds.width > 0 {
            let target = live.position ?? (style.positionX, style.positionY)
            let size = live.fontSize ?? style.fontSize
            transform = CaptionGestures.liveTransform(
                offset: CGSize(width: (target.0 - drawn.x) * bounds.width, height: (target.1 - drawn.y) * bounds.height),
                scale: CGFloat(size) / CGFloat(drawn.fontSize), pivot: drawnCentre(drawn), in: overlay.bounds.size)
        }
        guard !CATransform3DEqualToTransform(overlay.transform, CATransform3DMakeAffineTransform(transform)) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.setAffineTransform(transform)
        CATransaction.commit()
    }

    /// The watermark on its own layer, showing its part of the picture, and the hole for it in the caption's.
    private func placeMark() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let r = markRect, frameSize.width > 0, frameSize.height > 0, bounds.width > 0 else {
            markLayer.isHidden = true
            hole.path = nil
            overlay.mask = nil
            return
        }
        let k = CGSize(width: bounds.width / frameSize.width, height: bounds.height / frameSize.height)
        let rect = CGRect(x: r.x * k.width, y: r.y * k.height, width: r.width * k.width, height: r.height * k.height)
        markLayer.frame = rect
        markLayer.contentsRect = CGRect(
            x: r.x / frameSize.width, y: r.y / frameSize.height,
            width: r.width / frameSize.width, height: r.height / frameSize.height)
        markLayer.isHidden = false
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(rect)
        hole.path = path
        overlay.mask = hole
    }

    /// The middle of the caption as drawn, in points: where a pinch scales from.
    private func drawnCentre(_ drawn: Placement) -> CGPoint {
        if let box = caption?.bounds, frameSize.width > 0, frameSize.height > 0 {
            return CGPoint(
                x: (box.x + box.width / 2) * bounds.width / frameSize.width,
                y: (box.y + box.height / 2) * bounds.height / frameSize.height)
        }
        return CGPoint(x: drawn.x * bounds.width, y: drawn.y * bounds.height)
    }

    /// When the last finger is up, commit what they settled on, once.
    private func settleIfIdle() {
        guard !panning, !pinching else { return }
        // The drag ends the moment a second finger lands, a little before the pinch is recognised.
        // Committing then would redraw the caption where the drag left it while the pinch scales it
        // about the old place: it would jump and come back. The pinch commits both when it ends.
        if pinchRecogniser.numberOfTouches >= 2 {
            guard !waitingForFingers else { return }
            waitingForFingers = true
            Task { @MainActor in
                while pinchRecogniser.numberOfTouches >= 2, !pinching {
                    try? await Task.sleep(for: .milliseconds(40))
                }
                waitingForFingers = false
                settleIfIdle()
            }
            return
        }
        verticalGuide.isHidden = true
        horizontalGuide.isHidden = true
        let (position, size) = (live.position, live.fontSize)
        live = Live()
        guard position != nil || size != nil else {
            applyLive()
            return
        }
        // The style is what the layer is placed by from here, until the engine's picture of it arrives.
        if let position { style?.positionX = position.x; style?.positionY = position.y }
        if let size { style?.fontSize = size }
        applyLive()
        onAdjust(position, size)
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard let style else { return }
        switch g.state {
        case .began:
            pinching = true
            pinchStartSize = style.fontSize
        case .changed:
            guard pinching, pinchStartSize > 0 else { return }
            live.fontSize = CaptionGestures.pinchedFontSize(from: pinchStartSize, scale: g.scale)
            applyLive()
            if let size = live.fontSize { layOutAgain(fontSize: size) }
        default:
            if pinching {
                pinching = false
                wantedSize = nil
                // The engine holds the pinch's last size; whatever the project now says is laid out again,
                // and if nothing changed, a moment from now, as it was.
                sceneKey = nil
                settleIfIdle()
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    if sceneKey == nil, let project = lastProject, let fonts = lastFonts {
                        configure(
                            project: project, fonts: fonts, suspended: suspended, isPlaying: isPlaying,
                            watermark: lastWatermark)
                    }
                }
            }
        }
    }

    private func secondFingerDown(_ pan: UIPanGestureRecognizer) -> Bool {
        pan.numberOfTouches > 1 || pinchRecogniser.numberOfTouches > 1
    }

    /// How far the finger has gone since it went down.
    private func travelled(_ g: UIPanGestureRecognizer) -> CGPoint {
        guard let down = touchDown?.point else { return g.translation(in: self) }
        return g.location(in: self) - down
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let style else { return }
        switch g.state {
        case .began:
            // What the finger went down on, not what is showing now: a playing video may have moved
            // on to the next caption by the time the pan is recognised.
            let down = touchDown ?? (g.location(in: self) - g.translation(in: self), caption?.bounds)
            let landed = framePoint(down.point)
            let region = CaptionGestures.dragRegion(
                caption: down.caption, position: (style.positionX, style.positionY), frame: frameSize,
                pixelsPerPoint: frameSize.width / max(1, bounds.width))
            guard region.contains(x: landed.x, y: landed.y) else {
                g.state = .cancelled
                return
            }
            panning = true
            lastTravel = .zero
            dragStart = (style.positionX, style.positionY)
        case .changed:
            // With a second finger down the pan's location is between the two, which is where the
            // pinch is, not where the caption was taken: the caption would jump there.
            guard panning, let start = dragStart, !secondFingerDown(g) else { return }
            lastTravel = travelled(g)
            follow(translation: lastTravel, from: start, final: false)
        case .ended:
            guard panning, let start = dragStart else { return }
            // A drag that ends because a second finger landed ends where the first finger was.
            follow(translation: secondFingerDown(g) ? lastTravel : travelled(g), from: start, final: true)
        default:
            // Cancelled (a second finger joined, which pinches) or failed: what was reached stands.
            if panning {
                panning = false
                dragStart = nil
                settleIfIdle()
            }
        }
    }

    /// Puts the caption where a drag has taken it, through the engine's pull to the centre lines. The
    /// answer comes back asynchronously and only the newest is used; the last one is what is committed.
    private func follow(translation: CGPoint, from start: (x: Double, y: Double), final: Bool) {
        let raw = CaptionGestures.draggedPosition(from: start, translation: translation.asSize, size: bounds.size)
        // At once, on this touch: asked of the engine's actor, the answer waited behind the frames it
        // was drawing, and the caption trailed the finger or stayed behind until it was lifted.
        let snapped = CaptionEngine.snappedPosition(
            x: raw.x, y: raw.y, width: bounds.width, height: bounds.height, threshold: Self.snapPull)
        if final {
            panning = false
            dragStart = nil
        } else {
            guard panning else { return }
            if (snapped.onX && verticalGuide.isHidden) || (snapped.onY && horizontalGuide.isHidden) {
                haptic.selectionChanged()
            }
            verticalGuide.isHidden = !snapped.onX
            horizontalGuide.isHidden = !snapped.onY
        }
        live.position = (snapped.x, snapped.y)
        applyLive()
        if final { settleIfIdle() }
    }
}

private extension CGPoint {
    var asSize: CGSize { CGSize(width: x, height: y) }

    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
}
