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
    private let setWindowLocationFn: CGEventSetWindowLocationFn?

    private init() {
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") {
            self.setWindowLocationFn = unsafeBitCast(sym, to: CGEventSetWindowLocationFn.self)
        } else {
            self.setWindowLocationFn = nil
        }
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

    /// Constructs a window-targeted `CGEvent` with fields `3` (button), `7` (subtype=3), `91` & `92` (`windowID`),
    /// and window-local coordinates (`CGEventSetWindowLocation`), then posts it directly to `pid`.
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
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point.cgPoint,
            mouseButton: button
        ) else {
            return
        }

        let evNum = nextEventNumber()
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

        let localX = point.x - windowBounds.x
        let localY = point.y - windowBounds.y
        setWindowLocationFn?(event, CGPoint(x: localX, y: localY))

        event.postToPid(pid)
    }

    /// Performs a complete background click at `point` inside `(pid, windowID, windowBounds)` without moving the physical cursor.
    public func performBackgroundClick(
        at point: ScreenPoint,
        button: MouseButton,
        clickCount: Int,
        pid: Int32,
        windowID: UInt32,
        windowBounds: ScreenRect
    ) {
        enforceBackgroundFocus(
            pid: pid,
            windowID: windowID,
            windowBounds: windowBounds,
            activationPoint: point
        )

        let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = {
            switch button {
            case .left: return (.leftMouseDown, .leftMouseUp, .left)
            case .right: return (.rightMouseDown, .rightMouseUp, .right)
            case .center: return (.otherMouseDown, .otherMouseUp, .center)
            }
        }()

        // First post a mouseMoved to the target point inside the target process
        postSynthesizedMouseEvent(
            type: .mouseMoved,
            button: .left,
            at: point,
            clickCount: 0,
            pid: pid,
            windowID: windowID,
            windowBounds: windowBounds
        )
        Thread.sleep(forTimeInterval: 0.015)

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
            Thread.sleep(forTimeInterval: 0.03)
            postSynthesizedMouseEvent(
                type: upType,
                button: cgButton,
                at: point,
                clickCount: i,
                pid: pid,
                windowID: windowID,
                windowBounds: windowBounds
            )
            if i < clickCount {
                Thread.sleep(forTimeInterval: 0.04)
            }
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
