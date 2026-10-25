import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import Darwin

/// Replicates Codex (`SkyComputerUseService`) background event synthesis (`AccessibilitySupport.SynthesizedEvent`
/// and `AccessibilitySupport.SyntheticAppFocusEnforcer`), enabling non-intrusive background clicks and typing
/// via `CGEventPostToPid` without moving the user's physical mouse cursor or stealing OS focus.
public final class SyntheticFocusEnforcer: @unchecked Sendable {
    public static let shared = SyntheticFocusEnforcer()

    private typealias CGEventSetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void

    private let lock = NSLock()
    private var eventCounter: Int64 = 1000
    private var activeStates: [Int32: Bool] = [:]
    private var pinnedWindowsByPid: [Int32: UInt32] = [:]
    private let setWindowLocationFn: CGEventSetWindowLocationFn?

    private init() {
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") {
            self.setWindowLocationFn = unsafeBitCast(sym, to: CGEventSetWindowLocationFn.self)
        } else {
            self.setWindowLocationFn = nil
        }
    }

    public func pinWindow(pid: Int32, windowID: UInt32) {
        guard pid > 0, windowID > 0 else { return }
        lock.lock()
        pinnedWindowsByPid[pid] = windowID
        lock.unlock()
    }

    public func pinnedWindowID(forPid pid: Int32) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return pinnedWindowsByPid[pid]
    }

    public func nextEventNumber() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        eventCounter += 1
        return eventCounter
    }

    /// Resolves the target application's `pid`, `CGWindowID`, and logical `ScreenRect` at a screen coordinate
    /// (even if the target window is occluded behind another application's window).
    public func resolveTargetWindow(
        at point: ScreenPoint,
        preferredPid: Int32? = nil,
        preferredAppName: String? = nil
    ) -> (pid: Int32, windowID: UInt32, bounds: ScreenRect, appName: String)? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let selfPid = ProcessInfo.processInfo.processIdentifier

        // 1. If preferredPid or preferredAppName is specified, search that app's layer-0 windows first
        if preferredPid != nil || (preferredAppName != nil && !preferredAppName!.isEmpty) {
            let candidates = infoList.compactMap { dict -> (pid: Int32, windowID: UInt32, bounds: ScreenRect, appName: String)? in
                guard let ownerPid = dict[kCGWindowOwnerPID as String] as? Int32,
                      ownerPid != selfPid,
                      let layer = dict[kCGWindowLayer as String] as? Int,
                      layer == 0,
                      let winNum = dict[kCGWindowNumber as String] as? UInt32,
                      let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                    return nil
                }
                let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
                if let pPid = preferredPid, ownerPid != pPid {
                    return nil
                }
                if let pName = preferredAppName?.lowercased(), !pName.isEmpty,
                   !ownerName.lowercased().contains(pName) {
                    return nil
                }
                let rect = ScreenRect(
                    x: Double(boundsDict["X"] ?? 0),
                    y: Double(boundsDict["Y"] ?? 0),
                    width: Double(boundsDict["Width"] ?? 0),
                    height: Double(boundsDict["Height"] ?? 0)
                )
                guard rect.width >= 80, rect.height >= 80 else { return nil }
                return (ownerPid, winNum, rect, ownerName)
            }

            if let pPid = preferredPid,
               let pinnedWid = pinnedWindowID(forPid: pPid),
               let pinnedMatch = candidates.first(where: { $0.windowID == pinnedWid }) {
                return pinnedMatch
            }
            if let containing = candidates.first(where: { $0.bounds.contains(point) }) {
                return containing
            }
            if let largest = candidates.max(by: { ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height) }) {
                return largest
            }
        }

        // 2. Otherwise find the topmost normal (layer 0) window containing `point`
        for dict in infoList {
            guard let ownerPid = dict[kCGWindowOwnerPID as String] as? Int32,
                  ownerPid != selfPid,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let winNum = dict[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
            if ownerName.lowercased().contains("opencomputeruse") { continue }
            let rect = ScreenRect(
                x: Double(boundsDict["X"] ?? 0),
                y: Double(boundsDict["Y"] ?? 0),
                width: Double(boundsDict["Width"] ?? 0),
                height: Double(boundsDict["Height"] ?? 0)
            )
            guard rect.width >= 80, rect.height >= 80 else { continue }
            if rect.contains(point) {
                return (ownerPid, winNum, rect, ownerName)
            }
        }

        return nil
    }

    /// Returns true if the topmost visible on-screen window containing `point` belongs to `pid`.
    public func isPointUnoccludedOnScreen(at point: ScreenPoint, forPid pid: Int32) -> Bool {
        guard let onScreenList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        for dict in onScreenList {
            guard let ownerPid = dict[kCGWindowOwnerPID as String] as? Int32,
                  ownerPid != selfPid,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
            if ownerName.lowercased().contains("opencomputeruse") { continue }
            let rect = ScreenRect(
                x: Double(boundsDict["X"] ?? 0),
                y: Double(boundsDict["Y"] ?? 0),
                width: Double(boundsDict["Width"] ?? 0),
                height: Double(boundsDict["Height"] ?? 0)
            )
            guard rect.width >= 80, rect.height >= 80 else { continue }
            if rect.contains(point) {
                return ownerPid == pid
            }
        }
        return false
    }

    /// Returns true only if `windowID` is currently the active frontmost unoccluded window on its display.
    /// When false, the target window is in the background or occluded, so cursor feedback should be shown inside
    /// the Mini PiP Live Preview Window instead of cluttering the user's main desktop.
    public func isWindowFrontmostOnScreen(windowID: UInt32, pid: Int32) -> Bool {
        guard windowID > 0 else { return false }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return false
        }
        guard let onScreenList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        for dict in onScreenList {
            guard let ownerPid = dict[kCGWindowOwnerPID as String] as? Int32,
                  ownerPid != selfPid,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let winNum = dict[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
            if ownerName.lowercased().contains("opencomputeruse") { continue }
            let w = Double(boundsDict["Width"] ?? 0)
            let h = Double(boundsDict["Height"] ?? 0)
            guard w >= 80, h >= 80 else { continue }
            // The first normal window for `pid` in on-screen z-order must be `windowID`
            if ownerPid == pid {
                return winNum == windowID
            }
        }
        return false
    }

    private func windowUsesFlippedCoordinates(forPid pid: Int32) -> Bool {
        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.lowercased() ?? ""
        if bundleId.contains("wechat") || bundleId.contains("xinwechat") {
            return true
        }
        return false
    }

    /// Sends synthetic `kCGEventAppKitDefined` (`type = 13`, `subtype = 1` ApplicationActivated) events directly
    /// to `pid` so the background application believes it is active and key-focused without stealing OS focus.
    public func enforceBackgroundFocus(
        pid: Int32,
        windowID: UInt32,
        windowBounds: ScreenRect,
        activationPoint: ScreenPoint
    ) {
        let uptime = ProcessInfo.processInfo.systemUptime
        let flags = windowID != 0 ? NSEvent.ModifierFlags(rawValue: 0xc0000) : []

        // 1. AppKitDefined subtype 1: NSApplicationActivatedEventType
        if let activateNSEvent = NSEvent.otherEvent(
            with: .appKitDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: uptime,
            windowNumber: Int(windowID),
            context: nil,
            subtype: 1,
            data1: Int(windowID),
            data2: 0
        ), let cgActivate = activateNSEvent.cgEvent {
            cgActivate.postToPid(pid)
        }

        // 2. AppKitDefined subtype 4: WindowKeyFocusReturned / WindowMoved notification
        if let keyFocusNSEvent = NSEvent.otherEvent(
            with: .appKitDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: uptime,
            windowNumber: Int(windowID),
            context: nil,
            subtype: 4,
            data1: Int(windowID),
            data2: 1
        ), let cgKeyFocus = keyFocusNSEvent.cgEvent {
            cgKeyFocus.postToPid(pid)
        }

        lock.lock()
        activeStates[pid] = true
        lock.unlock()
    }

    /// Constructs a window-targeted `CGEvent` via `NSEvent.mouseEvent` (matching Codex `SynthesizedEvent.mouseEvent`)
    /// with fields `3` (button), `7` (subtype=3), `91` & `92` (`windowID`), and bottom-up window-local coordinates
    /// (`CGEventSetWindowLocation`), then posts it directly to `pid`.
    public func postSynthesizedMouseEvent(
        type: CGEventType,
        button: CGMouseButton,
        at point: ScreenPoint,
        clickCount: Int,
        flags: CGEventFlags = [],
        pid: Int32,
        windowID: UInt32,
        windowBounds: ScreenRect
    ) {
        let evNum = nextEventNumber()
        let localX = point.x - windowBounds.x
        let localYTopDown = point.y - windowBounds.y
        let localYBottomUp = max(0.0, windowBounds.height - localYTopDown)
        let nsLocation = CGPoint(x: localX, y: localYBottomUp)

        let nsType: NSEvent.EventType = {
            switch type {
            case .leftMouseDown: return .leftMouseDown
            case .leftMouseUp: return .leftMouseUp
            case .rightMouseDown: return .rightMouseDown
            case .rightMouseUp: return .rightMouseUp
            case .otherMouseDown: return .otherMouseDown
            case .otherMouseUp: return .otherMouseUp
            case .leftMouseDragged: return .leftMouseDragged
            case .rightMouseDragged: return .rightMouseDragged
            case .otherMouseDragged: return .otherMouseDragged
            default: return .mouseMoved
            }
        }()

        let pressure: Float = (type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown || type == .leftMouseDragged) ? 1.0 : 0.0
        let nsEvent = NSEvent.mouseEvent(
            with: nsType,
            location: nsLocation,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue)),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: Int(windowID),
            context: nil,
            eventNumber: Int(evNum),
            clickCount: max(1, clickCount),
            pressure: pressure
        )

        guard let event = nsEvent?.cgEvent ?? CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point.cgPoint,
            mouseButton: button
        ) else {
            return
        }

        event.flags = flags
        event.location = point.cgPoint
        event.setIntegerValueField(.mouseEventNumber, value: evNum)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        // Field 3: mouseEventButtonNumber
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        // Field 7: mouseEventSubtype = 3 (window-targeted event subtype used by Codex SynthesizedEvent)
        event.setIntegerValueField(.mouseEventSubtype, value: 3)

        if windowID != 0 {
            if let field91 = CGEventField(rawValue: 91) {
                event.setIntegerValueField(field91, value: Int64(windowID))
            }
            if let field92 = CGEventField(rawValue: 92) {
                event.setIntegerValueField(field92, value: Int64(windowID))
            }
        }

        // Match Codex's `windowUsesFlippedCoordinates` branch (0x10075dd84 in SkyComputerUseService):
        // Flipped custom UIs (WeChat) use top-down localY, whereas standard AppKit NSWindows (Chrome/Safari) use bottom-up localY.
        let usesFlipped = windowUsesFlippedCoordinates(forPid: pid)
        let winLocalPt = CGPoint(x: localX, y: usesFlipped ? localYTopDown : localYBottomUp)
        setWindowLocationFn?(event, winLocalPt)
        event.postToPid(pid)
    }

    /// Performs a complete click at `point` inside `(pid, windowID, windowBounds)` while preserving the user's
    /// physical mouse cursor position so custom C++ / Qt / Electron apps (like WeChat) and native Cocoa apps both respond.
    public func performBackgroundClick(
        at point: ScreenPoint,
        button: MouseButton,
        clickCount: Int,
        pid: Int32,
        windowID: UInt32,
        windowBounds: ScreenRect
    ) {
        let savedMousePos = PermissionManager.shared.currentMouseLocation().cgPoint

        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = {
            switch button {
            case .left: return (.leftMouseDown, .leftMouseUp, .left)
            case .right: return (.rightMouseDown, .rightMouseUp, .right)
            case .center: return (.otherMouseDown, .otherMouseUp, .center)
            }
        }()

        // 1. If the target app is already the frontmost application and the point is unoccluded on screen,
        // perform an atomic micro-warp + HID event tap click, wait 35ms for WindowServer/Chromium to process
        // the mouseUp event at `cgPt`, and then immediately restore the user's physical cursor.
        // When the target app is in the background, we NEVER use `.cghidEventTap` so we never steal OS focus!
        let isFrontmostApp = (NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
        if isFrontmostApp && isPointUnoccludedOnScreen(at: point, forPid: pid) {
            let cgPt = point.cgPoint
            CGWarpMouseCursorPosition(cgPt)
            CGAssociateMouseAndMouseCursorPosition(1)
            if let moveEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: cgPt,
                mouseButton: .left
            ) {
                moveEvent.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.010)
            for i in 1...max(1, clickCount) {
                if let downEvent = CGEvent(
                    mouseEventSource: nil,
                    mouseType: downType,
                    mouseCursorPosition: cgPt,
                    mouseButton: cgButton
                ), let upEvent = CGEvent(
                    mouseEventSource: nil,
                    mouseType: upType,
                    mouseCursorPosition: cgPt,
                    mouseButton: cgButton
                ) {
                    downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                    upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                    downEvent.post(tap: .cghidEventTap)
                    Thread.sleep(forTimeInterval: 0.025)
                    upEvent.post(tap: .cghidEventTap)
                }
                if i < clickCount {
                    Thread.sleep(forTimeInterval: 0.030)
                }
            }
            // Wait 35ms before restoring cursor so asynchronous IPC apps (Chrome/Electron) receive mouseUp at cgPt
            Thread.sleep(forTimeInterval: 0.035)
            CGWarpMouseCursorPosition(savedMousePos)
            CGAssociateMouseAndMouseCursorPosition(1)
            return
        }

        // 2. Fallback for occluded background windows: post window-targeted events directly to PID
        enforceBackgroundFocus(
            pid: pid,
            windowID: windowID,
            windowBounds: windowBounds,
            activationPoint: point
        )

        postSynthesizedMouseEvent(
            type: .mouseMoved,
            button: .left,
            at: point,
            clickCount: 0,
            pid: pid,
            windowID: windowID,
            windowBounds: windowBounds
        )

        for i in 1...max(1, clickCount) {
            postSynthesizedMouseEvent(
                type: downType,
                button: cgButton,
                at: point,
                clickCount: i,
                pid: pid,
                windowID: windowID,
                windowBounds: windowBounds
            )
            Thread.sleep(forTimeInterval: 0.015)
            postSynthesizedMouseEvent(
                type: upType,
                button: cgButton,
                at: point,
                clickCount: i,
                pid: pid,
                windowID: windowID,
                windowBounds: windowBounds
            )
        }
    }

    /// Posts a key press (`keyCode` + modifier `flags`) directly to `pid`.
    public func postSynthesizedKeyCode(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        toPid pid: Int32
    ) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        Thread.sleep(forTimeInterval: 0.02)
        up.postToPid(pid)
    }
}
