import OpenCaptionsKit
import SwiftUI

/// Play/pause, the timecode and mute, with the timeline's zoom controls at the right.
struct TransportBar: View {
    let playback: Playback
    let duration: Double
    let canZoomOut: Bool
    let canZoomIn: Bool
    let zoomOut: () -> Void
    let zoomIn: () -> Void
    let fit: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 28)
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Timecode(playback: playback, duration: duration)
            Button { playback.isMuted.toggle() } label: {
                Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .accessibilityLabel(playback.isMuted ? "Unmute" : "Mute")
            Spacer()
            Button(action: zoomOut) { Image(systemName: "minus.magnifyingglass") }
                .disabled(!canZoomOut).accessibilityLabel("Zoom out")
            Button(action: zoomIn) { Image(systemName: "plus.magnifyingglass") }
                .disabled(!canZoomIn).accessibilityLabel("Zoom in")
            Button(action: fit) { Image(systemName: "arrow.left.and.right") }
                .disabled(!canZoomOut).accessibilityLabel("Fit the whole video")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The only view that reads the playing time besides the playhead.
private struct Timecode: View {
    let playback: Playback
    let duration: Double

    var body: some View {
        (Text(TimelineScale.timecode(playback.time)).foregroundStyle(.primary)
            + Text(" / " + TimelineScale.timecode(duration)).foregroundStyle(.secondary))
            .font(.caption.monospacedDigit())
    }
}
