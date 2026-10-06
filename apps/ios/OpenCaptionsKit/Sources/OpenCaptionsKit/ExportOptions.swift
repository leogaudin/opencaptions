import Foundation

/// What a saved video is like: how it is encoded, how large, at what frame rate, and whether an HDR
/// source stays HDR. The defaults keep the video as it was, in a format everything plays.
public struct ExportOptions: Codable, Equatable, Sendable {
    public enum Codec: String, Codable, CaseIterable, Sendable {
        /// Plays everywhere; larger files.
        case h264
        /// About a third smaller at the same quality; plays on every recent phone and computer,
        /// but not on some old players and sites.
        case hevc
    }

    /// Bits per pixel per frame, for H.264. There is no quality choice: a saved video is a second
    /// encoding of the source, so it is made as good as it can be, and the size is chosen with the
    /// resolution and the frame rate.
    static let bitsPerPixel = 0.28

    /// The size, as the short side of the picture (so 1080 is 1080 × 1920 upright, and 1920 × 1080
    /// sideways). A video is never made larger than it was.
    public enum Resolution: String, Codable, CaseIterable, Sendable {
        case original, p2160, p1080, p720

        public var shortSide: Int? {
            switch self {
            case .original: nil
            case .p2160: 2160
            case .p1080: 1080
            case .p720: 720
            }
        }

        /// The choices worth offering for a video whose short side is `side`: its own size, and each
        /// smaller one.
        public static func available(forShortSide side: Int) -> [Resolution] {
            [.original] + allCases.filter { ($0.shortSide ?? .max) < side }
        }
    }

    /// The frame rate: the source's, or another. A higher rate than the source's repeats its frames
    /// but draws the captions at each, so their animation is smoother; a lower one keeps evenly
    /// spaced frames.
    public enum FrameRate: String, Codable, CaseIterable, Sendable {
        case original, fps30, fps60

        public var value: Double? {
            switch self {
            case .original: nil
            case .fps30: 30
            case .fps60: 60
            }
        }

        /// The choices for a source at `fps`: its own rate, and the others (not one it already is).
        public static func available(forSourceFps fps: Double) -> [FrameRate] {
            [.original] + allCases.filter { rate in rate.value.map { abs($0 - fps) > 0.5 } ?? false }
        }
    }

    public var codec: Codec
    public var resolution: Resolution
    /// For an HDR source: keep it HDR (always HEVC, 10-bit) or make an ordinary SDR video.
    public var keepHDR: Bool
    public var frameRate: FrameRate

    public init(
        codec: Codec = .h264, resolution: Resolution = .original, keepHDR: Bool = true, frameRate: FrameRate = .original
    ) {
        self.codec = codec
        self.resolution = resolution
        self.keepHDR = keepHDR
        self.frameRate = frameRate
    }

    /// The saved video's frame rate for a source at `source`.
    public func outputFps(source: Double) -> Double {
        frameRate.value ?? source
    }

    public static let standard = ExportOptions()

    /// How a project is encoded under these options: an HDR source kept as HDR is 10-bit HEVC, since
    /// H.264 cannot carry it; anything else is SDR in the chosen codec.
    public struct Plan: Equatable, Sendable {
        public var transfer: HDRTransfer?
        public var codec: Codec
    }

    public func plan(for project: Project) -> Plan {
        if let transfer = project.hdrTransfer, keepHDR { return Plan(transfer: transfer, codec: .hevc) }
        return Plan(transfer: nil, codec: codec)
    }

    /// The picture's size for a source of `width` × `height`, even in both (encoders need it).
    public func outputSize(width: Int, height: Int) -> (width: Int, height: Int) {
        func even(_ value: Double) -> Int { max(2, Int(value.rounded()) & ~1) }
        let short = min(width, height)
        guard let target = resolution.shortSide, target < short else { return (even(Double(width)), even(Double(height))) }
        let scale = Double(target) / Double(short)
        return (even(Double(width) * scale), even(Double(height) * scale))
    }

    /// The video's bitrate, from its size and rate: HEVC needs about two thirds of
    /// H.264's for the same picture, except in HDR, where the extra range uses what it saves.
    func bitrate(width: Int, height: Int, fps: Double, plan: Plan) -> Int {
        let efficiency = plan.codec == .hevc && plan.transfer == nil ? 0.65 : 1.0
        let bits = Double(width * height) * fps * Self.bitsPerPixel * efficiency
        return min(80_000_000, max(2_000_000, Int(bits)))
    }

    /// About how large the file is, in bytes, for a project (the video's bits plus 128 kbit/s of audio).
    public func estimatedBytes(for project: Project) -> Int64? {
        guard let width = project.videoWidth, let height = project.videoHeight,
            let seconds = project.videoDuration, seconds > 0
        else { return nil }
        let size = outputSize(width: width, height: height)
        let fps = outputFps(source: project.videoFps ?? 30)
        let rate = bitrate(width: size.width, height: size.height, fps: fps, plan: plan(for: project))
        return Int64(Double(rate + 128_000) * seconds / 8)
    }

    /// What of these options decides the file (for its name): nothing the source cannot use.
    func signature(for project: Project) -> String {
        let plan = plan(for: project)
        let format = switch (plan.transfer, plan.codec) {
        case (.pq?, _): "hevc10-pq"
        case (.hlg?, _): "hevc10-hlg"
        case (nil, .hevc): "hevc"
        case (nil, .h264): "h264"
        }
        let rate = frameRate == .original ? "" : "-\(frameRate.rawValue)"
        return "\(format)-\(resolution.rawValue)\(rate)"
    }
}
