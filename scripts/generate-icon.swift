#!/usr/bin/env swift
// Renders the Morph app icon into the asset catalog. Usage: swift scripts/generate-icon.swift
import AppKit

let output = "Morph/Resources/Assets.xcassets/AppIcon.appiconset"
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    // macOS icon grid: the tile occupies 824/1024 of the canvas.
    let tile = NSRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let body = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(white: 0.13, alpha: 1), NSColor(white: 0.03, alpha: 1)])!.draw(in: body, angle: -90)

    let island = NSRect(x: s * 0.27, y: s * 0.50, width: s * 0.46, height: s * 0.16)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: island, xRadius: island.height / 2, yRadius: island.height / 2).fill()
    NSColor(white: 1, alpha: 0.22).setStroke()
    let outline = NSBezierPath(roundedRect: island, xRadius: island.height / 2, yRadius: island.height / 2)
    outline.lineWidth = max(1, s * 0.004)
    outline.stroke()
    NSColor.white.setFill()
    let dot = s * 0.05
    NSBezierPath(ovalIn: NSRect(x: island.maxX - dot * 1.7, y: island.midY - dot / 2, width: dot, height: dot)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [String] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)@\(scale)x.png"
    try render(points * scale).write(to: URL(fileURLWithPath: "\(output)/\(name)"))
    images.append(#"{ "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#)
}
let contents = "{\n  \"images\" : [\n    \(images.joined(separator: ",\n    "))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(toFile: "\(output)/Contents.json", atomically: true, encoding: .utf8)
