#!/usr/bin/env swift
// Renders the Gosan app icon at all macOS sizes.
// The mark fuses a Persian harp (chang) with an equalizer: the strings are the
// audio bars. Run: swift tools/GenerateGosanIcon.swift [outputDir]
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Persian-inspired palette: lapis night, deep turquoise, saffron gold, accent teal.
let bgTop = rgb(22, 44, 80)
let bgBottom = rgb(13, 78, 86)
let gold = rgb(233, 180, 82)
let accent = rgb(70, 205, 184)

func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let radius = s * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let space = CGColorSpaceCreateDeviceRGB()

    // Background gradient
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    if let grad = CGGradient(colorsSpace: space, colors: [bgTop, bgBottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    }
    // Soft top-left glow
    if let glow = CGGradient(colorsSpace: space,
                             colors: [rgb(255, 255, 255, 0.12), rgb(255, 255, 255, 0)] as CFArray,
                             locations: [0, 1]) {
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: s * 0.30, y: s * 0.78), startRadius: 0,
                               endCenter: CGPoint(x: s * 0.30, y: s * 0.78), endRadius: s * 0.75,
                               options: [])
    }

    // The harp / equalizer mark
    let baseY = s * 0.30
    let xs: [CGFloat] = [0.355, 0.425, 0.495, 0.565, 0.635]
    let hs: [CGFloat] = [0.18, 0.30, 0.36, 0.28, 0.20]
    let accentIndex = 2

    ctx.setLineCap(.round)
    for i in xs.indices {
        let x = s * xs[i]
        let top = baseY + s * hs[i]
        let color = i == accentIndex ? accent : gold
        ctx.setStrokeColor(color)
        ctx.setLineWidth(s * 0.028)
        ctx.move(to: CGPoint(x: x, y: baseY))
        ctx.addLine(to: CGPoint(x: x, y: top))
        ctx.strokePath()
        ctx.setFillColor(color)
        let r = s * 0.014
        ctx.fillEllipse(in: CGRect(x: x - r, y: top - r, width: r * 2, height: r * 2))
    }

    // Harp neck (curved frame sweeping over the strings)
    ctx.setStrokeColor(gold)
    ctx.setLineWidth(s * 0.05)
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: s * 0.30, y: baseY))
    neck.addCurve(to: CGPoint(x: s * 0.70, y: baseY + s * 0.16),
                  control1: CGPoint(x: s * 0.34, y: s * 0.86),
                  control2: CGPoint(x: s * 0.74, y: s * 0.66))
    ctx.addPath(neck); ctx.strokePath()

    // Soundboard foot
    ctx.move(to: CGPoint(x: s * 0.30, y: baseY))
    ctx.addLine(to: CGPoint(x: s * 0.70, y: baseY))
    ctx.strokePath()

    ctx.restoreGState()
}

func makeImage(size: Int) -> CGImage? {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    drawIcon(ctx, CGFloat(size))
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Gosan/Assets.xcassets/AppIcon.appiconset"
let outURL = URL(fileURLWithPath: outputDir)
try? FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

// (filename, pixel size) for the macOS icon set.
let targets: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

for (name, size) in targets {
    if let image = makeImage(size: size) {
        writePNG(image, to: outURL.appendingPathComponent(name))
        print("wrote \(name) (\(size)px)")
    }
}
