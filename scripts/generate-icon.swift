import AppKit

// Convert the checked-in master artwork into all standard macOS icon sizes.
let destination = CommandLine.arguments.dropFirst().first ?? "Packaging/AppIcon.iconset"
let source = CommandLine.arguments.dropFirst(2).first ?? "Packaging/AppIcon.png"
guard let artwork = NSImage(contentsOfFile: source) else {
    fatalError("Unable to load icon artwork: \(source)")
}
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
func icon(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = graphics
    graphics.imageInterpolation = .high
    artwork.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try icon(size).write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size * 2).write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
