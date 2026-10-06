import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// The name of an export on disk: a hash of everything that decides its pixels, so an
/// unchanged project is saved again at once. Local to the phone (it is not the
/// server's hash), but built the same way: the inputs in canonical JSON.
public enum ExportKey {
    private struct Inputs: Encodable {
        var transcript: Transcript
        var style: StyleConfig
        var captionOffsetMs: Int
        var format: String
        var width: Int
        var height: Int
        var fps: Double

        enum CodingKeys: String, CodingKey {
            case transcript, style, format, width, height, fps
            case captionOffsetMs = "caption_offset_ms"
        }
    }

    /// 16 hex characters; nil for a project that has nothing to export yet.
    public static func hash(for project: Project, format: String? = nil, options: ExportOptions = .standard) -> String? {
        guard let transcript = project.transcript else { return nil }
        let format = format ?? options.signature(for: project)
        let inputs = Inputs(
            transcript: transcript, style: project.styleConfig, captionOffsetMs: project.captionOffsetMs,
            format: format, width: project.videoWidth ?? 0, height: project.videoHeight ?? 0,
            fps: project.videoFps ?? 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(inputs) else { return nil }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// How a video track's `preferredTransform` turns its stored picture into the one shown.
public enum VideoOrientation {
    /// The orientation Core Image should apply to a decoded frame to make it upright.
    public static func from(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (Int(t.a.rounded()), Int(t.b.rounded()), Int(t.c.rounded()), Int(t.d.rounded())) {
        case (0, 1, -1, 0): .right  // rotated 90° clockwise
        case (0, -1, 1, 0): .left  // rotated 90° counter-clockwise
        case (-1, 0, 0, -1): .down
        case (-1, 0, 0, 1): .upMirrored
        case (1, 0, 0, -1): .downMirrored
        case (0, 1, 1, 0): .leftMirrored
        case (0, -1, -1, 0): .rightMirrored
        default: .up
        }
    }
}
