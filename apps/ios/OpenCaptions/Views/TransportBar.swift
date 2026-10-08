import OpenCaptionsKit
import SwiftUI

/// Play/pause, the timecode and mute, with the timeline's zoom controls at the right.
struct TransportBar: View {
    let playback: Playback
    let duration: Double
    let canFit: Bool
    let canUndo: Bool
    let canRedo: Bool
    let fit: () -> Void
    let undo: () -> Void
    let redo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button { playback.toggle() } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .frame(width: 36, height: 36)
                    .background(Theme.textPrimary, in: .circle)
            }
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
            Timecode(playback: playback, duration: duration)
            Spacer()
            Button { playback.isMuted.toggle() } label: {
                Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(playback.isMuted ? Theme.textSecondary : Theme.textPrimary)
            }
            .accessibilityLabel(playback.isMuted ? "Unmute" : "Mute")
            tool("arrow.left.and.right", "Fit the whole video", enabled: canFit, fit)
            tool("arrow.uturn.backward", "Undo", enabled: canUndo, undo)
            tool("arrow.uturn.forward", "Redo", enabled: canRedo, redo)
        }
        .buttonStyle(.plain)
        .font(.system(size: 17))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func tool(_ symbol: String, _ label: LocalizedStringKey, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(enabled ? Theme.textPrimary : Theme.textSecondary.opacity(0.4))
                .frame(minWidth: 40, minHeight: 44).contentShape(.rect)
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
        VStack(alignment: .leading, spacing: 1) {
            Text(TimelineScale.timecode(playback.time))
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(TimelineScale.timecode(duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TimelineScale.timecode(playback.time) + " / " + TimelineScale.timecode(duration))
    }
}
