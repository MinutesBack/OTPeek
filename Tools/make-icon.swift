#!/usr/bin/env swift
// Renders OTPeek.iconset. Usage: swift Tools/make-icon.swift <output-iconset-dir>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <iconset dir>\n".utf8))
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// One icon at a given pixel size: a rounded indigo tile with a key on it.
func renderIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let tile = NSBezierPath(roundedRect: rect,
                            xRadius: size * 0.22, yRadius: size * 0.22)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.22, green: 0.24, blue: 0.62, alpha: 1),
    ])
    gradient?.draw(in: tile, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.44, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "key.horizontal.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
        symbol.draw(at: .zero, from: NSRect(origin: .zero, size: symbol.size),
                    operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()

        let target = NSRect(x: (size - symbol.size.width) / 2,
                            y: (size - symbol.size.height) / 2,
                            width: symbol.size.width, height: symbol.size.height)
        tinted.draw(in: target)
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)
    return bitmap.representation(using: .png, properties: [:])
}

// The set of sizes iconutil expects.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let data = renderIcon(pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}
print("wrote \(variants.count) icon sizes to \(outputDirectory.path)")
