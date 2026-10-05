import OpenCaptionsKit
import SwiftUI

/// The editing timeline: a ruler over a video track and a caption track, on a time axis
/// that scrolls and zooms (pinch), with the playhead across them. Dragging anywhere on the
/// timeline scrolls it, and a tap on the ruler or a track seeks; the playhead's handle is
/// what moves the playhead by hand. Tap a caption to select it and seek, drag its edges to
/// retime it.
/// Words are edited on the preview. The edits are the engine's; this is only the UI.
struct CaptionTimeline: View {
    let model: EditorModel
    let playback: Playback

    private static let rulerHeight = 26.0
    private static let videoHeight = 38.0
    private static let captionHeight = 54.0
    private static let labelWidth = 44.0

    @State private var zoom: Double?  // points per second; nil is "fit"
    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var scrollX = 0.0
    @State private var viewport = 0.0
    @State private var pinch: (base: Double, anchorTime: Double)?

    private var duration: Double { max(1, model.project.videoDuration ?? model.transcript?.duration ?? 1) }
    /// A positive offset shows the last captions past the video's end; keep them reachable.
    private var span: Double { duration + max(0, Double(model.project.captionOffsetMs) / 1000) }
    private var fit: Double { viewport > 0 ? viewport / span : 1 }
    private var px: Double { zoom.map { TimelineScale.clampZoom($0, fit: fit) } ?? fit }
    private var contentWidth: Double { zoom == nil ? viewport : span * px }

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(
                playback: playback, duration: duration, canZoomOut: zoom != nil,
                canZoomIn: px < max(fit, TimelineScale.maxPointsPerSecond) - 1e-6,
                zoomOut: { zoomButton(1 / 1.5) }, zoomIn: { zoomButton(1.5) }, fit: { zoom = nil })
            HStack(alignment: .top, spacing: 0) {
                labels
                scroller
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

    private var scroller: some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ruler
                    videoTrack
                    captionTrack
                }
                Playhead(playback: playback, px: px, follow: follow, drag: dragPlayhead)
                    .frame(height: Self.rulerHeight + Self.videoHeight + Self.captionHeight)
            }
            .frame(width: contentWidth, alignment: .topLeading)
            .coordinateSpace(.named("track"))
        }
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: Double.self) { $0.contentOffset.x } action: { _, x in scrollX = x }
        .onScrollGeometryChange(for: Double.self) { $0.containerSize.width } action: { _, w in viewport = w }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if pinch == nil {
                        let anchor = TimelineScale.time(
                            atX: value.startLocation.x, scrollOffset: scrollX, pointsPerSecond: px, span: span)
                        pinch = (px, anchor)
                    }
                    guard let pinch else { return }
                    apply(zoom: pinch.base * value.magnification, keeping: pinch.anchorTime, at: value.startLocation.x)
                }
                .onEnded { _ in pinch = nil })
    }

    /// A tap seeks. A drag is left to the scroll view, so the timeline can always be moved by
    /// a finger anywhere on it; the playhead's handle is the way to scrub.
    private var tapToSeek: some Gesture {
        SpatialTapGesture(coordinateSpace: .named("track")).onEnded { tap in
            playback.seek(to: min(span, max(0, tap.location.x / px)))
        }
    }

    /// The handle moved to content position `x`: seek there, and when it nears the edge of
    /// the view scroll on, so a long timeline can be crossed in one drag.
    private func dragPlayhead(toContentX x: Double) {
        playback.seek(to: min(span, max(0, x / px)))
        if x < scrollX + 28 {
            scrollPosition.scrollTo(x: max(0, scrollX - 24))
        } else if x > scrollX + viewport - 28 {
            scrollPosition.scrollTo(x: scrollX + 24)
        }
    }

    private var ruler: some View {
        Canvas { context, size in
            let step = TimelineScale.tickStep(pointsPerSecond: px)
            let first = max(0, Int(((scrollX - 80) / px / step).rounded(.down)))
            let last = min(Int(span / step), Int(((scrollX + viewport + 80) / px / step).rounded(.up)))
            guard first <= last else { return }
            for i in first...last {
                let t = Double(i) * step
                let x = t * px
                context.fill(Path(CGRect(x: x, y: size.height - 8, width: 1, height: 8)), with: .color(Theme.textSecondary.opacity(0.6)))
                context.draw(
                    Text(TimelineScale.tickLabel(t, step: step)).font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary),
                    at: CGPoint(x: x + 3, y: size.height / 2 - 2), anchor: .leading)
            }
        }
        .frame(width: contentWidth, height: Self.rulerHeight)
        .contentShape(.rect)
        .gesture(tapToSeek)
        .accessibilityLabel("Timeline ruler")
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
        .frame(width: contentWidth, height: Self.videoHeight)
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
                        playback.seek(to: min(span, max(0, tap.location.x / px)))
                    })
            ForEach(model.lines, id: \.from) { line in
                CaptionBlock(
                    line: line, px: px, selected: model.selectedLine == line.from,
                    select: {
                        model.selectedLine = line.from
                        playback.seek(to: $0)
                    },
                    retime: { edge, time in
                        playback.seek(to: time)
                        model.retime(index: edge == .start ? line.from : line.from + line.count - 1, edge: edge, time: time)
                    },
                    span: span)
            }
        }
        .frame(width: contentWidth, height: Self.captionHeight, alignment: .topLeading)
    }

    // MARK: Zoom

    private func apply(zoom target: Double, keeping time: Double, at anchorX: Double) {
        let clamped = TimelineScale.clampZoom(target, fit: fit)
        zoom = clamped <= fit * 1.001 ? nil : clamped
        scrollPosition.scrollTo(
            x: TimelineScale.scrollOffset(keeping: time, at: anchorX, pointsPerSecond: clamped))
    }

    /// The buttons zoom around the playhead, or the middle of the view if it is out of sight.
    private func zoomButton(_ factor: Double) {
        let head = playback.time * px - scrollX
        let anchorX = (0...viewport).contains(head) ? head : viewport / 2
        let time = TimelineScale.time(atX: anchorX, scrollOffset: scrollX, pointsPerSecond: px, span: span)
        apply(zoom: px * factor, keeping: time, at: anchorX)
    }

    /// While playing, keep the playhead in view.
    private func follow(_ time: Double) {
        let x = time * px
        guard playback.isPlaying, x < scrollX || x > scrollX + viewport else { return }
        scrollPosition.scrollTo(x: max(0, x - viewport / 4))
    }
}

