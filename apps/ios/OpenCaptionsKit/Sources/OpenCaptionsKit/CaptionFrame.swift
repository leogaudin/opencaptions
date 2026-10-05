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
