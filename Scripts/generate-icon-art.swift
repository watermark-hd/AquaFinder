#!/usr/bin/env swift
// Renders AquaFinder's app icon (an original glossy blue rounded-square
// + magnifying glass design — deliberately not a recreation of Apple's
// trademarked Finder face) into every PNG size iconutil expects, directly
// into Resources/AquaFinder.iconset. Re-run any time the design changes;
// Scripts/make-icon.sh then converts the .iconset into AppIcon.icns.
//
// Usage: swift Scripts/generate-icon-art.swift Resources/AquaFinder.iconset

import AppKit

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: generate-icon-art.swift <output .iconset directory>\n".data(using: .utf8)!)
    exit(1)
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(pixels: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

func draw(pixels: CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    let inset = pixels * 0.06
    let bodyRect = rect.insetBy(dx: inset, dy: inset)
    let radius = bodyRect.width * 0.22

    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.46, green: 0.75, blue: 0.99, alpha: 1.0),
        NSColor(calibratedRed: 0.10, green: 0.38, blue: 0.86, alpha: 1.0),
    ])
    gradient?.draw(in: bodyPath, angle: -90)

    // Soft drop shadow under the whole shape, drawn before the glossy
    // highlight so it stays underneath.
    NSColor.black.withAlphaComponent(0.18).setStroke()
    let outline = NSBezierPath(roundedRect: bodyRect, xRadius: radius, yRadius: radius)
    outline.lineWidth = pixels * 0.004
    outline.stroke()

    // Glossy top highlight, classic Aqua-era look.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    let highlightRect = NSRect(x: bodyRect.minX, y: bodyRect.midY, width: bodyRect.width, height: bodyRect.height * 0.55)
    let highlightGradient = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.35),
        NSColor.white.withAlphaComponent(0.0),
    ])
    highlightGradient?.draw(in: highlightRect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Magnifying glass — a simple, unambiguous "browse/search" symbol
    // that doesn't lean on Apple's specific Finder-face character design.
    let glassDiameter = bodyRect.width * 0.44
    let glassCenter = NSPoint(x: bodyRect.midX - bodyRect.width * 0.07, y: bodyRect.midY + bodyRect.height * 0.07)
    let glassRect = NSRect(
        x: glassCenter.x - glassDiameter / 2, y: glassCenter.y - glassDiameter / 2,
        width: glassDiameter, height: glassDiameter
    )

    let lineWidth = pixels * 0.055
    NSColor.black.withAlphaComponent(0.15).setFill()
    NSBezierPath(ovalIn: glassRect.insetBy(dx: -pixels * 0.01, dy: -pixels * 0.01)).fill()

    let ringPath = NSBezierPath(ovalIn: glassRect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
    ringPath.lineWidth = lineWidth
    NSColor.white.setStroke()
    ringPath.stroke()

    let handleStart = NSPoint(
        x: glassCenter.x + glassDiameter / 2 * 0.70,
        y: glassCenter.y - glassDiameter / 2 * 0.70
    )
    let handleEnd = NSPoint(
        x: handleStart.x + glassDiameter * 0.40,
        y: handleStart.y - glassDiameter * 0.40
    )
    let handlePath = NSBezierPath()
    handlePath.move(to: handleStart)
    handlePath.line(to: handleEnd)
    handlePath.lineWidth = lineWidth * 1.2
    handlePath.lineCapStyle = .round
    NSColor.white.setStroke()
    handlePath.stroke()
}

for (name, pixels) in sizes {
    let data = renderPNG(pixels: pixels)
    let url = outputDir.appendingPathComponent("\(name).png")
    try! data.write(to: url)
    print("wrote \(url.lastPathComponent) (\(pixels)x\(pixels))")
}
