import CoreImage
import Foundation

/// One engine frame: `width` x `height` x 4 bytes of straight-alpha RGBA.
public struct CaptionFrame: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rgba: Data

    public init(width: Int, height: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    /// The overlay as a Core Image image, ready to composite. Core Image works with
    /// premultiplied alpha, and the engine's frame is straight, so it is converted.
    public var ciImage: CIImage {
        CIImage(
            bitmapData: rgba, bytesPerRow: width * 4, size: CGSize(width: width, height: height),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        ).premultiplyingAlpha()
    }
}

extension CaptionFrame {
    /// The overlay as a CGImage, premultiplied, for a layer to show.
    public func cgImage(using context: CIContext) -> CGImage? {
        context.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height))
    }
}

extension CaptionFrame {
    /// How much brighter than reference white (the white of an SDR picture, 203 nits in PQ)
    /// captions are over an HDR video. Real footage has its diffuse whites (a wall, a sky, a shirt)
    /// at about one and a half times reference white, with highlights above: a caption at twice
    /// it was no brighter than the wall behind it and read as dim grey. At four times (about 800
    /// nits in PQ, the top of the range in HLG) it is the brightest thing in the picture. The
    /// preview and the export use the same factor.
    public static let hdrWhiteScale = 4.0

    /// The overlay for an HDR video's preview: half-float, in extended linear sRGB, with white at
    /// `hdrWhiteScale` (a layer showing it must set `wantsExtendedDynamicRangeContent`).
    public func hdrCGImage(using context: CIContext) -> CGImage? {
        context.createCGImage(
            ciImage.scaled(by: Self.hdrWhiteScale), from: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }
}

extension CIImage {
    /// Premultiplied colour scaled by `gain` (alpha unchanged), in the context's linear working space.
    func scaled(by gain: Double) -> CIImage {
        guard gain != 1 else { return self }
        return applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
    }
}
