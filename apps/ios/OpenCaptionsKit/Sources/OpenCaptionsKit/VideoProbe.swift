import AVFoundation
import CoreMedia

public struct VideoInfo: Equatable, Sendable {
    /// The size as displayed, after the track's rotation.
    public var width: Int
    public var height: Int
    public var fps: Double
    public var duration: Double
    public var hdr: HDRTransfer?
}

public enum VideoProbeError: Error, Sendable {
    case noVideoTrack
}

/// What the server's probe reads at upload: size (after rotation), frame rate,
/// duration, and whether the picture is HDR.
public enum VideoProbe {
    public static func probe(_ url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoProbeError.noVideoTrack
        }
        let (size, transform, fps, formats) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        let duration = try await asset.load(.duration).seconds
        return VideoInfo(
            width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()),
            fps: Double(fps), duration: duration.isFinite ? duration : 0, hdr: hdr(formats.first))
    }

    private static func hdr(_ format: CMFormatDescription?) -> HDRTransfer? {
        guard let format,
            let transfer = CMFormatDescriptionGetExtension(
                format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
        else { return nil }
        if transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String { return .pq }
        if transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String { return .hlg }
        return nil
    }
}