/// The playhead: the only part of the timeline that moves with the playing time. The round
/// handle at the top is what is dragged to move it, with a touch target well past its size.
private struct Playhead: View {
    let playback: Playback
    let px: Double
    let follow: (Double) -> Void
    let drag: (Double) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.white)
                .frame(width: 2)
                .shadow(color: .black.opacity(0.5), radius: 1.5)
                .allowsHitTesting(false)
            Circle()
                .fill(.white)
                .overlay(Circle().stroke(.black.opacity(0.25), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                .frame(width: 16, height: 16)
                .padding(14)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { drag($0.location.x) }
                )
                .accessibilityLabel("Playhead")
                .accessibilityHint("Drag to move through the video")
        }
        .frame(width: 44)
        .offset(x: playback.time * px - 22)
        .onChange(of: playback.time) { _, time in follow(time) }
    }
}

/// One caption line. A selected one has a handle on each edge that retimes it.
private struct CaptionBlock: View {
    let line: CaptionLine
    let px: Double
    let selected: Bool
    let select: (_ time: Double) -> Void
    let retime: (_ edge: CaptionEdge, _ time: Double) -> Void
    let span: Double

    var body: some View {
        let width = max((line.end - line.start) * px, 4)
        RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Theme.accent : Color.white.opacity(0.13))
            .overlay {
                RoundedRectangle(cornerRadius: 9).stroke(selected ? Theme.accent : Color.white.opacity(0.22), lineWidth: 1)
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
            .fill(.white)
            .overlay(Capsule().stroke(.black.opacity(0.3), lineWidth: 1))
            .frame(width: 6, height: 28)
            .padding(.horizontal, 12)
            .contentShape(.rect)
            .offset(x: edge == .start ? -12 : 12)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("track")).onChanged { drag in
                    retime(edge, min(span, max(0, drag.location.x / px)))
                }
            )
            .accessibilityLabel(edge == .start ? "Caption start" : "Caption end")
    }
}
