import OpenCaptionsKit
import SwiftUI

/// The editing timeline: a ruler over a video track and a caption track. The playhead stays in the
/// middle and the timeline moves under it: dragging it scrubs (and coasts on release), pinching
/// zooms, and the playing video carries it along. A tap on the ruler or a track seeks; tap a
/// caption to select it and seek, drag its edges to retime it.
/// Words are edited on the preview. The edits are the engine's; this is only the UI.
struct CaptionTimeline: View {
    let model: EditorModel
    let playback: Playback

    private static let rulerHeight = 26.0
    private static let videoHeight = 38.0
    private static let captionHeight = 54.0
    private static let labelWidth = 44.0

    @State private var zoom = TimelineScale.defaultPointsPerSecond  // points per second
    @State private var viewport = 0.0
    @State private var pinchBase: Double?
    /// The time a drag of the timeline began at.
    @State private var scrubStart: Double?
    /// Held while a caption edge is dragged: the track stays still, or it would move under the finger.
    @State private var frozenTime: Double?
    @State private var coast: Task<Void, Never>?

    private var duration: Double { max(1, model.project.videoDuration ?? model.transcript?.duration ?? 1) }
    /// A positive offset shows the last captions past the video's end; keep them reachable.
    private var span: Double { duration + max(0, Double(model.project.captionOffsetMs) / 1000) }
    private var fit: Double { viewport > 0 ? TimelineScale.fit(viewport: viewport, span: span) : 1 }
    private var px: Double { TimelineScale.clampZoom(zoom, fit: fit) }
    private var atFit: Bool { px <= fit * 1.001 }
    private var trackWidth: Double { span * px }
    private var height: Double { Self.rulerHeight + Self.videoHeight + Self.captionHeight }

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(
                playback: playback, duration: duration, canFit: !atFit, canUndo: model.canUndo, canRedo: model.canRedo,
                fit: { zoom = fit }, undo: { model.undo() }, redo: { model.redo() })
            HStack(alignment: .top, spacing: 0) {
                labels
                timeline
            }
        }
    }

    private var labels: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: Self.rulerHeight)
            label("film", "Video", height: Self.videoHeight)
            label("captions.bubble", "Captions", height: Self.captionHeight)
            Spacer(minLength: 0)
        }
        .frame(width: Self.labelWidth)
    }

    private func label(_ symbol: String, _ name: String, height: Double) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: Self.labelWidth, height: height)
            .accessibilityLabel(name)
    }

    // MARK: Tracks

    private var timeline: some View {
        // The tracks are far wider than the view: they sit in an overlay, so that they cannot make
        // the screen as wide as they are.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .topLeading) { tracksAndPlayhead }
            .clipped()
            .onGeometryChange(for: Double.self) { $0.size.width } action: { viewport = $0 }
            .contentShape(.rect)
            // A child's own gesture (a caption, an edge) wins over this one.
            .gesture(scrub)
            .simultaneousGesture(pinch)
    }

    private var tracksAndPlayhead: some View {
        ZStack(alignment: .topLeading) {
            TimelineRuler(playback: playback, px: px, span: span, viewport: viewport, frozen: frozenTime)
                .frame(width: viewport, height: Self.rulerHeight)
                .contentShape(.rect)
                .gesture(
                    SpatialTapGesture().onEnded { tap in
                        coast?.cancel()
                        playback.seek(
                            to: TimelineScale.time(
                                atX: tap.location.x, playheadTime: playback.time, pointsPerSecond: px,
                                viewport: viewport, span: span))
                    }
                )
                .accessibilityLabel("Timeline ruler")
            VStack(spacing: 0) {
                Color.clear.frame(height: Self.rulerHeight)
                videoTrack
                captionTrack
            }
            .frame(width: trackWidth, alignment: .topLeading)
            .coordinateSpace(.named("track"))
            .modifier(UnderThePlayhead(playback: playback, px: px, viewport: viewport, frozen: frozenTime))
            playhead
        }
    }

    /// The playhead, in the middle of the view; it does not move, the timeline does.
    private var playhead: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Theme.mark)
                .frame(width: 2)
                .shadow(color: Theme.background.opacity(0.6), radius: 1.5)
            Circle()
                .fill(Theme.mark)
                .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                .frame(width: 12, height: 12)
        }
        .frame(width: 16, height: height)
        .offset(x: viewport / 2 - 8)
        .allowsHitTesting(false)
        .accessibilityLabel("Playhead")
    }

    /// Dragging scrubs: the timeline follows the finger, and coasts a little when it lets go. A
    /// playing video is paused by it.
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { drag in
                if scrubStart == nil {
                    coast?.cancel()
                    scrubStart = playback.time
                    if playback.isPlaying { playback.pause() }
                }
                guard let start = scrubStart else { return }
                playback.seek(
                    to: TimelineScale.scrubbed(from: start, translation: drag.translation.width, pointsPerSecond: px, span: span))
            }
            .onEnded { drag in
                guard let start = scrubStart else { return }
                scrubStart = nil
                coast(
                    to: TimelineScale.scrubbed(
                        from: start, translation: drag.predictedEndTranslation.width, pointsPerSecond: px, span: span))
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBase == nil { pinchBase = px }
                if let base = pinchBase { zoom = TimelineScale.clampZoom(base * value.magnification, fit: fit) }
            }
            .onEnded { _ in pinchBase = nil }
    }

    /// Carries the timeline on after a drag, slowing to rest at where the finger was heading.
    private func coast(to target: Double) {
        let from = playback.time
        guard abs(target - from) * px > 12 else { return }
        coast?.cancel()
        coast = Task { @MainActor in
            let began = Date()
            let length = 0.45
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(began) / length)
                playback.seek(to: from + (target - from) * (1 - pow(1 - t, 3)))
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// A tap in the tracks seeks. A drag is the timeline's own.
    private var tapToSeek: some Gesture {
        SpatialTapGesture(coordinateSpace: .named("track")).onEnded { tap in
            coast?.cancel()
            playback.seek(to: min(span, max(0, tap.location.x / px)))
        }
    }

    private var videoTrack: some View {
        ZStack(alignment: .leading) {
            Color.clear
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.raised)
                .overlay(alignment: .leading) {
                    Text(model.project.title).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary).lineLimit(1).padding(.horizontal, 10)
                }
                .frame(width: duration * px, height: Self.videoHeight - 8)
        }
        .frame(width: trackWidth, height: Self.videoHeight)
        .contentShape(.rect)
        .gesture(tapToSeek)
    }

    private var captionTrack: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(.rect)
                .gesture(
                    SpatialTapGesture(coordinateSpace: .named("track")).onEnded { tap in
                        model.selectedLine = nil
                        coast?.cancel()
                        playback.seek(to: min(span, max(0, tap.location.x / px)))
                    })
            ForEach(model.lines, id: \.from) { line in
                CaptionBlock(
                    line: line, px: px, selected: model.selectedLine == line.from,
                    select: {
                        model.selectedLine = line.from
                        coast?.cancel()
                        playback.seek(to: $0)
                    },
                    retime: { edge, time in
                        // The track holds still under the finger while an edge is dragged.
                        if frozenTime == nil { coast?.cancel(); frozenTime = playback.time }
                        playback.seek(to: time)
                        model.retime(index: edge == .start ? line.from : line.from + line.count - 1, edge: edge, time: time)
                    },
                    release: {
                        // Then the track settles on the edge, under the playhead.
                        withAnimation(.easeOut(duration: 0.25)) { frozenTime = nil }
                    },
                    span: span)
            }
        }
        .frame(width: trackWidth, height: Self.captionHeight, alignment: .topLeading)
    }
}

