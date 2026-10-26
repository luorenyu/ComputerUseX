#!/usr/bin/env swift
import Foundation
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let outputIcnsPath = args.count > 1 ? args[1] : "AppIcon.icns"

func renderIconImage(pixelSize: Int) -> NSImage {
    let s = CGFloat(pixelSize)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // 1. macOS squircle padding (~9.5% inset)
    let pad = s * 0.085
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let cornerRadius = rect.width * 0.225
    let squirclePath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // 2. Deep Obsidian base gradient (#0D0F15 -> #181B26)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1.0),
        CGColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1.0)
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // 3. Ambient Gemini Aurora Orbs (Top-left Blue, Bottom-right Violet/Coral)
    let blueOrbColors = [
        CGColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 0.52),
        CGColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 0.0)
    ] as CFArray
    if let blueOrb = CGGradient(colorsSpace: colorSpace, colors: blueOrbColors, locations: [0.0, 1.0]) {
        let c1 = CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.74)
        ctx.drawRadialGradient(blueOrb, startCenter: c1, startRadius: 0, endCenter: c1, endRadius: rect.width * 0.65, options: [])
    }

    let coralOrbColors = [
        CGColor(red: 0.61, green: 0.45, blue: 0.80, alpha: 0.48),
        CGColor(red: 0.85, green: 0.40, blue: 0.44, alpha: 0.25),
        CGColor(red: 0.85, green: 0.40, blue: 0.44, alpha: 0.0)
    ] as CFArray
    if let coralOrb = CGGradient(colorsSpace: colorSpace, colors: coralOrbColors, locations: [0.0, 0.55, 1.0]) {
        let c2 = CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.26)
        ctx.drawRadialGradient(coralOrb, startCenter: c2, startRadius: 0, endCenter: c2, endRadius: rect.width * 0.68, options: [])
    }

    // 4. Companion Gemini 4-point Sparkle Stars (Upper-Right & Upper-Middle)
    let auroraColors = [
        CGColor(red: 0.40, green: 0.72, blue: 1.00, alpha: 1.0),
        CGColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1.0),
        CGColor(red: 0.61, green: 0.45, blue: 0.80, alpha: 1.0),
        CGColor(red: 0.85, green: 0.40, blue: 0.44, alpha: 1.0)
    ] as CFArray

    func drawSparkleStar(center: CGPoint, radius: CGFloat, fillWhite: Bool = false) {
        let curvature = radius * 0.20
        let starPath = CGMutablePath()
        let topPt = CGPoint(x: center.x, y: center.y + radius)
        let rightPt = CGPoint(x: center.x + radius, y: center.y)
        let bottomPt = CGPoint(x: center.x, y: center.y - radius)
        let leftPt = CGPoint(x: center.x - radius, y: center.y)

        starPath.move(to: topPt)
        starPath.addQuadCurve(to: rightPt, control: CGPoint(x: center.x + curvature, y: center.y + curvature))
        starPath.addQuadCurve(to: bottomPt, control: CGPoint(x: center.x + curvature, y: center.y - curvature))
        starPath.addQuadCurve(to: leftPt, control: CGPoint(x: center.x - curvature, y: center.y - curvature))
        starPath.addQuadCurve(to: topPt, control: CGPoint(x: center.x - curvature, y: center.y + curvature))
        starPath.closeSubpath()

        ctx.saveGState()
        ctx.addPath(starPath)
        if fillWhite {
            ctx.setFillColor(CGColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 0.95))
            ctx.fillPath()
        } else {
            ctx.clip()
            if let auroraGrad = CGGradient(colorsSpace: colorSpace, colors: auroraColors, locations: [0.0, 0.35, 0.70, 1.0]) {
                ctx.drawLinearGradient(
                    auroraGrad,
                    start: CGPoint(x: center.x - radius, y: center.y + radius),
                    end: CGPoint(x: center.x + radius, y: center.y - radius),
                    options: []
                )
            }
        }
        ctx.restoreGState()
    }

    // 4. Tapered Comet Tail Arc Ribbon (from cursor notch to bottom-right)
    let arcPath = CGMutablePath()
    arcPath.move(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.48))
    arcPath.addQuadCurve(
        to: CGPoint(x: rect.minX + rect.width * 0.90, y: rect.minY + rect.height * 0.15),
        control: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.minY + rect.height * 0.26)
    )
    arcPath.addQuadCurve(
        to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.44),
        control: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY + rect.height * 0.20)
    )
    arcPath.closeSubpath()

    ctx.saveGState()
    ctx.addPath(arcPath)
    ctx.clip()
    if let auroraGrad = CGGradient(colorsSpace: colorSpace, colors: auroraColors, locations: [0.0, 0.35, 0.70, 1.0]) {
        ctx.drawLinearGradient(
            auroraGrad,
            start: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.48),
            end: CGPoint(x: rect.minX + rect.width * 0.90, y: rect.minY + rect.height * 0.15),
            options: []
        )
    }
    ctx.restoreGState()

    // 5. Sparkles along the Top-Left -> Bottom-Right Comet Arc (Largest in front of tip, tapering smaller behind)
    // Sparkle #1 (LARGEST — In front of Cursor Tip at Top-Left)
    drawSparkleStar(
        center: CGPoint(x: rect.minX + rect.width * 0.17, y: rect.minY + rect.height * 0.83),
        radius: rect.width * 0.135
    )
    // Sparkle #2 (MEDIUM — First trailing star on the comet arc behind cursor)
    drawSparkleStar(
        center: CGPoint(x: rect.minX + rect.width * 0.565, y: rect.minY + rect.height * 0.325),
        radius: rect.width * 0.105
    )
    // Sparkle #3 (SMALL — Second trailing star along the comet arc)
    drawSparkleStar(
        center: CGPoint(x: rect.minX + rect.width * 0.735, y: rect.minY + rect.height * 0.22),
        radius: rect.width * 0.078
    )
    // Sparkle #4 (TINY — Tail-end star at Bottom-Right of the comet arc)
    drawSparkleStar(
        center: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.155),
        radius: rect.width * 0.052,
        fillWhite: true
    )

    // 6. Slender 2:3 Tailless Gemini Cyber-Blade Cursor
    let tip = CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.75)
    let wingLeft = CGPoint(x: rect.minX + rect.width * 0.29, y: rect.minY + rect.height * 0.31)
    let notch = CGPoint(x: rect.minX + rect.width * 0.395, y: rect.minY + rect.height * 0.475)
    let wingRight = CGPoint(x: rect.minX + rect.width * 0.555, y: rect.minY + rect.height * 0.525)

    let pointerPath = CGMutablePath()
    pointerPath.move(to: tip)
    pointerPath.addLine(to: wingLeft)
    pointerPath.addLine(to: notch)
    pointerPath.addLine(to: wingRight)
    pointerPath.closeSubpath()

    // Pointer drop shadow & aurora glow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.018), blur: s * 0.055, color: CGColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 0.75))
    ctx.addPath(pointerPath)
    ctx.setFillColor(CGColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Pointer Aurora Fill
    ctx.saveGState()
    ctx.addPath(pointerPath)
    ctx.clip()
    if let auroraGrad = CGGradient(colorsSpace: colorSpace, colors: auroraColors, locations: [0.0, 0.35, 0.70, 1.0]) {
        ctx.drawLinearGradient(
            auroraGrad,
            start: tip,
            end: CGPoint(x: wingRight.x, y: wingLeft.y),
            options: []
        )
    }
    ctx.restoreGState()

    // Pointer Pearlescent White Rim
    ctx.saveGState()
    ctx.addPath(pointerPath)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.92))
    ctx.setLineWidth(max(1.2, s * 0.016))
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // 6. Outer Squircle Aurora Rim Border
    ctx.addPath(squirclePath)
    ctx.setStrokeColor(CGColor(red: 0.52, green: 0.68, blue: 0.98, alpha: 0.38))
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.strokePath()

    ctx.restoreGState()
    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try png.write(to: url)
}

let tempIconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: tempIconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempIconset) }

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for item in sizes {
    let img = renderIconImage(pixelSize: item.pixels)
    try savePNG(img, to: tempIconset.appendingPathComponent(item.name), pixelSize: item.pixels)
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", tempIconset.path, "-o", outputIcnsPath]
try proc.run()
proc.waitUntilExit()

if proc.terminationStatus != 0 {
    fputs("Failed to generate .icns via iconutil\n", stderr)
    exit(1)
}
