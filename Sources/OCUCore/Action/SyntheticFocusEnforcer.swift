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
            if let containing = candidates.first(where: {
                let padded = ScreenRect(x: $0.bounds.x - 14, y: $0.bounds.y - 14, width: $0.bounds.width + 28, height: $0.bounds.height + 28)
                return padded.contains(point)
            }) {
                return containing
            }
            if let largest = candidates.max(by: { ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height) }) {
                return largest
            }
        }

        // 2. Otherwise find the topmost ON-SCREEN normal (layer 0) window containing `point`
        let onScreenList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? infoList
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
            let lowerOwner = ownerName.lowercased()
            if lowerOwner.contains("computerusex") || lowerOwner.contains("opencomputeruse") { continue }
            let rect = ScreenRect(
                x: Double(boundsDict["X"] ?? 0),
                y: Double(boundsDict["Y"] ?? 0),
                width: Double(boundsDict["Width"] ?? 0),
                height: Double(boundsDict["Height"] ?? 0)
            )
            guard rect.width >= 80, rect.height >= 80 else { continue }
            let padded = ScreenRect(x: rect.x - 14, y: rect.y - 14, width: rect.width + 28, height: rect.height + 28)
            if padded.contains(point) {
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
            let lowerOwner = ownerName.lowercased()
            if lowerOwner.contains("computerusex") || lowerOwner.contains("opencomputeruse") { continue }
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

    /// Returns true if `windowID` (or any main window of `pid` if `windowID == 0`) is currently on-screen
    /// on the active Space and at the top layer of its desktop/display (not covered by another app's window).
    /// Note: Ignores same-PID helper/overlay windows (such as Feishu's transparent `WatermarkWidget`) and
    /// does NOT require `pid` to hold global keyboard focus (`frontmostApplication`), because on a multi-monitor
    /// or side-by-side desktop setup the target window can already be completely visible at the top of its screen!
    public func isWindowFrontmostOnScreen(windowID: UInt32, pid: Int32) -> Bool {
        guard windowID > 0 || pid > 0 else { return false }
        guard let onScreenList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let selfPid = ProcessInfo.processInfo.processIdentifier

        // 1. Locate the target window in `onScreenList` to verify it is on the current Space and get its bounds & Z-index
        var targetIndex: Int? = nil
        var targetBounds: ScreenRect? = nil
        var resolvedPid: Int32 = pid

        for (idx, dict) in onScreenList.enumerated() {
            guard let ownerPid = dict[kCGWindowOwnerPID as String] as? Int32,
                  ownerPid != selfPid,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let winNum = dict[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let w = Double(boundsDict["Width"] ?? 0)
            let h = Double(boundsDict["Height"] ?? 0)
            guard w >= 80, h >= 80 else { continue }

            if windowID > 0 {
                if winNum == windowID {
                    targetIndex = idx
                    targetBounds = ScreenRect(
                        x: Double(boundsDict["X"] ?? 0),
                        y: Double(boundsDict["Y"] ?? 0),
                        width: w,
                        height: h
                    )
                    if resolvedPid <= 0 { resolvedPid = ownerPid }
                    break
                }
            } else if pid > 0 && ownerPid == pid {
                targetIndex = idx
                targetBounds = ScreenRect(
                    x: Double(boundsDict["X"] ?? 0),
                    y: Double(boundsDict["Y"] ?? 0),
                    width: w,
                    height: h
                )
                break
            }
        }

        // If the target window is not in `onScreenList`, it is minimized to Dock or on another Space
        guard let foundIdx = targetIndex, let tBounds = targetBounds else {
            return false
        }
        let targetArea = max(1.0, tBounds.width * tBounds.height)

        // 2. Check all normal layer-0 windows ordered ABOVE `windowID` (`0 ..< foundIdx`).
        // Ignore windows belonging to `ComputerUseX` or the same `resolvedPid` (e.g., Feishu's WatermarkWidget overlay).
        // If another app's window above `windowID` significantly overlaps `tBounds` (> 8% of area or covers its center),
        // then `windowID` is occluded/underneath another window. Otherwise it is at the top layer of its desktop!
        for idx in 0..<foundIdx {
            let dict = onScreenList[idx]
            guard let ownerPid = dict[kCGWindowOwnerPID as String] as? Int32,
                  ownerPid != selfPid,
                  ownerPid != resolvedPid,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            if let alpha = dict[kCGWindowAlpha as String] as? Double, alpha <= 0.05 {
                continue
            }
            let ownerName = (dict[kCGWindowOwnerName as String] as? String) ?? ""
            let lowerOwner = ownerName.lowercased()
            if lowerOwner.contains("computerusex") || lowerOwner.contains("opencomputeruse") { continue }

            let rect = ScreenRect(
                x: Double(boundsDict["X"] ?? 0),
                y: Double(boundsDict["Y"] ?? 0),
                width: Double(boundsDict["Width"] ?? 0),
                height: Double(boundsDict["Height"] ?? 0)
            )
            guard rect.width >= 80, rect.height >= 80 else { continue }

            let overlap = rect.intersectionArea(with: tBounds)
            if overlap > targetArea * 0.08 || rect.contains(tBounds.center) {
                return false
            }
        }
        return true
    }

    private func windowUsesFlippedCoordinates(forPid pid: Int32) -> Bool {
        // SkyLight's `CGEventSetWindowLocation` (`SLSEventSetWindowLocation`) uses top-down window-local
        // coordinates (`localYTopDown = point.y - windowBounds.y`) across AppKit, Electron/Chromium (Feishu/Lark,
        // VSCode, Chrome), and custom UIs (WeChat). Passing bottom-up Y mirrors clicks vertically.
        return true
    }

    /// Sends synthetic `kCGEventAppKitDefined` (`type = 13`, `subtype = 1` ApplicationActivated) events directly
    /// to `pid` so the background application believes it is active and key-focused without stealing OS focus.
    /// IMPORTANT: When the target window is on another macOS Space (`!isWindowOnCurrentSpace`), we NEVER send
    /// `NSApplicationActivatedEventType` (`subtype = 1`), because Electron/AppKit responds by ordering its window
    /// front and causing macOS WindowServer/Dock to switch Spaces to the target application!
    public func enforceBackgroundFocus(
        pid: Int32,
        windowID: UInt32,
        windowBounds: ScreenRect,
        activationPoint: ScreenPoint
    ) {
        let effWid = windowID != 0 ? windowID : (pinnedWindowID(forPid: pid) ?? 0)
        let onCurrentSpace = SpaceFocusMonitor.shared.isWindowOnCurrentSpace(windowID: effWid, pid: pid)
        guard onCurrentSpace else {
            // Never post AppKitDefined subtype 1/4 to an off-Space window: Electron/Chromium will immediately
            // order its window front and cause macOS WindowServer to switch Spaces away from the user!
            return
        }
        SpaceFocusMonitor.shared.traceSubStep(
            "enforceBackgroundFocus",
            targetPid: pid,
            windowID: effWid,
            details: "appKitDefined(subtype=1,4)"
        ) {
            let uptime = ProcessInfo.processInfo.systemUptime
            let flags = effWid != 0 ? NSEvent.ModifierFlags(rawValue: 0xc0000) : []

            // 1. AppKitDefined subtype 1: NSApplicationActivatedEventType
            if let activateNSEvent = NSEvent.otherEvent(
                with: .appKitDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: uptime,
                windowNumber: Int(effWid),
                context: nil,
                subtype: 1,
                data1: Int(effWid),
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
                windowNumber: Int(effWid),
                context: nil,
                subtype: 4,
                data1: Int(effWid),
                data2: 1
            ), let cgKeyFocus = keyFocusNSEvent.cgEvent {
                cgKeyFocus.postToPid(pid)
            }

            lock.lock()
            activeStates[pid] = true
            lock.unlock()
        }
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

    /// Performs a complete click at `point` inside `(pid, windowID, windowBounds)` using pure process-targeted
    /// synthesized events (`postToPid`) without ever warping the user's physical mouse cursor or posting to `.cghidEventTap`.
    public func performBackgroundClick(
        at point: ScreenPoint,
        button: MouseButton,
        clickCount: Int,
        pid: Int32,
        windowID: UInt32,
        windowBounds: ScreenRect
    ) {
        SpaceFocusMonitor.shared.traceSubStep(
            "performBackgroundClick",
            targetPid: pid,
            windowID: windowID,
            details: "point=(\(Int(point.x)),\(Int(point.y)))"
        ) {
            let (downType, upType, cgButton): (CGEventType, CGEventType, CGMouseButton) = {
                switch button {
                case .left: return (.leftMouseDown, .leftMouseUp, .left)
                case .right: return (.rightMouseDown, .rightMouseUp, .right)
                case .center: return (.otherMouseDown, .otherMouseUp, .center)
                }
            }()

            // Post window-targeted events directly to PID without touching .cghidEventTap or physical mouse cursor
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
    }

    /// Posts a window-targeted scroll wheel event directly to `pid` (matching Codex `SynthesizedEvent.scroll`)
    /// when the target window is in the background, avoiding focus stealing or scrolling the wrong foreground window.
    public func postSynthesizedScrollEvent(
        at point: ScreenPoint,
        dx: Int32,
        dy: Int32,
        pid: Int32,
        windowID: UInt32,
        windowBounds: ScreenRect,
        phase: Int64 = 2
    ) {
        guard let scrollEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else {
            return
        }
        scrollEvent.location = point.cgPoint
        scrollEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        scrollEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        if windowID != 0 {
            if let field91 = CGEventField(rawValue: 91) {
                scrollEvent.setIntegerValueField(field91, value: Int64(windowID))
            }
            if let field92 = CGEventField(rawValue: 92) {
                scrollEvent.setIntegerValueField(field92, value: Int64(windowID))
            }
        }
        let localX = point.x - windowBounds.x
        let localYTopDown = point.y - windowBounds.y
        let localYBottomUp = max(0.0, windowBounds.height - localYTopDown)
        let usesFlipped = windowUsesFlippedCoordinates(forPid: pid)
        let winLocalPt = CGPoint(x: localX, y: usesFlipped ? localYTopDown : localYBottomUp)
        setWindowLocationFn?(scrollEvent, winLocalPt)
        scrollEvent.postToPid(pid)
    }

    /// Posts a key press (`keyCode` + modifier `flags`) directly to `pid` (including across macOS Spaces).
    public func postSynthesizedKeyCode(
        _ keyCode: CGKeyCode,
        flags: CGEventFlags = [],
        toPid pid: Int32
    ) {
        let wid = Int(pinnedWindowID(forPid: pid) ?? 0)
        if wid > 0 {
            enforceBackgroundFocus(
                pid: pid,
                windowID: UInt32(wid),
                windowBounds: ScreenRect(x: 0, y: 0, width: 0, height: 0),
                activationPoint: ScreenPoint(x: 0, y: 0)
            )
        }
        let charMap: [CGKeyCode: String] = [
            36: "\r", 48: "\t", 49: " ", 51: "\u{8}", 53: "\u{1b}",
            0: "a", 8: "c", 9: "v", 7: "x", 6: "z"
        ]
        if let ch = charMap[keyCode] {
            let uptime = ProcessInfo.processInfo.systemUptime
            let nsFlags = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue))
            if let kd = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: nsFlags,
                timestamp: uptime,
                windowNumber: wid,
                context: nil,
                characters: ch,
                charactersIgnoringModifiers: ch,
                isARepeat: false,
                keyCode: keyCode
            )?.cgEvent,
            let ku = NSEvent.keyEvent(
                with: .keyUp,
                location: .zero,
                modifierFlags: nsFlags,
                timestamp: uptime,
                windowNumber: wid,
                context: nil,
                characters: ch,
                charactersIgnoringModifiers: ch,
                isARepeat: false,
                keyCode: keyCode
            )?.cgEvent {
                kd.flags = flags
                ku.flags = flags
                kd.postToPid(pid)
                Thread.sleep(forTimeInterval: 0.025)
                ku.postToPid(pid)
                return
            }
        }
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
