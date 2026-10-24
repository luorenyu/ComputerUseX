import Foundation
import AppKit
import CoreGraphics

public final class SoMAnnotator: @unchecked Sendable {
    public static let shared = SoMAnnotator()

    private init() {}

    /// Renders Set-of-Marks (SoM) bounding boxes, `@eX` reference tags, and coordinate rulers onto the screenshot.
    public func annotateImage(
        _ baseImage: CGImage,
        elements: [UIElementRef],
        scaleFactor: Double
    ) -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Draw original screenshot at full resolution
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        NSGraphicsContext.saveGraphicsState()
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.current = nsCtx

        // 1. Draw subtle coordinate ruler ticks along top and left edges (every 200 logical pts)
        drawCoordinateRuler(in: ctx, pixelWidth: width, pixelHeight: height, scaleFactor: scaleFactor)

        // 2. Draw bounding boxes and @eX badges for elements
        let fontSize = CGFloat(max(11.0, 11.0 * scaleFactor))
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)

        for element in elements.prefix(160) {
            let px = CGFloat(element.frame.x * scaleFactor)
            let py = CGFloat(Double(height) - (element.frame.y + element.frame.height) * scaleFactor)
            let pw = CGFloat(element.frame.width * scaleFactor)
            let ph = CGFloat(element.frame.height * scaleFactor)
            let boxRect = CGRect(x: px, y: py, width: pw, height: ph)

            // Color coding: Cyan/Blue for AX native elements, Emerald/Green for Vision OCR elements
            let strokeColor: NSColor = (element.source == .ax)
                ? NSColor(calibratedRed: 0.05, green: 0.58, blue: 0.98, alpha: 0.92)
                : NSColor(calibratedRed: 0.08, green: 0.78, blue: 0.45, alpha: 0.90)

            let fillColor: NSColor = (element.source == .ax)
                ? NSColor(calibratedRed: 0.04, green: 0.38, blue: 0.82, alpha: 0.94)
                : NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.32, alpha: 0.94)

            ctx.saveGState()
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(CGFloat(max(1.5, 1.5 * scaleFactor)))
            ctx.stroke(boxRect)

            // Draw @eX tag badge at top-left of the bounding box
            let tagText = element.ref as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]
            let textSize = tagText.size(withAttributes: attrs)
            let padX = CGFloat(4.0 * scaleFactor)
            let padY = CGFloat(2.0 * scaleFactor)
            let badgeW = textSize.width + padX * 2
            let badgeH = textSize.height + padY * 2

            let badgeX = max(0, min(CGFloat(width) - badgeW, boxRect.minX))
            let badgeY = min(CGFloat(height) - badgeH, max(0, boxRect.maxY - badgeH))
            let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)

            let badgePath = CGPath(
                roundedRect: badgeRect,
                cornerWidth: CGFloat(3.0 * scaleFactor),
                cornerHeight: CGFloat(3.0 * scaleFactor),
                transform: nil
            )
            ctx.addPath(badgePath)
            ctx.setFillColor(fillColor.cgColor)
            ctx.fillPath()

            tagText.draw(
                at: NSPoint(x: badgeX + padX, y: badgeY + padY),
                withAttributes: attrs
            )
            ctx.restoreGState()
        }

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private func drawCoordinateRuler(
        in ctx: CGContext,
        pixelWidth: Int,
        pixelHeight: Int,
        scaleFactor: Double
    ) {
        let logicalWidth = Int(Double(pixelWidth) / scaleFactor)
        let logicalHeight = Int(Double(pixelHeight) / scaleFactor)
        let rulerFont = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(10.0 * scaleFactor), weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: rulerFont,
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.9)
        ]

        // Top horizontal bar
        let barThickness = CGFloat(18.0 * scaleFactor)
        ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.65).cgColor)
        ctx.fill(CGRect(x: 0, y: CGFloat(pixelHeight) - barThickness, width: CGFloat(pixelWidth), height: barThickness))

        for xPt in stride(from: 200, to: logicalWidth, by: 200) {
            let px = CGFloat(Double(xPt) * scaleFactor)
            ctx.setStrokeColor(NSColor(calibratedWhite: 0.85, alpha: 0.7).cgColor)
            ctx.setLineWidth(CGFloat(1.0 * scaleFactor))
            ctx.move(to: CGPoint(x: px, y: CGFloat(pixelHeight)))
            ctx.addLine(to: CGPoint(x: px, y: CGFloat(pixelHeight) - barThickness))
            ctx.strokePath()
            let label = "x:\(xPt)" as NSString
            label.draw(at: NSPoint(x: px + 4, y: CGFloat(pixelHeight) - barThickness + 2), withAttributes: attrs)
        }

        for yPt in stride(from: 200, to: logicalHeight, by: 200) {
            let py = CGFloat(Double(pixelHeight) - Double(yPt) * scaleFactor)
            let label = "y:\(yPt)" as NSString
            let size = label.size(withAttributes: attrs)
            let pillRect = CGRect(x: 2, y: py - size.height / 2 - 2, width: size.width + 8, height: size.height + 4)
            ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 0.65).cgColor)
            ctx.fill(pillRect)
            label.draw(at: NSPoint(x: 6, y: py - size.height / 2), withAttributes: attrs)
        }
    }
}
