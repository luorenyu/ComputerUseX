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
            screenBounds: mainScreenBounds(),
            scaleFactor: mainScreenScaleFactor(),
            killSwitchTripped: KillSwitchMonitor.shared.isTripped
        )
    }
}
