import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 216, yRadius: 216)
        NSColor(calibratedRed: 0.06, green: 0.14, blue: 0.19, alpha: 1).setFill(); background.fill()
        let halo = NSBezierPath(ovalIn: NSRect(x: 160, y: 160, width: 704, height: 704))
        NSColor(calibratedRed: 0.13, green: 0.26, blue: 0.30, alpha: 1).setFill(); halo.fill()
        let ring = NSBezierPath()
        ring.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 277, startAngle: 85, endAngle: 350, clockwise: false)
        ring.lineWidth = 96; ring.lineCapStyle = .round
        NSColor(calibratedRed: 0.23, green: 0.79, blue: 0.67, alpha: 1).setStroke(); ring.stroke()
        let other = NSBezierPath()
        other.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 277, startAngle: 12, endAngle: 56, clockwise: false)
        other.lineWidth = 96; other.lineCapStyle = .round
        NSColor(calibratedRed: 0.45, green: 0.56, blue: 0.91, alpha: 1).setStroke(); other.stroke()
        let disk = NSBezierPath(roundedRect: NSRect(x: 354, y: 377, width: 316, height: 269), xRadius: 46, yRadius: 46)
        NSColor(calibratedWhite: 0.95, alpha: 1).setFill(); disk.fill()
        let line = NSBezierPath(roundedRect: NSRect(x: 396, y: 478, width: 232, height: 26), xRadius: 13, yRadius: 13)
        NSColor(calibratedRed: 0.18, green: 0.36, blue: 0.37, alpha: 1).setFill(); line.fill()
        NSBezierPath(ovalIn: NSRect(x: 571, y: 415, width: 31, height: 31)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
