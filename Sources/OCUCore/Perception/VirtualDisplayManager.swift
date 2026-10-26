import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

@_silgen_name("CGSessionCopyCurrentDictionary")
private func OCU_CGSessionCopyCurrentDictionary() -> CFDictionary?

public struct ParkedWindowState: Codable, Equatable, Sendable {
    public var appName: String
    public var pid: Int32
    public var windowID: UInt32
    public var originalFrame: ScreenRect
    public var parkedFrame: ScreenRect
    public var parkedAt: String
}

/// Manages macOS Screen Lock detection, automatic background unminimization, and the
/// "Ghost Space" / Virtual Display Offscreen Sandbox (`ocu sandbox`) so background windows can be
/// operated with zero central desktop clutter while keeping their WindowServer surface live for PiP capture.
public final class VirtualDisplayManager: @unchecked Sendable {
    public static let shared = VirtualDisplayManager()

    private let lock = NSLock()
    private var parkedWindows: [UInt32: ParkedWindowState] = [:]

    private init() {}

    /// Detects whether the macOS login session is currently screen-locked (`CGSSessionScreenIsLocked`).
    public func isScreenLocked() -> Bool {
        guard let dict = OCU_CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        if let lockedNum = dict["CGSSessionScreenIsLocked"] as? NSNumber {
            return lockedNum.boolValue
        }
        return false
    }

    /// Checks whether macOS supports runtime `CGVirtualDisplay` creation in the current process.
    public func isCGVirtualDisplayRuntimeAvailable() -> Bool {
        return NSClassFromString("CGVirtualDisplay") != nil && NSClassFromString("CGVirtualDisplayDescriptor") != nil
    }

    /// Ensures that if ALL of a target application's windows are minimized to the Dock (`kAXMinimizedAttribute == true`)
    /// or the application is hidden (`NSRunningApplication.isHidden`), a single window is unminimized when explicitly requested.
    /// If the app already has at least one unminimized window on any display, its minimized windows are never touched.
    @discardableResult
    public func ensureWindowUnminimizedInBackground(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var changed = false
        if let runningApp = NSRunningApplication(processIdentifier: pid), runningApp.isHidden {
            runningApp.unhide()
            changed = true
        }
        let appElem = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return changed
        }
        let hasUnminimizedWindow = windows.contains { win in
            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
               let isMin = minRef as? Bool {
                return !isMin
            }
            return true
        }
        if hasUnminimizedWindow {
            return changed
        }
        if let firstWin = windows.first {
            AXUIElementSetAttributeValue(firstWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            changed = true
            Thread.sleep(forTimeInterval: 0.35)
        }
        return changed
    }

    /// Parks a target app's window into the "Ghost Space" peripheral sandbox zone (bottom-right edge of the display,
    /// keeping >=96pt on-screen so macOS WindowServer continues compositing its GPU surface at 60fps for Mini PiP)
    /// while freeing the user's primary workspace!
    public func parkWindowInGhostSandbox(appName: String) throws -> ActionOutcome {
        let start = Date()
        let scan = AXScanner.shared.scanApplication(appNameFilter: appName, maxDepth: 4, maxElements: 10)
        guard scan.pid > 0, let wid = scan.windowID, let currentFrame = scan.windowFrame else {
            throw OCUError(
                code: .appNotFound,
                message: "Could not find a live window for '\(appName)' to park in Ghost Sandbox.",
                recoveryHint: "Ensure '\(appName)' is running."
            )
        }

        ensureWindowUnminimizedInBackground(pid: scan.pid)

        let screen = PermissionManager.shared.mainScreenBounds()
        // Keep a thin 120pt corner slice inside display bounds so macOS WindowServer never suspends GPU rendering
        let sandboxOrigin = ScreenPoint(
            x: max(40.0, screen.width - 140.0),
            y: max(40.0, screen.height - 140.0)
        )

        lock.lock()
        if parkedWindows[wid] == nil {
            parkedWindows[wid] = ParkedWindowState(
                appName: scan.appName,
                pid: scan.pid,
                windowID: wid,
                originalFrame: currentFrame,
                parkedFrame: ScreenRect(
                    x: sandboxOrigin.x,
                    y: sandboxOrigin.y,
                    width: currentFrame.width,
                    height: currentFrame.height
                ),
                parkedAt: ISO8601DateFormatter().string(from: Date())
            )
        }
        lock.unlock()

        _ = AXScanner.shared.moveWindowBackground(pid: scan.pid, windowID: wid, to: sandboxOrigin)

        let newBounds = ScreenRect(
            x: sandboxOrigin.x,
            y: sandboxOrigin.y,
            width: currentFrame.width,
            height: currentFrame.height
        )
        KillSwitchMonitor.shared.emitHUDEvent(
            .pipTargetWindow(
                pid: scan.pid,
                windowID: wid,
                appName: scan.appName,
                windowTitle: scan.windowTitle,
                windowBounds: newBounds
            )
        )

        return ActionOutcome(
            action: "sandbox_park",
            targetDescription: "\(scan.appName) (#\(wid)) parked to Ghost Space",
            point: sandboxOrigin,
            details: "Original frame [\(Int(currentFrame.x)),\(Int(currentFrame.y))] saved; live surface streaming in Mini PiP",
            elapsedMs: Int(Date().timeIntervalSince(start) * 1000)
        )
    }

    /// Restores a previously parked window (or all parked windows) back to its exact original workspace position.
    public func restoreParkedWindows(appName: String? = nil) -> ActionOutcome {
        let start = Date()
        lock.lock()
        let statesToRestore: [ParkedWindowState]
        if let app = appName, !app.isEmpty {
            let lower = app.lowercased()
            statesToRestore = parkedWindows.values.filter { $0.appName.lowercased().contains(lower) }
            for st in statesToRestore {
                parkedWindows.removeValue(forKey: st.windowID)
            }
        } else {
            statesToRestore = Array(parkedWindows.values)
            parkedWindows.removeAll()
        }
        lock.unlock()

        for st in statesToRestore {
            _ = AXScanner.shared.moveWindowBackground(
                pid: st.pid,
                windowID: st.windowID,
                to: ScreenPoint(x: st.originalFrame.x, y: st.originalFrame.y)
            )
        }

        return ActionOutcome(
            action: "sandbox_restore",
            targetDescription: "Restored \(statesToRestore.count) window(s) from Ghost Sandbox",
            details: statesToRestore.map { "\($0.appName) (#\($0.windowID)) -> (\(Int($0.originalFrame.x)),\(Int($0.originalFrame.y)))" }.joined(separator: ", "),
            elapsedMs: Int(Date().timeIntervalSince(start) * 1000)
        )
    }

    public func currentParkedWindows() -> [ParkedWindowState] {
        lock.lock()
        defer { lock.unlock() }
        return Array(parkedWindows.values)
    }
}
