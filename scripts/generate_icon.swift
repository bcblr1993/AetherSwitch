// Run by concatenating BrandGlyph.swift with this source, preserving shared geometry.
import AppKit
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext
context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 186, yRadius: 186)
NSColor(srgbRed: 0.035, green: 0.075, blue: 0.15, alpha: 1).setFill(); plate.fill()
let gradient = NSGradient(starting: NSColor(srgbRed: 0.09, green: 0.20, blue: 0.34, alpha: 1), ending: NSColor(srgbRed: 0.025, green: 0.05, blue: 0.10, alpha: 1))!
gradient.draw(in: plate, angle: 90)
BrandGlyph.draw(in: NSRect(x: 240, y: 205, width: 544, height: 614),
    color: NSColor(srgbRed: 0.07, green: 0.78, blue: 0.97, alpha: 1),
    secondary: NSColor(srgbRed: 0.25, green: 0.94, blue: 0.72, alpha: 1), knobColor: .white)
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
