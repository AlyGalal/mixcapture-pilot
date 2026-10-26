#!/usr/bin/env swift
// Generates the app icon with CoreGraphics only: a mint/teal gradient with white waveform bars
// and a dot. No SF Symbols, SVG or bitmap assets. Usage: swift scripts/make-icon.swift [outputDir]
// Writes <outputDir>/GeneratedAssets.xcassets/AppIcon.appiconset (default outputDir: build).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outputRoot = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let catalog = URL(fileURLWithPath: outputRoot).appendingPathComponent("GeneratedAssets.xcassets")
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// Opaque bitmap: App Store icons must not contain transparency.
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not create bitmap context")
}

let colors = [CGColor(red: 0.45, green: 0.93, blue: 0.78, alpha: 1),
              CGColor(red: 0.05, green: 0.52, blue: 0.58, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0),
                       options: [])

// Waveform bars, vertically centered, plus a dot on the right.
let heights: [CGFloat] = [220, 420, 640, 420, 220]
let barWidth: CGFloat = 78
let gap: CGFloat = 52
let dot: CGFloat = 78
let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count) * gap + dot
var x = (CGFloat(size) - total) / 2
let midY = CGFloat(size) / 2
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
for h in heights {
    let rect = CGRect(x: x, y: midY - h / 2, width: barWidth, height: h)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.fillPath()
    x += barWidth + gap
}
ctx.fillEllipse(in: CGRect(x: x, y: midY - dot / 2, width: dot, height: dot))

guard let image = ctx.makeImage() else { fatalError("Could not render icon") }
let pngURL = iconSet.appendingPathComponent("AppIcon-1024.png")
guard let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not create PNG destination")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Could not write PNG") }

let iconContents = """
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try iconContents.write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
""".write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(iconSet.path)")
