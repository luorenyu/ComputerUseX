import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

public final class PermissionManager: @unchecked Sendable {
    public static let shared = PermissionManager()

    private init() {}

    public func isAccessibilityGranted(prompt: Bool = false) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    public func isScreenRecordingGranted(prompt: Bool = false) -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted && prompt {
            return CGRequestScreenCaptureAccess()
        }
        return granted
    }

    public func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public func mainScreenBounds() -> ScreenRect {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        return ScreenRect(bounds)
    }

    /// Returns the bounds of all active displays in global top-left CGDisplay coordinates.
    public func allDisplayBounds() -> [(id: CGDirectDisplayID, bounds: ScreenRect, scale: Double)] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else {
            return [(CGMainDisplayID(), mainScreenBounds(), mainScreenScaleFactor())]
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        return displays.map { id in
            let rect = ScreenRect(CGDisplayBounds(id))
            var scale = 2.0
            if let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 {
                scale = Double(mode.pixelWidth) / Double(mode.width)
            }
            return (id, rect, scale)
        }
    }

    /// Union bounding rectangle across all connected displays.
    public func desktopBounds() -> ScreenRect {
        let displays = allDisplayBounds().map(\.bounds)
        guard let first = displays.first else {
            return mainScreenBounds()
        }
        var minX = first.x
        var minY = first.y
        var maxX = first.maxX
        var maxY = first.maxY
        for d in displays.dropFirst() {
            minX = min(minX, d.x)
            minY = min(minY, d.y)
            maxX = max(maxX, d.maxX)
            maxY = max(maxY, d.maxY)
        }
        return ScreenRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Finds the display containing the given point (or closest to it).
    public func displayContaining(point: ScreenPoint) -> (id: CGDirectDisplayID, bounds: ScreenRect, scale: Double) {
        let all = allDisplayBounds()
        if let match = all.first(where: { $0.bounds.contains(point) }) {
            return match
        }
        return all.first ?? (CGMainDisplayID(), mainScreenBounds(), mainScreenScaleFactor())
    }

    public func mainScreenScaleFactor() -> Double {
        if let screen = NSScreen.main {
            return Double(screen.backingScaleFactor)
        }
        let mode = CGDisplayCopyDisplayMode(CGMainDisplayID())
        if let mode = mode, mode.width > 0 {
            return Double(mode.pixelWidth) / Double(mode.width)
        }
        return 2.0
    }

    public func currentMouseLocation() -> ScreenPoint {
        if let event = CGEvent(source: nil) {
            return ScreenPoint(event.location)
        }
        return ScreenPoint(x: 0, y: 0)
    }

    public func currentStatus(daemonConnected: Bool, socketPath: String) -> PermissionStatus {
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName
        return PermissionStatus(
            accessibilityGranted: isAccessibilityGranted(prompt: false),
            screenRecordingGranted: isScreenRecordingGranted(prompt: false),
            daemonConnected: daemonConnected,
            socketPath: socketPath,
            activeApp: frontApp,
            mouseLocation: currentMouseLocation(),
            screenBounds: desktopBounds(),
            scaleFactor: mainScreenScaleFactor(),
            killSwitchTripped: KillSwitchMonitor.shared.isTripped
        )
    }
}
