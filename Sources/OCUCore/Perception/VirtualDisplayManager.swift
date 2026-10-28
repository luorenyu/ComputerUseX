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

    private func collectAllAXWindows(for appElem: AXUIElement) -> [AXUIElement] {
        var allWindows: [AXUIElement] = []
        var winsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &winsRef) == .success,
           let wins = winsRef as? [AXUIElement] {
            allWindows.append(contentsOf: wins)
        }
        for attr in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElem, attr as CFString, &winRef) == .success,
               let w = winRef {
                let winEl = w as! AXUIElement
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(winEl, kAXRoleAttribute as CFString, &roleRef)
                if (roleRef as? String) == "AXWindow" {
                    let h = CFHash(winEl)
                    if !allWindows.contains(where: { CFHash($0) == h }) {
                        allWindows.append(winEl)
                    }
                }
            }
        }
        func isOverlayHelper(_ win: AXUIElement) -> Bool {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef)
            let title = ((titleRef as? String) ?? "").lowercased()
            if title.contains("watermark") { return true }
            var subRef: CFTypeRef?
            AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subRef)
            let sub = (subRef as? String) ?? ""
            return sub == "AXUnknown" && title.isEmpty
        }
        if !allWindows.contains(where: { !isOverlayHelper($0) }) {
            var appPid: pid_t = 0
            if AXUIElementGetPid(appElem, &appPid) == .success, appPid > 0 {
                for w in AXScanner.shared.discoverWindowsViaRemoteToken(pid: appPid) {
                    let h = CFHash(w)
                    if !allWindows.contains(where: { CFHash($0) == h }) {
                        allWindows.append(w)
                    }
                }
            }
        }
        allWindows.sort { a, b in
            let aOverlay = isOverlayHelper(a)
            let bOverlay = isOverlayHelper(b)
            if aOverlay != bOverlay { return !aOverlay }
            var aSubRef: CFTypeRef?
            var bSubRef: CFTypeRef?
            AXUIElementCopyAttributeValue(a, kAXSubroleAttribute as CFString, &aSubRef)
            AXUIElementCopyAttributeValue(b, kAXSubroleAttribute as CFString, &bSubRef)
            let aStd = ((aSubRef as? String) == "AXStandardWindow")
            let bStd = ((bSubRef as? String) == "AXStandardWindow")
            if aStd != bStd { return aStd }
            return false
        }
        let nonOverlay = allWindows.filter { !isOverlayHelper($0) }
        return nonOverlay.isEmpty ? allWindows : nonOverlay
    }

    /// Returns true if `pid` is currently hidden (`Cmd+H`) or all of its open windows are minimized into the Dock (`Cmd+M`).
    /// Returns false if the app has an unminimized window on the current Space or on another Space.
    public func isAppMinimizedOrHidden(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if let runningApp = NSRunningApplication(processIdentifier: pid), runningApp.isHidden {
            return true
        }
        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElem, 0.5)
        let windows = collectAllAXWindows(for: appElem)
        guard !windows.isEmpty else { return false }
        let hasUnminimized = windows.contains { win in
            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
               let isMin = minRef as? Bool {
                return !isMin
            }
            return true
        }
        return !hasUnminimized
    }

    /// Returns the CoreGraphics `CGDirectDisplayID` that contains the center point (or largest intersection) of `rect`.
    public func displayID(for rect: ScreenRect) -> CGDirectDisplayID {
        let center = CGPoint(x: rect.x + rect.width / 2.0, y: rect.y + rect.height / 2.0)
        var dispID: CGDirectDisplayID = CGMainDisplayID()
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(center, 1, &dispID, &count) == .success, count > 0 {
            return dispID
        }
        let cgRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        if CGGetDisplaysWithRect(cgRect, 1, &dispID, &count) == .success, count > 0 {
            return dispID
        }
        return CGMainDisplayID()
    }

    private func readAXWindowFrame(_ win: AXUIElement) -> ScreenRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID(),
              let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sv as! AXValue, .cgSize, &sz),
              sz.width > 40, sz.height > 40 else {
            return nil
        }
        return ScreenRect(x: Double(pt.x), y: Double(pt.y), width: Double(sz.width), height: Double(sz.height))
    }

    private func raiseTopWindow(ofPid coverPid: Int32) {
        let coverAX = AXUIElementCreateApplication(coverPid)
        AXUIElementSetMessagingTimeout(coverAX, 0.4)
        var coverWinsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(coverAX, kAXWindowsAttribute as CFString, &coverWinsRef) == .success,
           let coverWins = coverWinsRef as? [AXUIElement], let topCover = coverWins.first {
            _ = AXUIElementPerformAction(topCover, kAXRaiseAction as CFString)
        }
    }

    /// Finds the topmost large on-screen window (e.g. `Antigravity`) that can act as a visual shield/cover
    /// so a background target window on the same display can be positioned directly underneath it in Z-order.
    public func resolveForegroundCoverWindow(
        excludingPid targetPid: Int32,
        onDisplay requiredDisplayID: CGDirectDisplayID? = nil
    ) -> (pid: Int32, windowID: UInt32, bounds: ScreenRect, appName: String, displayID: CGDirectDisplayID)? {
        guard let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0

        var candidates: [(pid: Int32, windowID: UInt32, bounds: ScreenRect, appName: String, displayID: CGDirectDisplayID)] = []
        for dict in onScreen {
            guard let ownerPid = dict[kCGWindowOwnerPID as String] as? Int32,
                  ownerPid != selfPid,
                  ownerPid != targetPid,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let wid = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let b = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
            let lower = ownerName.lowercased()
            if lower.contains("computerusex") || lower.contains("opencomputeruse") || lower.contains("finder") || lower.contains("访达") {
                continue
            }
            let rect = ScreenRect(
                x: Double(b["X"] ?? 0),
                y: Double(b["Y"] ?? 0),
                width: Double(b["Width"] ?? 0),
                height: Double(b["Height"] ?? 0)
            )
            guard rect.width >= 600, rect.height >= 450 else { continue }
            let disp = displayID(for: rect)
            if let reqDisp = requiredDisplayID, disp != reqDisp {
                continue
            }
            candidates.append((ownerPid, wid, rect, ownerName, disp))
        }

        if let frontMatch = candidates.first(where: { $0.pid == frontPid }) {
            return frontMatch
        }
        return candidates.first
    }

    /// Display-aware non-intrusive window placement:
    /// 1. If `pid`'s window is on a DIFFERENT display from the user's active foreground window (e.g. `Antigravity`),
    ///    it NEVER drags the window across displays or alters its size/position — it leaves it in place on that secondary display.
    /// 2. If `pid`'s window is on the SAME display as the user's active foreground window, it keeps the foreground
    ///    window raised on top in Z-order and only tucks `pid`'s frame if its edges would protrude outside the cover window.
    public func tuckWindowUnderFrontmost(pid: Int32, axWindow: AXUIElement? = nil) {
        guard pid > 0 else { return }
        let userFrontApp = NSWorkspace.shared.frontmostApplication
        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElem, 0.6)

        let targetWin: AXUIElement? = {
            if let explicit = axWindow { return explicit }
            return collectAllAXWindows(for: appElem).first
        }()
        guard let win = targetWin else { return }

        let targetFrame = readAXWindowFrame(win)
        let targetDisp = targetFrame.map { displayID(for: $0) }

        if let cover = resolveForegroundCoverWindow(excludingPid: pid) {
            if let tDisp = targetDisp, tDisp != cover.displayID {
                // Target window lives on a DIFFERENT monitor from the user's active foreground window (`Antigravity`).
                // Do NOT move it across monitors or resize it! Just ensure the user's active window and any existing
                // top window on that secondary monitor stay above it in Z-order.
                // The target is already on another display. Leave its frame and
                // z-order untouched: the caller can operate it through AX
                // without moving it into the user's active display or changing
                // what the user is currently looking at.
            } else {
                // Target window is on the SAME monitor as the user's active foreground window (`Antigravity`).
                let curW = targetFrame?.width ?? (cover.bounds.width - 32.0)
                let curH = targetFrame?.height ?? (cover.bounds.height - 32.0)
                let isAlreadyCovered: Bool = {
                    guard let tf = targetFrame else { return false }
                    return tf.x >= cover.bounds.x - 4.0 &&
                           tf.y >= cover.bounds.y - 4.0 &&
                           (tf.x + tf.width) <= (cover.bounds.x + cover.bounds.width + 4.0) &&
                           (tf.y + tf.height) <= (cover.bounds.y + cover.bounds.height + 4.0)
                }()

                if !isAlreadyCovered {
                    let maxW = max(400.0, cover.bounds.width - 24.0)
                    let maxH = max(320.0, cover.bounds.height - 24.0)
                    let newW = min(curW, maxW)
                    let newH = min(curH, maxH)
                    let newX = cover.bounds.x + (cover.bounds.width - newW) / 2.0
                    let newY = cover.bounds.y + (cover.bounds.height - newH) / 2.0

                    if newW < curW - 1.0 || newH < curH - 1.0 {
                        var targetSize = CGSize(width: newW, height: newH)
                        if let axSize = AXValueCreate(.cgSize, &targetSize) {
                            _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, axSize)
                        }
                    }
                    var targetPt = CGPoint(x: newX, y: newY)
                    if let axPt = AXValueCreate(.cgPoint, &targetPt) {
                        _ = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axPt)
                    }
                }

                // Ensure the cover window (e.g. Antigravity) stays at Z-index #0 in front of the target window
                raiseTopWindow(ofPid: cover.pid)
            }
        }

        if let front = userFrontApp, front.processIdentifier != pid,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != front.processIdentifier {
            front.activate()
        }
    }

    /// Ensures that if ALL of a target application's windows are minimized to the Dock (`kAXMinimizedAttribute == true`)
    /// or the application is hidden (`NSRunningApplication.isHidden`), a single window is unminimized in the background:
    /// - If the window belongs to another monitor, it unminimizes in place on that monitor without moving to the user's active screen.
    /// - If the window is on the same monitor as the user's active app, it stays occluded underneath the active window.
    @discardableResult
    public func ensureWindowUnminimizedInBackground(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let userFrontApp = NSWorkspace.shared.frontmostApplication
        var changed = false
        if let runningApp = NSRunningApplication(processIdentifier: pid), runningApp.isHidden {
            runningApp.unhide()
            changed = true
        }
        let appElem = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElem, 0.6)
        let windows = collectAllAXWindows(for: appElem)
        guard !windows.isEmpty else {
            if changed {
                tuckWindowUnderFrontmost(pid: pid)
            }
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
            if changed {
                tuckWindowUnderFrontmost(pid: pid, axWindow: windows.first)
            }
            return changed
        }
        if let firstWin = windows.first {
            // Unminimize first without overriding coordinates so macOS restores the window onto its native display!
            AXUIElementSetAttributeValue(firstWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(firstWin, kAXMainAttribute as CFString, kCFBooleanTrue)
            changed = true
            Thread.sleep(forTimeInterval: 0.22)
            tuckWindowUnderFrontmost(pid: pid, axWindow: firstWin)
            if let front = userFrontApp, front.processIdentifier != pid,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != front.processIdentifier {
                front.activate()
            }
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
