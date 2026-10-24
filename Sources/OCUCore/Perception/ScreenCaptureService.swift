import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public final class ScreenCaptureService: @unchecked Sendable {
    public static let shared = ScreenCaptureService()

    private init() {}

    public func captureMainDisplayImage() throws -> (image: CGImage, logicalBounds: ScreenRect, scaleFactor: Double) {
        let logicalBounds = PermissionManager.shared.mainScreenBounds()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocu-raw-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(6)).png")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x: silent (no shutter sound), -m: main monitor only, -t png
        process.arguments = ["-x", "-m", "-t", "png", tempURL.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw OCUError(
                code: .captureFailed,
                message: "Failed to invoke /usr/sbin/screencapture: \(error.localizedDescription)",
                recoveryHint: "Grant Screen Recording permission in System Settings > Privacy & Security > Screen Recording."
            )
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempURL.path),
              let source = CGImageSourceCreateWithURL(tempURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCUError(
                code: .captureFailed,
                message: "Screen capture produced no image (Screen Recording permission may be missing).",
                recoveryHint: "Open System Settings > Privacy & Security > Screen Recording and enable OpenComputerUse or your terminal."
            )
        }

        let scale = logicalBounds.width > 0 ? Double(cgImage.width) / logicalBounds.width : 2.0
        return (cgImage, logicalBounds, scale)
    }

    public func savePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw OCUError(
                code: .captureFailed,
                message: "Could not create PNG destination at \(path)",
                recoveryHint: "Verify that the output directory is writable."
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OCUError(
                code: .captureFailed,
                message: "Failed to write PNG data to \(path)",
                recoveryHint: "Check disk space and permissions."
            )
        }
    }

    public func encodePNGData(_ image: CGImage, maxDimension: Int = 1728) -> Data? {
        let targetImage: CGImage
        let width = image.width
        let height = image.height
        if max(width, height) > maxDimension {
            let ratio = Double(maxDimension) / Double(max(width, height))
            let newW = max(1, Int(Double(width) * ratio))
            let newH = max(1, Int(Double(height) * ratio))
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(
                data: nil,
                width: newW,
                height: newH,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
                targetImage = ctx.makeImage() ?? image
            } else {
                targetImage = image
            }
        } else {
            targetImage = image
        }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, targetImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return mutableData as Data
    }
}