/// Moves the tracks so that the playhead's time is in the middle of the view. Only this reads the
/// playing time, so the tracks themselves are not laid out again every frame.
private struct UnderThePlayhead: ViewModifier {
    let playback: Playback
    let px: Double
    let viewport: Double
    let frozen: Double?

    func body(content: Content) -> some View {
        content.offset(
            x: TimelineScale.trackOrigin(time: frozen ?? playback.time, pointsPerSecond: px, viewport: viewport))
    }
}

/// The time axis, drawn for what is in view around the playhead: it reads the playing time, so
/// it is the one piece (with the tracks' offset) redrawn each frame.
private struct TimelineRuler: View {
    let playback: Playback
    let px: Double
    let span: Double
    let viewport: Double
    let frozen: Double?

    var body: some View {
        let origin = TimelineScale.trackOrigin(time: frozen ?? playback.time, pointsPerSecond: px, viewport: viewport)
        Canvas { context, size in
            let step = TimelineScale.tickStep(pointsPerSecond: px)
            let first = max(0, Int(((-origin - 80) / px / step).rounded(.down)))
            let last = min(Int(span / step), Int(((-origin + viewport + 80) / px / step).rounded(.up)))
            guard first <= last else { return }
            for i in first...last {
                let t = Double(i) * step
                let x = origin + t * px
                context.fill(Path(CGRect(x: x, y: size.height - 8, width: 1, height: 8)), with: .color(Theme.textSecondary.opacity(0.6)))
                context.draw(
                    Text(TimelineScale.tickLabel(t, step: step)).font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary),
                    at: CGPoint(x: x + 3, y: size.height / 2 - 2), anchor: .leading)
            }
        }
    }
}

/// One caption line. A selected one has a handle on each edge that retimes it.
private struct CaptionBlock: View {
    let line: CaptionLine
    let px: Double
    let selected: Bool
    let select: (_ time: Double) -> Void
    let retime: (_ edge: CaptionEdge, _ time: Double) -> Void
    let release: () -> Void
    let span: Double

    var body: some View {
        let width = max((line.end - line.start) * px, 4)
        RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Theme.accent : Theme.textPrimary.opacity(0.10))
            .overlay {
                RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.accent : Theme.textPrimary.opacity(0.2), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Text(line.text).font(.system(size: 12, weight: .bold)).lineLimit(1).padding(.horizontal, 9)
                    .foregroundStyle(selected ? Theme.onAccent : Theme.textPrimary)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: 40)
            .contentShape(.rect)
            .gesture(
                SpatialTapGesture(coordinateSpace: .named("track")).onEnded { tap in
                    select(min(span, max(0, tap.location.x / px)))
                }
            )
            .overlay(alignment: .leading) { if selected { handle(.start) } }
            .overlay(alignment: .trailing) { if selected { handle(.end) } }
            .offset(x: line.start * px, y: 7)
            .accessibilityLabel(line.text)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// A narrow bar with a wider touch target, dragged along the track.
    private func handle(_ edge: CaptionEdge) -> some View {
        Capsule()
            .fill(Theme.mark)
            .overlay(Capsule().stroke(Theme.background, lineWidth: 1.5))
            .frame(width: 6, height: 28)
            .padding(.horizontal, 12)
            .contentShape(.rect)
            .offset(x: edge == .start ? -12 : 12)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("track"))
                    .onChanged { drag in retime(edge, min(span, max(0, drag.location.x / px))) }
                    .onEnded { _ in release() }
            )
            .accessibilityLabel(edge == .start ? "Caption start" : "Caption end")
    }
}
