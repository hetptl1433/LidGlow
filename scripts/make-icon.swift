import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
  let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 20, dy: 20), xRadius: 220, yRadius: 220)
  NSColor(calibratedRed: 0.065, green: 0.07, blue: 0.085, alpha: 1).setFill()
  shape.fill()
  let border = NSBezierPath(roundedRect: rect.insetBy(dx: 22, dy: 22), xRadius: 218, yRadius: 218)
  border.lineWidth = 4
  NSColor.white.withAlphaComponent(0.14).setStroke()
  border.stroke()
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor(calibratedRed: 1, green: 0.65, blue: 0.27, alpha: 0.65)
  shadow.shadowBlurRadius = 70
  shadow.shadowOffset = .zero
  shadow.set()
  let ring = NSBezierPath(ovalIn: NSRect(x: 244, y: 244, width: 536, height: 536))
  ring.lineWidth = 45
  NSColor(calibratedRed: 1, green: 0.72, blue: 0.4, alpha: 1).setStroke()
  ring.stroke()
  NSGraphicsContext.restoreGraphicsState()
  let center = NSBezierPath(ovalIn: NSRect(x: 425, y: 425, width: 174, height: 174))
  NSColor.white.setFill()
  center.fill()
  return true
}
var rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
let original = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
for pointSize in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let size = pointSize * scale
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.draw(
      original, in: CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let name = "icon_\(pointSize)x\(pointSize)\(suffix).png"
    try bitmap.representation(using: .png, properties: [:])!.write(
      to: destination.appendingPathComponent(name))
  }
}
