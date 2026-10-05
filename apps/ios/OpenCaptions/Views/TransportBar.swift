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
        HStack(spacing: 16) {
            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(.white, in: .circle)
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Timecode(playback: playback, duration: duration)
            Button { playback.isMuted.toggle() } label: {
                Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(playback.isMuted ? Theme.textSecondary : Theme.textPrimary)
            }
            .accessibilityLabel(playback.isMuted ? "Unmute" : "Mute")
            Spacer()
            tool("minus.magnifyingglass", "Zoom out", enabled: canZoomOut, zoomOut)
            tool("plus.magnifyingglass", "Zoom in", enabled: canZoomIn, zoomIn)
            tool("arrow.left.and.right", "Fit the whole video", enabled: canZoomOut, fit)
        }
        .buttonStyle(.plain)
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func tool(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(enabled ? Theme.textPrimary : Theme.textSecondary.opacity(0.4))
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// The only view that reads the playing time besides the playhead.
private struct Timecode: View {
    let playback: Playback
    let duration: Double

    var body: some View {
        (Text(TimelineScale.timecode(playback.time)).foregroundStyle(Theme.textPrimary)
            + Text(" / " + TimelineScale.timecode(duration)).foregroundStyle(Theme.textSecondary))
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
    }
}
