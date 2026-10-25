import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

public final class ScreenCaptureService: @unchecked Sendable {
    public static let shared = ScreenCaptureService()

    private init() {}

    /// Captures the target application window (when `windowOnly` is true and `pid`/`targetRect` are known)
    /// or the display containing `targetRect` using native ScreenCaptureKit in-process.
    public func captureDisplayImage(
        for targetRect: ScreenRect? = nil,
        pid: Int32? = nil,
        windowOnly: Bool = true
    ) throws -> (image: CGImage, logicalBounds: ScreenRect, scaleFactor: Double) {
        let targetPoint = targetRect?.center ?? PermissionManager.shared.mainScreenBounds().center
        let displayInfo = PermissionManager.shared.displayContaining(point: targetPoint)

        // 1. Try native in-process ScreenCaptureKit capture first (window-cropped if windowOnly == true)
        if let scResult = captureViaScreenCaptureKit(
            displayID: displayInfo.id,
            targetRect: targetRect,
            pid: pid,
            windowOnly: windowOnly,
            fallbackBounds: displayInfo.bounds,
            scale: displayInfo.scale
        ) {
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
        if windowOnly, let cropRect = targetRect,
           let cropped = cropImage(cgImage, to: cropRect, displayBounds: displayInfo.bounds, scale: scale) {
            return (cropped, cropRect, scale)
        }
        return (cgImage, displayInfo.bounds, scale)
    }

    private func captureViaScreenCaptureKit(
        displayID: CGDirectDisplayID,
        targetRect: ScreenRect?,
        pid: Int32?,
        windowOnly: Bool,
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
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

                // Fast path: capture only the target application's window when windowOnly is enabled
                if windowOnly, let targetPid = pid, targetPid > 0 {
                    let appWindows = content.windows.filter { win in
                        win.owningApplication?.processID == targetPid &&
                        win.windowLayer == 0 &&
                        win.frame.width >= 120 &&
                        win.frame.height >= 120
                    }
                    let onScreenPool = appWindows.filter(\.isOnScreen)
                    let candidatePool = onScreenPool.isEmpty ? appWindows : onScreenPool
                    let matchedWindow: SCWindow? = {
                        if let tr = targetRect {
                            return candidatePool.max(by: { a, b in
                                ScreenRect(a.frame).intersectionArea(with: tr) < ScreenRect(b.frame).intersectionArea(with: tr)
                            })
                        }
                        return candidatePool.max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) })
                    }()

                    if let scWin = matchedWindow {
                        let winRect = ScreenRect(scWin.frame)
                        let winFilter = SCContentFilter(desktopIndependentWindow: scWin)
                        let winConfig = SCStreamConfiguration()
                        let pw = max(Int(winRect.width), Int((winRect.width * scale).rounded()))
                        let ph = max(Int(winRect.height), Int((winRect.height * scale).rounded()))
                        winConfig.width = pw
                        winConfig.height = ph
                        winConfig.showsCursor = false
                        if let winImg = try? await SCScreenshotManager.captureImage(
                            contentFilter: winFilter,
                            configuration: winConfig
                        ) {
                            captured = winImg
                            resolvedBounds = winRect
                            resolvedScale = winRect.width > 0 ? Double(winImg.width) / winRect.width : scale
                            return
                        }
                    }
                }

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
                let pixelW = Int(Double(scDisplay.width) * scale)
                let pixelH = Int(Double(scDisplay.height) * scale)
                config.width = max(scDisplay.width, pixelW)
                config.height = max(scDisplay.height, pixelH)
                config.showsCursor = false

                let img = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: config
                )
                let actualScale = displayRect.width > 0 ? Double(img.width) / displayRect.width : scale
                if windowOnly, let cropRect = targetRect,
                   let cropped = self.cropImage(img, to: cropRect, displayBounds: displayRect, scale: actualScale) {
                    captured = cropped
                    resolvedBounds = cropRect
                    resolvedScale = actualScale
                } else {
                    captured = img
                    resolvedBounds = displayRect
                    resolvedScale = actualScale
                }
            } catch {
                return
            }
        }

        _ = semaphore.wait(timeout: .now() + 2.5)
        guard let finalImage = captured else { return nil }
        return (finalImage, resolvedBounds, resolvedScale)
    }

    private func cropImage(
        _ image: CGImage,
        to targetRect: ScreenRect,
        displayBounds: ScreenRect,
        scale: Double
    ) -> CGImage? {
        let localX = max(0, (targetRect.x - displayBounds.x) * scale)
        let localY = max(0, (targetRect.y - displayBounds.y) * scale)
        let cropW = min(Double(image.width) - localX, targetRect.width * scale)
        let cropH = min(Double(image.height) - localY, targetRect.height * scale)
        guard cropW >= 40, cropH >= 40 else { return nil }
        return image.cropping(to: CGRect(x: localX, y: localY, width: cropW, height: cropH))
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
