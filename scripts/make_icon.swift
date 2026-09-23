import AppKit
let s = 1024.0
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let colors = [NSColor(red: 0.10, green: 0.09, blue: 0.20, alpha: 1).cgColor, NSColor(red: 0.03, green: 0.03, blue: 0.07, alpha: 1).cgColor] as CFArray
let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
// Three tiles: tables (violet), dashboards (orange), code (coral)
let tiles: [(CGRect, NSColor)] = [
  (CGRect(x: 200, y: 530, width: 294, height: 294), NSColor(red: 0.49, green: 0.44, blue: 0.97, alpha: 1)),
  (CGRect(x: 530, y: 530, width: 294, height: 294), NSColor(red: 0.96, green: 0.52, blue: 0.10, alpha: 1)),
  (CGRect(x: 200, y: 200, width: 294, height: 294), NSColor(red: 0.99, green: 0.43, blue: 0.15, alpha: 1)),
  (CGRect(x: 530, y: 200, width: 294, height: 294), NSColor(red: 0.36, green: 0.80, blue: 0.72, alpha: 1)),
]
for (r, c) in tiles {
  c.setFill()
  NSBezierPath(roundedRect: r, xRadius: 70, yRadius: 70).fill()
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
