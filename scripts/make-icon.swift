#!/usr/bin/env swift
import AppKit

let destination = CommandLine.arguments.dropFirst().first ?? "App/Assets.xcassets/AppIcon.appiconset"
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
let variants: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
var images: [[String: String]] = []
for (points, scale) in variants {
    let pixels = points * scale
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 202, yRadius: 202).fill()
    NSColor(calibratedWhite: 0.20, alpha: 1).setStroke()
    let outline = NSBezierPath(roundedRect: NSRect(x: 54, y: 54, width: 916, height: 916), xRadius: 200, yRadius: 200)
    outline.lineWidth = 5; outline.stroke()
    let tray = NSBezierPath()
    tray.move(to: NSPoint(x: 253, y: 613)); tray.line(to: NSPoint(x: 322, y: 730))
    tray.line(to: NSPoint(x: 702, y: 730)); tray.line(to: NSPoint(x: 771, y: 613))
    tray.line(to: NSPoint(x: 771, y: 353)); tray.curve(to: NSPoint(x: 728, y: 310), controlPoint1: NSPoint(x: 771, y: 326), controlPoint2: NSPoint(x: 755, y: 310))
    tray.line(to: NSPoint(x: 296, y: 310)); tray.curve(to: NSPoint(x: 253, y: 353), controlPoint1: NSPoint(x: 269, y: 310), controlPoint2: NSPoint(x: 253, y: 326)); tray.close()
    NSColor(calibratedWhite: 0.15, alpha: 1).setFill(); tray.fill()
    NSColor(calibratedWhite: 0.81, alpha: 1).setStroke(); tray.lineWidth = 30; tray.lineJoinStyle = .round; tray.stroke()
    let lip = NSBezierPath()
    lip.move(to: NSPoint(x: 253, y: 534)); lip.line(to: NSPoint(x: 405, y: 534))
    lip.curve(to: NSPoint(x: 454, y: 463), controlPoint1: NSPoint(x: 418, y: 487), controlPoint2: NSPoint(x: 427, y: 463))
    lip.line(to: NSPoint(x: 570, y: 463)); lip.curve(to: NSPoint(x: 619, y: 534), controlPoint1: NSPoint(x: 597, y: 463), controlPoint2: NSPoint(x: 606, y: 487))
    lip.line(to: NSPoint(x: 771, y: 534)); lip.lineWidth = 30; lip.lineJoinStyle = .round; lip.stroke()
    NSColor(calibratedRed: 0.49, green: 0.70, blue: 0.56, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 715, y: 722, width: 94, height: 94)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let filename = "icon_\(points)x\(points)@\(scale)x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(filename))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
}
let manifest: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: destination).appendingPathComponent("Contents.json"))
