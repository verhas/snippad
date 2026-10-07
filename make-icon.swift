#!/usr/bin/env swift
//
// Draws Snippad's app icon straight into the asset catalog at
// Snippad/Assets.xcassets/AppIcon.appiconset. Run with:  swift make-icon.swift
//
// The mark is a clipboard: what a click on a snippet fills. It has to survive
// being shrunk to 16pt, so the board and the clip are large blocks and the
// only fine detail (the ruled lines) is allowed to disappear.

import AppKit
import Foundation

let tealTop    = NSColor(srgbRed: 0.10, green: 0.50, blue: 0.55, alpha: 1)
let tealBottom = NSColor(srgbRed: 0.05, green: 0.32, blue: 0.38, alpha: 1)
let board      = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1)
let clip       = NSColor(srgbRed: 0.98, green: 0.72, blue: 0.28, alpha: 1)
let rule       = NSColor(srgbRed: 0.55, green: 0.60, blue: 0.64, alpha: 1)

func icon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons do not fill their canvas; they sit on a rounded square with
    // padding around it, which is what makes them line up in the Dock.
    let inset = s * 0.085
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bodyPath = NSBezierPath(roundedRect: body,
                                xRadius: body.width * 0.2237,
                                yRadius: body.height * 0.2237)
    NSGradient(starting: tealTop, ending: tealBottom)!.draw(in: bodyPath, angle: -90)

    // The board.
    let boardW = body.width * 0.56
    let boardH = body.height * 0.66
    let paper = NSRect(x: body.midX - boardW / 2, y: body.minY + body.height * 0.12,
                       width: boardW, height: boardH)
    board.setFill()
    NSBezierPath(roundedRect: paper, xRadius: boardW * 0.08, yRadius: boardW * 0.08).fill()

    // Ruled lines standing in for a snippet. Skipped where they would be mud.
    if size >= 64 {
        let lineH = max(1, boardH * 0.045)
        rule.withAlphaComponent(0.6).setFill()
        for row in 0..<4 {
            let y = paper.maxY - boardH * 0.32 - CGFloat(row) * boardH * 0.15
            let width = paper.width * (row == 3 ? 0.40 : 0.66)
            NSBezierPath(roundedRect: NSRect(x: paper.minX + paper.width * 0.17,
                                             y: y, width: width, height: lineH),
                         xRadius: lineH / 2, yRadius: lineH / 2).fill()
        }
    }

    // The clip, straddling the top edge of the board.
    let clipW = boardW * 0.46
    let clipH = boardH * 0.17
    let clipRect = NSRect(x: body.midX - clipW / 2, y: paper.maxY - clipH * 0.55,
                          width: clipW, height: clipH)
    clip.setFill()
    NSBezierPath(roundedRect: clipRect, xRadius: clipH * 0.3, yRadius: clipH * 0.3).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let catalog = URL(fileURLWithPath: "Snippad/Assets.xcassets")
let iconset = catalog.appendingPathComponent("AppIcon.appiconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

try #"{"info":{"author":"xcode","version":1}}"#
    .write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16),    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),    ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

var entries: [String] = []
for variant in variants {
    let rep = icon(size: variant.px)
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))

    // "icon_32x32@2x" -> point size 32, scale 2x.
    let scale = variant.name.hasSuffix("@2x") ? "2x" : "1x"
    let points = variant.px / (scale == "2x" ? 2 : 1)
    entries.append("""
        {"idiom":"mac","scale":"\(scale)","size":"\(points)x\(points)","filename":"\(variant.name).png"}
    """)
}

let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {"author":"xcode","version":1}
}
"""
try contents.write(to: iconset.appendingPathComponent("Contents.json"),
                   atomically: true, encoding: .utf8)

print("wrote \(variants.count) images to \(iconset.path)")
