import AppKit
// A store screenshot: a phone on a coloured background with a headline above it.
// usage: compose in.png out.png "Headline with [highlight]|second line" yellow|dark width height [radius] [size] [top]
//   in.png    a simulator screenshot            [highlight] boxes the words between the brackets
//   |         ends a line (headlines are broken by hand)
//   radius, size, top: the device's corner radius and the headline's size (shares of the width), and
//   where the device's top edge sits (a share of the height; 0.27 by default)
let a = CommandLine.arguments
let src = NSImage(contentsOfFile: a[1])!
let (W, H) = (CGFloat(Int(a[5])!), CGFloat(Int(a[6])!))
let dark = a[4] == "dark"
let yellow = NSColor(srgbRed: 1, green: 0.867, blue: 0, alpha: 1)
let ink = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.045, alpha: 1)
// The headline face is the one the engine bundles, found from this file's place in the repository.
let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("engine/fonts/Poppins-ExtraBold.ttf")
CTFontManagerRegisterFontsForURL(fonts as CFURL, .process, nil)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
(dark ? ink : yellow).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
// the caption-bar pattern: rows of rounded bars, offset row to row
var seed: UInt64 = 7
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 1000) / 1000 }
let rowH = W * 0.052, gap = W * 0.03
var y = -rowH * 0.5, row = 0
(dark ? NSColor(white: 1, alpha: 0.05) : NSColor(srgbRed: 0.93, green: 0.76, blue: 0, alpha: 1)).setFill()
while y < H {
    var x = -W * 0.2 * rnd()
    while x < W {
        let w = W * (0.12 + 0.2 * rnd())
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: rowH), xRadius: rowH / 2, yRadius: rowH / 2).fill()
        x += w + gap
    }
    y += rowH + gap; row += 1
}
// the device: top edge at 27% of the height, bleeding off the bottom
let devTop = H * (a.count > 9 ? CGFloat(Double(a[9])!) : 0.27)
let dw = W * 0.82, dh = dw * src.size.height / src.size.width
let dev = NSRect(x: (W - dw) / 2, y: H - devTop - dh, width: dw, height: dh)
let radius = dw * (a.count > 7 ? CGFloat(Double(a[7])!) : 0.085), bezel = dw * 0.018
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowBlurRadius = 60; sh.shadowOffset = NSSize(width: 0, height: -20); sh.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.6 : 0.3); sh.set()
ink.setFill(); NSBezierPath(roundedRect: dev.insetBy(dx: -bezel, dy: -bezel), xRadius: radius + bezel, yRadius: radius + bezel).fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
NSBezierPath(roundedRect: dev, xRadius: radius, yRadius: radius).addClip()
src.draw(in: dev)
NSGraphicsContext.restoreGraphicsState()
// the headline, centred between the top of the frame and the top of the device, with the key words in a box
let size = W * (a.count > 8 ? CGFloat(Double(a[8])!) : 0.083)
let font = NSFont(name: "Poppins-ExtraBold", size: size) ?? NSFont.systemFont(ofSize: size, weight: .heavy)
var inBox = false
// "|" ends a line: the headline is broken by hand, so it never leaves one word alone.
var lines: [[(String, Bool)]] = []
for part in a[3].split(separator: "|") {
    var words: [(String, Bool)] = []
    for token in part.split(separator: " ", omittingEmptySubsequences: true) {
        var t = String(token)
        if t.hasPrefix("[") { inBox = true; t.removeFirst() }
        let closes = t.hasSuffix("]") || t.contains("].")
        words.append((t.replacingOccurrences(of: "]", with: ""), inBox))
        if closes { inBox = false }
    }
    lines.append(words)
}
func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
let space = width(" "), padX = size * 0.22
let lineH = size * 1.42
let blockH = lineH * CGFloat(lines.count)
var top = (devTop - blockH) / 2   // distance from the top of the frame
for line in lines {
    // A run of highlighted words is one box, padded at its two ends only.
    let lead = line.indices.map { i in line[i].1 && (i == 0 || !line[i - 1].1) ? padX : 0 }
    let trail = line.indices.map { i in line[i].1 && (i == line.count - 1 || !line[i + 1].1) ? padX : 0 }
    let widths = line.indices.map { width(line[$0].0) + lead[$0] + trail[$0] }
    let total = widths.reduce(0, +) + space * CGFloat(line.count - 1)
    var x = (W - total) / 2
    let base = H - top - lineH   // bottom of this line's box, in AppKit's bottom-up coordinates
    var runStart: CGFloat?
    var cursor = x
    for i in line.indices {
        if line[i].1, lead[i] > 0 { runStart = cursor }
        if line[i].1, trail[i] > 0, let start = runStart {
            (dark ? yellow : ink).setFill()
            NSBezierPath(roundedRect: NSRect(x: start, y: base + lineH * 0.1, width: cursor + widths[i] - start, height: lineH * 0.82), xRadius: size * 0.22, yRadius: size * 0.22).fill()
            runStart = nil
        }
        cursor += widths[i] + space
    }
    for i in line.indices {
        let (w, boxed) = line[i]
        let colour: NSColor = boxed ? (dark ? ink : yellow) : (dark ? .white : ink)
        (w as NSString).draw(at: NSPoint(x: x + lead[i], y: base + (lineH - font.ascender + font.descender - font.leading) / 2 + size * 0.02), withAttributes: [.font: font, .foregroundColor: colour])
        x += widths[i] + space
    }
    top += lineH
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
