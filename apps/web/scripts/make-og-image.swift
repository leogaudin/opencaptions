// The picture a link to opencaptions.app shows (Open Graph / social cards): 1200 x 630, the app icon,
// the headline in the site's own face (Montserrat Black, bundled with the engine) and the address.
// Rebuild it after changing the headline, then commit the PNG:
//
//   swiftc -O /abs/path/to/make-og-image.swift -o /tmp/make-og && /tmp/make-og demo-public/og.png
//
// Compile it by its absolute path: the font and the icon are found from this file's own location.
import AppKit

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // apps/web/scripts
let fontURL = here.appendingPathComponent("../../engine/fonts/Montserrat-Black.ttf").standardized
let iconURL = here.appendingPathComponent(
    "../../ios/OpenCaptions/Resources/Assets.xcassets/AppIcon.appiconset/icon.png"
).standardized
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)

let W = 1200, H = 630
let yellow = NSColor(srgbRed: 1, green: 0.88, blue: 0, alpha: 1)
let ink = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 1)
let grey = NSColor(srgbRed: 0.74, green: 0.74, blue: 0.74, alpha: 1)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no bitmap") }
NSGraphicsContext.current = ctx

ink.setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()

func black(_ size: CGFloat) -> NSFont {
    NSFont(name: "Montserrat-Black", size: size) ?? NSFont.systemFont(ofSize: size, weight: .black)
}
func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
    (s as NSString).size(withAttributes: [.font: font]).width
}
func draw(_ s: String, at p: NSPoint, _ font: NSFont, _ color: NSColor) {
    (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
}

let left: CGFloat = 80

// The icon and the name, top left. AppKit's origin is the bottom left corner.
if let icon = NSImage(contentsOf: iconURL) {
    let box = NSRect(x: left, y: CGFloat(H) - 80 - 96, width: 96, height: 96)
    NSBezierPath(roundedRect: box, xRadius: 22, yRadius: 22).addClip()
    icon.draw(in: box)
    ctx.cgContext.resetClip()
}
draw("OpenCaptions", at: NSPoint(x: left + 120, y: CGFloat(H) - 80 - 70), black(46), .white)

// The headline: two lines, the second with its last words boxed in yellow, as on the site. The size
// is the largest at which the widest line fits.
let line1 = "Animated captions"
let line2a = "that "
let line2b = "stop the scroll"
let maxWidth = CGFloat(W) - 2 * left
var size: CGFloat = 96
let pad: CGFloat = 18
while size > 40 {
    let f = black(size)
    let w2 = textWidth(line2a, f) + textWidth(line2b, f) + 2 * pad
    if max(textWidth(line1, f), w2) <= maxWidth { break }
    size -= 1
}
let f = black(size)
let baseline2: CGFloat = 235
let lineHeight = size * 1.28
draw(line1, at: NSPoint(x: left, y: baseline2 + lineHeight - size * 0.22), f, .white)
draw(line2a, at: NSPoint(x: left, y: baseline2 - size * 0.22), f, .white)
let boxX = left + textWidth(line2a, f)
let boxRect = NSRect(x: boxX, y: baseline2 - size * 0.22 - 4, width: textWidth(line2b, f) + 2 * pad,
                     height: size * 1.12)
yellow.setFill()
NSBezierPath(roundedRect: boxRect, xRadius: 14, yRadius: 14).fill()
draw(line2b, at: NSPoint(x: boxX + pad, y: baseline2 - size * 0.22), f, ink)

// What it is, and where.
let sub = NSFont.systemFont(ofSize: 31, weight: .medium)
draw("Free and open source. On your iPhone or your own server.", at: NSPoint(x: left, y: 130), sub, grey)
draw("opencaptions.app", at: NSPoint(x: left, y: 64), black(34), yellow)

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "og.png"
try png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(W)x\(H))")
