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
    /// Held while an export owns the engine.
    var suspended = false
    let onTogglePlay: () -> Void
    let onMove: (_ x: Double, _ y: Double) -> Void
    let onEditWord: (_ index: Int) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(player: playback.player)
        view.onTogglePlay = onTogglePlay
        view.onMove = onMove
        view.onEditWord = onEditWord
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.onTogglePlay = onTogglePlay
        view.onMove = onMove
        view.onEditWord = onEditWord
        view.configure(project: project, fonts: fonts, suspended: suspended, isPlaying: playback.isPlaying)
    }
}

final class PreviewUIView: UIView {
    private let playerLayer: AVPlayerLayer
    private let overlay = CALayer()
    private let player: AVPlayer
    private let engine = CaptionEngine.shared
    private let ciContext = CIContext()
    nonisolated(unsafe) private var timeObserver: Any?

    var onTogglePlay: () -> Void = {}
    var onMove: (Double, Double) -> Void = { _, _ in }
    var onEditWord: (Int) -> Void = { _ in }

    // The scene the engine holds is rebuilt when any of this changes.
    private struct SceneKey: Equatable {
        var transcript: Transcript
        var style: StyleConfig
        var offsetMs: Int
        var width: Int
        var height: Int
    }
    private var sceneKey: SceneKey?
    private var generation = 0
    private var ready = false
    private var suspended = false
    private var isPlaying = false
    private var wordsPerLine = 3
    private var style: StyleConfig?
    private var frameSize = CGSize.zero
    private var caption: ActiveCaption?
    private var drawing = false
    private var pendingTime: Double?
    private var dragStart: (x: Double, y: Double)?

    init(player: AVPlayer) {
        self.player = player
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
        overlay.contentsGravity = .resize
        overlay.magnificationFilter = .trilinear
        layer.addSublayer(overlay)

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
        pan.maximumNumberOfTouches = 1
        [single, double, pan].forEach(addGestureRecognizer)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
        overlay.frame = bounds
        // The scene is sized to the view, so a new size lays it out again.
        if let lastProject, let lastFonts {
            configure(project: lastProject, fonts: lastFonts, suspended: suspended, isPlaying: isPlaying)
        }
    }

    private var lastProject: Project?
    private var lastFonts: FontCache?

    @MainActor
    func configure(project: Project, fonts: FontCache, suspended: Bool, isPlaying: Bool) {
        lastProject = project
        lastFonts = fonts
        // An export replaced the engine's scene; ours must be laid out again.
        if self.suspended, !suspended { sceneKey = nil }
        self.suspended = suspended
        self.isPlaying = isPlaying
        style = project.styleConfig
        wordsPerLine = project.styleConfig.wordsPerLine
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
            transcript: transcript, style: project.styleConfig, offsetMs: project.captionOffsetMs,
            width: width, height: height)
        guard key != sceneKey else { return }
        sceneKey = key
        ready = false
        generation += 1
        let mine = generation
        Task { [engine] in
            await engine.ensureFont(key.style.font, cache: fonts)
            guard mine == generation else { return }
            try? await engine.setScene(
                transcript: key.transcript, style: key.style, width: width, height: height,
                captionOffsetMs: key.offsetMs)
            guard mine == generation else { return }
            ready = true
            requestDraw(at: player.currentTime().seconds)
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
                let frame = await engine.render(at: t)
                let active = await engine.activeCaption()
                if !suspended {
                    caption = active
                    if let frame { overlay.contents = frame.cgImage(using: ciContext) }
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

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let style, !isPlaying else { return }
        switch g.state {
        case .began:
            let p = framePoint(g.location(in: self))
            guard let caption, caption.bounds.contains(x: p.x, y: p.y) else {
                g.state = .cancelled
                return
            }
            dragStart = (style.positionX, style.positionY)
        case .changed:
            guard let start = dragStart else { return }
            let moved = CaptionGestures.draggedPosition(
                from: start, translation: g.translation(in: self).asSize, size: bounds.size)
            onMove(moved.x, moved.y)
        default:
            dragStart = nil
        }
    }
}

private extension CGPoint {
    var asSize: CGSize { CGSize(width: x, height: y) }
}
