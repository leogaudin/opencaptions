import AppKit
// The Mac's app icons, from the phone's. iOS rounds a full square by itself; the Mac shows the file as it is, so
// the shape is drawn here: Apple's grid, a tile of 824 in 1024 with a soft shadow in the margin.
// usage: swift apps/ios/AppStore/mac-icon.swift   (writes mac-<size>.png beside icon.png)
let set = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("OpenCaptions/Resources/Assets.xcassets/AppIcon.appiconset")
let source = NSImage(contentsOf: set.appendingPathComponent("icon.png"))!
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let side = CGFloat(size), unit = side / 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let tile = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 20 * unit
    shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    source.draw(in: tile)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent("mac-\(size).png"))
}
