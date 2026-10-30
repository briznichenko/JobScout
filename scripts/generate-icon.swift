//
//  generate-icon.swift
//  JobScout
//
//  Created by Andrii Bryzhnychenko on 10/29/26.
//

import AppKit
import Foundation

let root = URL(filePath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let side = CGFloat(pixels)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        let tile = NSBezierPath(roundedRect: NSRect(x: side * 0.07, y: side * 0.07, width: side * 0.86, height: side * 0.86), xRadius: side * 0.20, yRadius: side * 0.20)
        NSGradient(starting: NSColor(calibratedWhite: 0.30, alpha: 1), ending: NSColor(calibratedWhite: 0.10, alpha: 1))!.draw(in: tile, angle: -60)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let handle = NSBezierPath(roundedRect: NSRect(x: side * 0.36, y: side * 0.59, width: side * 0.28, height: side * 0.15), xRadius: side * 0.04, yRadius: side * 0.04)
        handle.lineWidth = side * 0.045
        handle.stroke()
        let briefcase = NSBezierPath(roundedRect: NSRect(x: side * 0.23, y: side * 0.30, width: side * 0.54, height: side * 0.35), xRadius: side * 0.055, yRadius: side * 0.055)
        briefcase.lineWidth = side * 0.045
        briefcase.stroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: side * 0.24, y: side * 0.49))
        divider.line(to: NSPoint(x: side * 0.76, y: side * 0.49))
        divider.lineWidth = side * 0.035
        divider.stroke()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: side * 0.46, y: side * 0.43, width: side * 0.08, height: side * 0.12), xRadius: side * 0.015, yRadius: side * 0.015).fill()
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: root.appending(path: filename))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: root.appending(path: "Contents.json"))
