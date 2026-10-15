import AVFoundation
import CoreImage
import OpenCaptionsKit
import SwiftUI

#if os(iOS)
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
        view.core.onTogglePlay = onTogglePlay
        view.core.onAdjust = onAdjust
        view.core.onEditWord = onEditWord
        return area
    }

    func updateUIView(_ area: PreviewArea, context: Context) {
        area.ratio = ratio
        let view = area.preview
        view.core.onTogglePlay = onTogglePlay
        view.core.onAdjust = onAdjust
        view.core.onEditWord = onEditWord
        view.core.configure(
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

/// The iPhone's host of the preview: a view that lets `PreviewCore` draw on its layer, and turns its touch
/// recognisers into the core's intents.
final class PreviewUIView: UIView, UIGestureRecognizerDelegate {
    private let player: AVPlayer
    /// The drawing and the caption's live state. It starts when first asked for, which is right after the
    /// view exists and has the layer it draws on.
    private(set) lazy var core = PreviewCore(player: player, host: layer)
    /// Added by the area around the picture, so that it reaches past it.
    let pinchRecogniser = UIPinchGestureRecognizer()

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        #if DEBUG
            // Found by the UI tests, which drive the gestures.
            isAccessibilityElement = true
            accessibilityIdentifier = "preview"
            accessibilityLabel = "Video preview"
        #endif
        core.screenScale = UIScreen.main.scale
        core.pinchTouches = { [weak self] in self?.pinchRecogniser.numberOfTouches ?? 0 }
        core.onDrawn = { [weak self] in
            #if DEBUG
                self?.accessibilityValue = "drawn"  // the UI tests wait for this
            #endif
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
            core.touchLanded(at: touch.location(in: self))
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
            || (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        core.layOut(in: bounds.size)
    }

    @objc private func tapped() { core.tap() }

    @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
        core.doubleTap(at: g.location(in: self))
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began: core.pinchBegan()
        case .changed: core.pinchChanged(scale: g.scale)
        default: core.pinchEnded()
        }
    }

    private func secondFingerDown(_ pan: UIPanGestureRecognizer) -> Bool {
        pan.numberOfTouches > 1 || pinchRecogniser.numberOfTouches > 1
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let (location, translation) = (g.location(in: self), g.translation(in: self))
        switch g.state {
        case .began:
            if !core.dragBegan(location: location, translation: translation) { g.state = .cancelled }
        case .changed:
            core.dragChanged(location: location, translation: translation, secondFingerDown: secondFingerDown(g))
        case .ended:
            core.dragEnded(location: location, translation: translation, secondFingerDown: secondFingerDown(g))
        default:
            core.dragCancelled()
        }
    }
}

#else

import AppKit

/// The Mac's preview: the same core, hosted by an AppKit view. A click plays or pauses, a double click edits
/// the word under it, a drag moves the caption, and a pinch on the trackpad changes its size.
struct PreviewView: NSViewRepresentable {
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
    /// Where a drag and a pinch settled (either may be nil), once the pointer is up.
    let onAdjust: (_ position: (x: Double, y: Double)?, _ fontSize: Int?) -> Void
    let onEditWord: (_ index: Int) -> Void

    func makeNSView(context: Context) -> PreviewNSArea {
        let area = PreviewNSArea(player: playback.player)
        wire(area.preview.core)
        return area
    }

    func updateNSView(_ area: PreviewNSArea, context: Context) {
        area.ratio = ratio
        let core = area.preview.core
        wire(core)
        core.configure(
            project: project, fonts: fonts, suspended: suspended, isPlaying: playback.isPlaying, watermark: watermark)
    }

    private func wire(_ core: PreviewCore) {
        core.onTogglePlay = onTogglePlay
        core.onAdjust = onAdjust
        core.onEditWord = onEditWord
    }
}

/// All the room the preview is given, with the video fitted in the middle of it. A pinch anywhere in it
/// changes the caption's size; a drag, a click and a double click stay on the picture.
final class PreviewNSArea: NSView {
    let preview: PreviewNSView
    var ratio = 9.0 / 16.0 { didSet { needsLayout = true } }

    init(player: AVPlayer) {
        preview = PreviewNSView(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        addSubview(preview)
        addGestureRecognizer(preview.magnifyRecogniser)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0, ratio > 0 else { return }
        let size = bounds.width / bounds.height > ratio
            ? CGSize(width: bounds.height * ratio, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / ratio)
        preview.frame = CGRect(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
            width: size.width, height: size.height)
    }
}

final class PreviewNSView: NSView, NSGestureRecognizerDelegate {
    private let player: AVPlayer
    /// The drawing and the caption's live state. A Mac layer has its origin at the bottom, so the core lays
    /// its own layers out from the top inside it. It starts when first asked for, which is right after the
    /// view has the layer it draws on.
    private(set) lazy var core = PreviewCore(player: player, host: layer ?? CALayer(), flipped: true)
    /// Added by the area around the picture, so that it reaches past it.
    let magnifyRecogniser = NSMagnificationGestureRecognizer()
    private let single = NSClickGestureRecognizer()
    private let double = NSClickGestureRecognizer()
    private let pan = NSPanGestureRecognizer()

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)

        single.target = self
        single.action = #selector(clicked)
        double.target = self
        double.action = #selector(doubleClicked)
        double.numberOfClicksRequired = 2
        pan.target = self
        pan.action = #selector(panned)
        magnifyRecogniser.target = self
        magnifyRecogniser.action = #selector(magnified)
        for recogniser in [single, double, pan] {
            recogniser.delegate = self
            addGestureRecognizer(recogniser)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A point of this view with its origin at the top left, as the engine and the gestures measure.
    private func fromTop(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: bounds.height - p.y) }

    override func layout() {
        super.layout()
        core.screenScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        core.hdrHeadroom = { [weak self] in
            Double((self?.window?.screen ?? NSScreen.main)?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        }
        core.layOut(in: bounds.size)
    }

    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        if gestureRecognizer === pan {
            core.touchLanded(at: fromTop(convert(event.locationInWindow, from: nil)))
        }
        return true
    }

    /// A single click waits to see whether it is the first of two.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer) -> Bool {
        gestureRecognizer === single && other === double
    }

    @objc private func clicked(_ g: NSClickGestureRecognizer) { core.tap() }

    @objc private func doubleClicked(_ g: NSClickGestureRecognizer) {
        core.doubleTap(at: fromTop(g.location(in: self)))
    }

    @objc private func magnified(_ g: NSMagnificationGestureRecognizer) {
        switch g.state {
        case .began: core.pinchBegan()
        case .changed: core.pinchChanged(scale: 1 + g.magnification)
        default: core.pinchEnded()
        }
    }

    @objc private func panned(_ g: NSPanGestureRecognizer) {
        let location = fromTop(g.location(in: self))
        let t = g.translation(in: self)
        let translation = CGPoint(x: t.x, y: -t.y)
        switch g.state {
        case .began: _ = core.dragBegan(location: location, translation: translation)
        case .changed: core.dragChanged(location: location, translation: translation, secondFingerDown: false)
        case .ended: core.dragEnded(location: location, translation: translation, secondFingerDown: false)
        default: core.dragCancelled()
        }
    }
}

#endif
