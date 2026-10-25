import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

public final class ScreenCaptureService: @unchecked Sendable {
    public static let shared = ScreenCaptureService()

    private init() {}

    /// Captures the display containing `targetRect` (or main display if nil) using native ScreenCaptureKit
    /// in-process (excluding OpenComputerUse's own HUD overlay), with fallback to `/usr/sbin/screencapture`.
    public func captureDisplayImage(for targetRect: ScreenRect? = nil) throws -> (image: CGImage, logicalBounds: ScreenRect, scaleFactor: Double) {
        let targetPoint = targetRect?.center ?? PermissionManager.shared.mainScreenBounds().center
        let displayInfo = PermissionManager.shared.displayContaining(point: targetPoint)

        // 1. Try native in-process ScreenCaptureKit capture first
        if let scResult = captureViaScreenCaptureKit(displayID: displayInfo.id, fallbackBounds: displayInfo.bounds, scale: displayInfo.scale) {
            return scResult
        }

        // 2. Fallback to /usr/sbin/screencapture -D <index>
        let allDisplays = PermissionManager.shared.allDisplayBounds()
        let displayIndex = (allDisplays.firstIndex(where: { $0.id == displayInfo.id }) ?? 0) + 1
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocu-raw-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(6)).png")
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-D", "\(displayIndex)", "-t", "png", tempURL.path]

        try? process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tempURL.path),
              let source = CGImageSourceCreateWithURL(tempURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCUError(
                code: .captureFailed,
                message: "Screen capture failed for display \(displayInfo.id).",
                recoveryHint: "Grant Screen Recording permission in System Settings > Privacy & Security > Screen Recording."
            )
        }

        let scale = displayInfo.bounds.width > 0 ? Double(cgImage.width) / displayInfo.bounds.width : displayInfo.scale
        return (cgImage, displayInfo.bounds, scale)
    }

    private func captureViaScreenCaptureKit(
        displayID: CGDirectDisplayID,
        fallbackBounds: ScreenRect,
        scale: Double
    ) -> (image: CGImage, logicalBounds: ScreenRect, scaleFactor: Double)? {
        let semaphore = DispatchSemaphore(value: 0)
        var captured: CGImage? = nil
        var resolvedBounds = fallbackBounds
        var resolvedScale = scale

        Task.detached {
            defer { semaphore.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
                    return
                }
                let displayRect = ScreenRect(scDisplay.frame)
                resolvedBounds = displayRect

                // Exclude OpenComputerUse's own HUD overlay from screenshots
                let excludedApps = content.applications.filter {
                    $0.bundleIdentifier == "org.opencomputeruse.app"
                }
                let filter = SCContentFilter(
                    display: scDisplay,
                    excludingApplications: excludedApps,
                    exceptingWindows: []
                )
                let config = SCStreamConfiguration()
                let pixelW = Int( Double(scDisplay.width) * scale )
                let pixelH = Int( Double(scDisplay.height) * scale )
                config.width = max(scDisplay.width, pixelW)
                config.height = max(scDisplay.height, pixelH)
                config.showsCursor = false

                let img = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                captured = img
                if displayRect.width > 0 {
                    resolvedScale = Double(img.width) / displayRect.width
                }
            } catch {
                return
            }
        }

        _ = semaphore.wait(timeout: .now() + 2.5)
        guard let finalImage = captured else { return nil }
        return (finalImage, resolvedBounds, resolvedScale)
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
