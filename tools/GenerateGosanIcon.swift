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

    // The mark: a harp whose frame reads as a "G" for Gosan.
    ctx.setLineCap(.round)
    func deg(_ d: CGFloat) -> CGFloat { d * .pi / 180 }
    let c = CGPoint(x: s * 0.50, y: s * 0.50)
    let R = s * 0.305

    // G bowl — an open gold ring (the harp's curved frame), gap on the right.
    ctx.setStrokeColor(gold)
    ctx.setLineWidth(s * 0.055)
    ctx.beginPath()
    ctx.addArc(center: c, radius: R, startAngle: deg(40), endAngle: deg(320), clockwise: false)
    ctx.strokePath()

    // G crossbar — the defining horizontal stroke, entering from the right.
    ctx.beginPath()
    ctx.move(to: CGPoint(x: c.x + s * 0.015, y: c.y))
    ctx.addLine(to: CGPoint(x: c.x + R * 0.96, y: c.y))
    ctx.strokePath()

    // Harp strings in the lower bowl (equalizer bars), one turquoise accent.
    let baseY = c.y - R * 0.6
    let xs: [CGFloat] = [-0.16, -0.085, -0.01, 0.065, 0.14]
    let hs: [CGFloat] = [0.092, 0.128, 0.159, 0.116, 0.079]
    let accentIndex = 2
    for i in xs.indices {
        let x = c.x + s * xs[i]
        let top = baseY + s * hs[i]
        let col = i == accentIndex ? accent : gold
        ctx.setStrokeColor(col)
        ctx.setLineWidth(s * 0.024)
        ctx.move(to: CGPoint(x: x, y: baseY))
        ctx.addLine(to: CGPoint(x: x, y: top))
        ctx.strokePath()
        ctx.setFillColor(col)
        let r = s * 0.013
        ctx.fillEllipse(in: CGRect(x: x - r, y: top - r, width: r * 2, height: r * 2))
    }

    // Soundboard under the strings.
    ctx.setStrokeColor(gold)
    ctx.setLineWidth(s * 0.034)
    ctx.move(to: CGPoint(x: c.x - s * 0.175, y: baseY))
    ctx.addLine(to: CGPoint(x: c.x + s * 0.155, y: baseY))
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
