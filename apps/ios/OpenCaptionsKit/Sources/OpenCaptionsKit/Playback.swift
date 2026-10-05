import AVFoundation
import Observation

/// The editor's one player: the source video, looping as the web preview does. The
/// time is updated about 60 times a second while it plays, so only a small view
/// (the playhead, the timecode) should read it.
@MainActor @Observable
public final class Playback {
    public let player = AVPlayer()
    public private(set) var time: Double = 0
    public private(set) var isPlaying = false
    public private(set) var duration: Double = 0
    /// Stored (not read from the player) so a view that shows it updates when it changes.
    public var isMuted = false {
        didSet { player.isMuted = isMuted }
    }

    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var rateObserver: NSKeyValueObservation?

    public init() {
        // Without a playback category the ringer switch silences the video, as it would a
        // game; a video player should sound regardless of it.
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        player.actionAtItemEnd = .none
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60), queue: .main
        ) { [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds.isFinite ? t.seconds : 0 }
        }
        rateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.isPlaying = playing }
        }
    }

    public func load(_ url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        time = 0
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.seek(to: 0) ; self?.player.play() }
        }
        Task { [weak self] in
            let length = try? await item.asset.load(.duration).seconds
            self?.duration = length.flatMap { $0.isFinite ? $0 : nil } ?? 0
        }
    }

    public func play() { player.play() }
    public func pause() { player.pause() }
    public func toggle() { isPlaying ? pause() : play() }

    /// Seeks exactly (no tolerance), so the caption drawn for `time` matches the frame.
    public func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        time = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public func step(frames: Int, fps: Double) {
        pause()
        seek(to: (time * fps).rounded() / fps + Double(frames) / fps)
    }
}
