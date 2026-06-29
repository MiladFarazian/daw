#!/usr/bin/env swift
// Renders the Gosan app icon at all macOS sizes.
// The mark fuses a Persian harp (chang) with an equalizer: the strings are the
// audio bars. Run: swift tools/GenerateGosanIcon.swift [outputDir]
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// A filled, centered serif "G" glyph path sized to the icon — the harp frame.
func serifG(size s: CGFloat) -> CGPath? {
    let candidates = ["Didot-Bold", "Bodoni 72 Bold", "Georgia-Bold", "TimesNewRomanPS-BoldMT"]
    var font: CTFont?
    for name in candidates {
        let f = CTFontCreateWithName(name as CFString, s * 0.6, nil)
        if (CTFontCopyPostScriptName(f) as String).lowercased().contains(name.prefix(4).lowercased()) {
            font = f; break
        }
    }
    let ctFont = font ?? CTFontCreateWithName("Georgia-Bold" as CFString, s * 0.6, nil)

    var chars: [UniChar] = Array("G".utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    guard CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, chars.count),
          let path = CTFontCreatePathForGlyph(ctFont, glyphs[0], nil) else { return nil }

    let box = path.boundingBoxOfPath
    let scale = (s * 0.66) / box.height
    let tx = (s - box.width * scale) / 2 - box.minX * scale
    let ty = (s - box.height * scale) / 2 - box.minY * scale
    var t = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    return path.copy(using: &t)
}

struct StringLine { let x0, y0, x1, y1: CGFloat; let accent: Bool }

/// Harp strings across the bowl (CoreGraphics y-up coordinates).
func harpStrings(size s: CGFloat) -> [StringLine] {
    let count = 8, accentIndex = 2
    return (0..<count).map { i in
        let t = CGFloat(i) / CGFloat(count - 1)
        return StringLine(x0: s * (0.345 + t * 0.185), y0: s * (0.275 + t * 0.04),
                          x1: s * (0.405 + t * 0.15), y1: s * (0.655 - t * 0.045),
                          accent: i == accentIndex)
    }
}

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

    // The mark: a filled serif "G" letterform (the harp frame) + strings across the bowl.
    if let g = serifG(size: s) {
        ctx.addPath(g)
        ctx.setFillColor(gold)
        ctx.fillPath()
    }

    // Harp strings across the bowl: thin, near-vertical, spanning neck to soundboard.
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.011)
    for str in harpStrings(size: s) {
        ctx.setStrokeColor(str.accent ? accent : gold)
        ctx.move(to: CGPoint(x: str.x0, y: str.y0))
        ctx.addLine(to: CGPoint(x: str.x1, y: str.y1))
        ctx.strokePath()
    }

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

func f1(_ v: CGFloat) -> String { String(format: "%.1f", v) }

/// Convert a CGPath (y-up) to SVG path data (y-down).
func svgPathData(from path: CGPath, flip h: CGFloat) -> String {
    var d = ""
    path.applyWithBlock { ep in
        let e = ep.pointee, p = e.points
        switch e.type {
        case .moveToPoint: d += "M\(f1(p[0].x)) \(f1(h - p[0].y)) "
        case .addLineToPoint: d += "L\(f1(p[0].x)) \(f1(h - p[0].y)) "
        case .addQuadCurveToPoint: d += "Q\(f1(p[0].x)) \(f1(h - p[0].y)) \(f1(p[1].x)) \(f1(h - p[1].y)) "
        case .addCurveToPoint: d += "C\(f1(p[0].x)) \(f1(h - p[0].y)) \(f1(p[1].x)) \(f1(h - p[1].y)) \(f1(p[2].x)) \(f1(h - p[2].y)) "
        case .closeSubpath: d += "Z "
        @unknown default: break
        }
    }
    return d
}

let svgDefs = """
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#162C50"/><stop offset="1" stop-color="#0D4E56"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.30" cy="0.22" r="0.75">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.12"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
  </defs>
"""

/// Write branding SVGs from the same glyph + strings as the PNGs, so they never drift.
func writeBrandingSVGs() {
    let s: CGFloat = 512
    guard let g = serifG(size: s) else { return }
    let gd = svgPathData(from: g, flip: s)
    var strings = ""
    for st in harpStrings(size: s) {
        let color = st.accent ? "#46CDB8" : "#E9B452"
        strings += "      <line x1=\"\(f1(st.x0))\" y1=\"\(f1(s - st.y0))\" x2=\"\(f1(st.x1))\" y2=\"\(f1(s - st.y1))\" stroke=\"\(color)\" stroke-width=\"\(f1(s * 0.011))\"/>\n"
    }

    let icon = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
    \(svgDefs)
      <rect width="512" height="512" rx="114" fill="url(#bg)"/>
      <rect width="512" height="512" rx="114" fill="url(#glow)"/>
      <path d="\(gd)" fill="#E9B452"/>
      <g fill="none" stroke-linecap="round">
    \(strings)  </g>
    </svg>
    """
    try? icon.write(toFile: "branding/gosan-icon.svg", atomically: true, encoding: .utf8)

    let lockup = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 340" width="1200" height="340">
    \(svgDefs)
      <rect width="1200" height="340" rx="44" fill="url(#bg)"/>
      <rect width="1200" height="340" rx="44" fill="url(#glow)"/>
      <g transform="translate(34,30) scale(0.55)">
        <path d="\(gd)" fill="#E9B452"/>
        <g fill="none" stroke-linecap="round">
    \(strings)    </g>
      </g>
      <text x="316" y="178" font-family="Georgia, 'Times New Roman', serif" font-size="132" font-weight="600" fill="#F3E7CF" letter-spacing="2">Gosan</text>
      <text x="320" y="238" font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="30" fill="#E9B452" letter-spacing="3">SONGCRAFT WITH A HUMAN TOUCH</text>
    </svg>
    """
    try? lockup.write(toFile: "branding/gosan-lockup.svg", atomically: true, encoding: .utf8)
    print("wrote branding SVGs")
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

if FileManager.default.fileExists(atPath: "branding") {
    writeBrandingSVGs()
}
