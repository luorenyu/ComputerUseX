import Foundation
import CoreGraphics
import AppKit

public final class MouseController: @unchecked Sendable {
    public static let shared = MouseController()

    /// When enabled (default), OCU uses its own independent persistent Virtual Cursor window and
    /// `SyntheticFocusEnforcer` (`CGEventPostToPid`) instead of hijacking the user's physical mouse.
    public var useVirtualCursorByDefault: Bool = true

    private let stateLock = NSLock()
    private var virtualCursorLocation: ScreenPoint? = nil
    private var lastTargetPid: Int32? = nil
    private var lastTargetWindowID: UInt32? = nil
    private var lastTargetWindowBounds: ScreenRect? = nil

    private init() {}

    public var currentVirtualOrPhysicalLocation: ScreenPoint {
        stateLock.lock()
        defer { stateLock.unlock() }
        return virtualCursorLocation ?? PermissionManager.shared.currentMouseLocation()
    }

    public var lastResolvedTargetContext: (pid: Int32, windowID: UInt32, bounds: ScreenRect)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let pid = lastTargetPid, let wid = lastTargetWindowID, let b = lastTargetWindowBounds {
            return (pid, wid, b)
        }
        return nil
    }

    private func resolveEffectivePreferredTarget(
        at point: ScreenPoint,
        explicitPid: Int32? = nil,
        explicitApp: String? = nil
    ) -> (pid: Int32?, appName: String?) {
        if explicitPid != nil || (explicitApp != nil && !explicitApp!.isEmpty) {
            return (explicitPid, explicitApp)
        }
        if let snap = ElementSnapshotStore.shared.currentSnapshot(),
           snap.activePid > 0,
           snap.screenBounds.contains(point) {
            return (snap.activePid, snap.activeApp)
        }
        stateLock.lock()
        let savedPid = lastTargetPid
        let savedBounds = lastTargetWindowBounds
        stateLock.unlock()
        if let pid = savedPid, let bounds = savedBounds, bounds.contains(point) {
            return (pid, nil)
        }
        return (nil, nil)
    }

    public func moveSmoothly(
        to destination: ScreenPoint,
        duration: TimeInterval = 0.18,
        virtualCursor: Bool? = nil,
        windowID: UInt32? = nil,
        pid: Int32? = nil,
        label: String? = nil
    ) throws {
        let isVirtual = virtualCursor ?? useVirtualCursorByDefault
        if isVirtual {
            try KillSwitchMonitor.shared.verifySafeToProceed()
            let start = currentVirtualOrPhysicalLocation
            let pref = resolveEffectivePreferredTarget(at: destination, explicitPid: pid)
            let resolvedWin = SyntheticFocusEnforcer.shared.resolveTargetWindow(
                at: destination,
                preferredPid: pref.pid,
                preferredAppName: pref.appName
            )
            let effWinID = windowID ?? resolvedWin?.windowID
            let effPid = pref.pid ?? resolvedWin?.pid
            let distance = start.distance(to: destination)

            stateLock.lock()
            if let rw = resolvedWin {
                lastTargetPid = rw.pid
                lastTargetWindowID = rw.windowID
                lastTargetWindowBounds = rw.bounds
            }
            stateLock.unlock()

            if let rw = resolvedWin {
                KillSwitchMonitor.shared.emitHUDEvent(
                    .pipTargetWindow(
                        pid: rw.pid,
                        windowID: rw.windowID,
                        appName: rw.appName,
                        windowTitle: nil,
                        windowBounds: rw.bounds
                    )
                )
            }

            if distance < 2.0 {
                KillSwitchMonitor.shared.emitHUDEvent(
                    .virtualCursorMove(point: destination, windowID: effWinID, pid: effPid, tiltAngle: 0.0, label: label)
                )
                stateLock.lock()
                virtualCursorLocation = destination
                stateLock.unlock()
                return
            }

            let steps = max(8, min(24, Int(distance / 36.0) + 8))
            let points = CubicBezierTrajectory.sample(from: start, to: destination, steps: steps)
            let stepInterval = max(0.006, duration / Double(points.count))

            KillSwitchMonitor.shared.emitHUDEvent(.setActiveGlow(true))

            var prev = start
            for pt in points {
                try KillSwitchMonitor.shared.verifySafeToProceed()
                let vx = pt.x - prev.x
                let tilt = max(-18.0, min(18.0, vx * 0.45))
                KillSwitchMonitor.shared.emitHUDEvent(
                    .virtualCursorMove(point: pt, windowID: effWinID, pid: effPid, tiltAngle: tilt, label: nil)
                )
                prev = pt
                Thread.sleep(forTimeInterval: stepInterval)
            }

            KillSwitchMonitor.shared.emitHUDEvent(
                .virtualCursorMove(point: destination, windowID: effWinID, pid: effPid, tiltAngle: 0.0, label: nil)
            )
            stateLock.lock()
            virtualCursorLocation = destination
            stateLock.unlock()
            return
        }

        KillSwitchMonitor.shared.clearAgentMouseTracking()
        try KillSwitchMonitor.shared.verifySafeToProceed()
        let start = PermissionManager.shared.currentMouseLocation()
        let distance = start.distance(to: destination)

        if distance < 2.0 {
            postMouseMove(to: destination)
            KillSwitchMonitor.shared.recordAgentMousePosition(destination)
            return
        }

        let steps = max(6, min(24, Int(distance / 40.0) + 6))
        let points = CubicBezierTrajectory.sample(from: start, to: destination, steps: steps)
        let stepInterval = max(0.005, duration / Double(points.count))

        KillSwitchMonitor.shared.emitHUDEvent(.setActiveGlow(true))

        for pt in points {
            try KillSwitchMonitor.shared.verifySafeToProceed()
            postMouseMove(to: pt)
            KillSwitchMonitor.shared.recordAgentMousePosition(pt)
            Thread.sleep(forTimeInterval: stepInterval)
        }
    }

    public func click(
        target: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        dx: Double? = nil,
        dy: Double? = nil,
        button: MouseButton = .left,
        clickCount: Int = 1,
        axNative: Bool = false,
        virtualCursor: Bool? = nil
    ) throws -> ActionOutcome {
        let startTime = Date()
        let isVirtual = virtualCursor ?? useVirtualCursorByDefault
        if isVirtual {
            try KillSwitchMonitor.shared.verifySafeToProceed()
        } else {
            try KillSwitchMonitor.shared.verifySafeToProceed()
        }

        var resolvedElement: UIElementRef? = nil
        let targetPoint: ScreenPoint
        let targetDesc: String
        let offsetX = dx ?? 0
        let offsetY = dy ?? 0
        let hasOffset = (abs(offsetX) > 0.1 || abs(offsetY) > 0.1)

        if let targetRef = target, !targetRef.isEmpty {
            let el = try ElementSnapshotStore.shared.resolveTarget(targetRef)
            try KillSwitchMonitor.shared.verifyAppAllowed(el.appName)
            resolvedElement = el
            targetPoint = ScreenPoint(x: el.centerPoint.x + offsetX, y: el.centerPoint.y + offsetY)
            if hasOffset {
                targetDesc = "\(el.ref) [\(el.role): \(el.label)] + offset(\(Int(offsetX)),\(Int(offsetY)))"
            } else {
                targetDesc = "\(el.ref) [\(el.role): \(el.label)]"
            }
        } else if let px = x, let py = y {
            targetPoint = ScreenPoint(x: px + offsetX, y: py + offsetY)
            targetDesc = "(\(Int(targetPoint.x)), \(Int(targetPoint.y)))"
        } else {
            let current = isVirtual ? currentVirtualOrPhysicalLocation : PermissionManager.shared.currentMouseLocation()
            targetPoint = ScreenPoint(x: current.x + offsetX, y: current.y + offsetY)
            targetDesc = "current (\(Int(targetPoint.x)), \(Int(targetPoint.y)))"
        }

        let pref = resolveEffectivePreferredTarget(
            at: targetPoint,
            explicitPid: resolvedElement?.pid,
            explicitApp: resolvedElement?.appName
        )
        let winContext = SyntheticFocusEnforcer.shared.resolveTargetWindow(
            at: targetPoint,
            preferredPid: pref.pid,
            preferredAppName: pref.appName
        )
        if let wc = winContext {
            stateLock.lock()
            lastTargetPid = wc.pid
            lastTargetWindowID = wc.windowID
            lastTargetWindowBounds = wc.bounds
            stateLock.unlock()

            KillSwitchMonitor.shared.emitHUDEvent(
                .pipTargetWindow(
                    pid: wc.pid,
                    windowID: wc.windowID,
                    appName: wc.appName,
                    windowTitle: nil,
                    windowBounds: wc.bounds
                )
            )
        }

        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(
                title: "🖱️ \(isVirtual ? "[虚拟指针]" : "") 点击 \(targetDesc)",
                subtitle: "\(button.rawValue) ×\(clickCount)"
            )
        )

        // Step 1: Always glide the cursor to the destination FIRST so visual perception matches action timing
        try moveSmoothly(
            to: targetPoint,
            duration: 0.18,
            virtualCursor: isVirtual,
            windowID: winContext?.windowID,
            pid: winContext?.pid,
            label: nil
        )

        // Step 2: Brief settle pause (65ms) so the cursor visually lands on the target before pressing
        Thread.sleep(forTimeInterval: 0.065)

        if let el = resolvedElement {
            KillSwitchMonitor.shared.emitHUDEvent(
                .highlightElement(rect: el.frame, label: el.label)
            )
        }

        // Step 3: Trigger press visual feedback + click ripple at the exact landed position
        if isVirtual, let wc = winContext {
            KillSwitchMonitor.shared.emitHUDEvent(
                .virtualCursorPress(point: targetPoint, windowID: wc.windowID, isPressed: true)
            )
        }
        KillSwitchMonitor.shared.emitHUDEvent(
            .clickRipple(point: targetPoint, button: button, clickCount: clickCount)
        )

        let isBackgroundWindow: Bool = {
            guard let wc = winContext else { return false }
            return !SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(windowID: wc.windowID, pid: wc.pid)
        }()

        // Step 4: Execute the actual click after the cursor has landed and pressed
        if (axNative || (isVirtual && isBackgroundWindow)) && !hasOffset,
           let el = resolvedElement,
           el.source == .ax,
           button == .left,
           clickCount == 1 {
            if AXScanner.shared.performNativePress(ref: el.ref) {
                if isVirtual, let wc = winContext {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.14) {
                        KillSwitchMonitor.shared.emitHUDEvent(
                            .virtualCursorPress(point: targetPoint, windowID: wc.windowID, isPressed: false)
                        )
                    }
                }
                let ms = Int(Date().timeIntervalSince(startTime) * 1000)
                KillSwitchMonitor.shared.logAction("🖱️ AXPress \(targetDesc)")
                return ActionOutcome(
                    action: "click(ax-native)",
                    targetDescription: targetDesc,
                    point: targetPoint,
                    details: "Triggered native kAXPressAction (background=\(isBackgroundWindow))",
                    elapsedMs: ms
                )
            }
        }

        if isVirtual, let wc = winContext {
            SyntheticFocusEnforcer.shared.performBackgroundClick(
                at: targetPoint,
                button: button,
                clickCount: clickCount,
                pid: wc.pid,
                windowID: wc.windowID,
                windowBounds: wc.bounds
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.14) {
                KillSwitchMonitor.shared.emitHUDEvent(
                    .virtualCursorPress(point: targetPoint, windowID: wc.windowID, isPressed: false)
                )
            }
            let ms = Int(Date().timeIntervalSince(startTime) * 1000)
            KillSwitchMonitor.shared.logAction("🖱️ [Virtual] Clicked \(targetDesc) -> PID \(wc.pid) Win #\(wc.windowID)")
            return ActionOutcome(
                action: "click(virtual)",
                targetDescription: targetDesc,
                point: targetPoint,
                details: "mode=virtual, pid=\(wc.pid), windowID=\(wc.windowID), button=\(button.rawValue), count=\(clickCount)",
                elapsedMs: ms
            )
        }

        let cgPoint = targetPoint.cgPoint
        let (downType, upType, cgButton) = mouseEventTypes(for: button)

        for i in 1...max(1, clickCount) {
            try KillSwitchMonitor.shared.verifySafeToProceed()
            if let downEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: downType,
                mouseCursorPosition: cgPoint,
                mouseButton: cgButton
            ), let upEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: upType,
                mouseCursorPosition: cgPoint,
                mouseButton: cgButton
            ) {
                downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(i))
                downEvent.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.025)
                upEvent.post(tap: .cghidEventTap)
                if i < clickCount {
                    Thread.sleep(forTimeInterval: 0.04)
                }
            }
        }

        KillSwitchMonitor.shared.recordAgentMousePosition(targetPoint)
        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        KillSwitchMonitor.shared.logAction("🖱️ Clicked \(targetDesc)")
        return ActionOutcome(
            action: "click",
            targetDescription: targetDesc,
            point: targetPoint,
            details: "button=\(button.rawValue), count=\(clickCount)",
            elapsedMs: ms
        )
    }

    public func drag(
        from startPoint: ScreenPoint,
        to endPoint: ScreenPoint,
        duration: TimeInterval = 0.30
    ) throws -> ActionOutcome {
        let startTime = Date()
        try KillSwitchMonitor.shared.verifySafeToProceed()

        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(
                title: "✊ 拖拽操作",
                subtitle: "(\(Int(startPoint.x)),\(Int(startPoint.y))) → (\(Int(endPoint.x)),\(Int(endPoint.y)))"
            )
        )

        try moveSmoothly(to: startPoint, duration: 0.14)
        Thread.sleep(forTimeInterval: 0.05)
        KillSwitchMonitor.shared.emitHUDEvent(.clickRipple(point: startPoint, button: .left, clickCount: 1))

        // Background window title-bar drag fast-path: if dragging a background window's titlebar, move via kAXPositionAttribute!
        if let rw = SyntheticFocusEnforcer.shared.resolveTargetWindow(at: startPoint, preferredPid: lastTargetPid),
           !SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(windowID: rw.windowID, pid: rw.pid),
           startPoint.y >= rw.bounds.y && (startPoint.y - rw.bounds.y) <= 40.0 {
            let deltaX = endPoint.x - startPoint.x
            let deltaY = endPoint.y - startPoint.y
            let newOrigin = ScreenPoint(x: rw.bounds.x + deltaX, y: rw.bounds.y + deltaY)
            if AXScanner.shared.moveWindowBackground(pid: rw.pid, windowID: rw.windowID, to: newOrigin) {
                try moveSmoothly(to: endPoint, duration: duration)
                KillSwitchMonitor.shared.emitHUDEvent(.clickRipple(point: endPoint, button: .left, clickCount: 1))
                let ms = Int(Date().timeIntervalSince(startTime) * 1000)
                let desc = "(\(Int(startPoint.x)),\(Int(startPoint.y))) -> (\(Int(endPoint.x)),\(Int(endPoint.y)))"
                return ActionOutcome(
                    action: "drag",
                    targetDescription: desc,
                    point: endPoint,
                    details: "method=ax-window-move, winID=\(rw.windowID)",
                    elapsedMs: ms
                )
            }
        }

        let gestureEventNumber = Int64(CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown)) + 1

        guard let downEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: startPoint.cgPoint,
            mouseButton: .left
        ) else {
            throw OCUError(
                code: .actionFailed,
                message: "Could not create mouse down event for drag.",
                recoveryHint: "Verify Accessibility permission is enabled."
            )
        }
        downEvent.setIntegerValueField(.mouseEventNumber, value: gestureEventNumber)
        downEvent.post(tap: .cghidEventTap)
        KillSwitchMonitor.shared.recordAgentMousePosition(startPoint)
        Thread.sleep(forTimeInterval: 0.06)

        let points = CubicBezierTrajectory.sample(from: startPoint, to: endPoint, steps: 20, curvature: 0.04)
        let stepInterval = max(0.006, duration / Double(points.count))

        var prevPt = startPoint
        for pt in points {
            try KillSwitchMonitor.shared.verifySafeToProceed()
            let dx = pt.x - prevPt.x
            let dy = pt.y - prevPt.y
            if let dragEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: pt.cgPoint,
                mouseButton: .left
            ) {
                dragEvent.setIntegerValueField(.mouseEventNumber, value: gestureEventNumber)
                dragEvent.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
                dragEvent.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
                dragEvent.setDoubleValueField(.mouseEventDeltaX, value: dx)
                dragEvent.setDoubleValueField(.mouseEventDeltaY, value: dy)
                dragEvent.post(tap: .cghidEventTap)
                KillSwitchMonitor.shared.recordAgentMousePosition(pt)
                KillSwitchMonitor.shared.emitHUDEvent(
                    .virtualCursorMove(point: pt, windowID: lastTargetWindowID, pid: lastTargetPid, tiltAngle: 0.0, label: nil)
                )
            }
            prevPt = pt
            Thread.sleep(forTimeInterval: stepInterval)
        }

        if let upEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: endPoint.cgPoint,
            mouseButton: .left
        ) {
            upEvent.setIntegerValueField(.mouseEventNumber, value: gestureEventNumber)
            upEvent.post(tap: .cghidEventTap)
        }
        KillSwitchMonitor.shared.emitHUDEvent(.clickRipple(point: endPoint, button: .left, clickCount: 1))

        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        let desc = "(\(Int(startPoint.x)),\(Int(startPoint.y))) -> (\(Int(endPoint.x)),\(Int(endPoint.y)))"
        KillSwitchMonitor.shared.logAction("✊ Dragged \(desc)")
        return ActionOutcome(
            action: "drag",
            targetDescription: desc,
            point: endPoint,
            details: "method=hid-delta-drag",
            elapsedMs: ms
        )
    }

    public func scroll(
        dx: Double = 0,
        dy: Double,
        target: String? = nil,
        x: Double? = nil,
        y: Double? = nil
    ) throws -> ActionOutcome {
        let startTime = Date()
        try KillSwitchMonitor.shared.verifySafeToProceed()

        var targetPoint: ScreenPoint? = nil
        var preferredPid: Int32? = nil
        var preferredApp: String? = nil
        if let targetRef = target, !targetRef.isEmpty {
            let el = try ElementSnapshotStore.shared.resolveTarget(targetRef)
            targetPoint = el.centerPoint
            preferredPid = el.pid
            preferredApp = el.appName
        } else if let px = x, let py = y {
            targetPoint = ScreenPoint(x: px, y: py)
        }

        let scrollPoint = targetPoint ?? currentVirtualOrPhysicalLocation
        let pref = resolveEffectivePreferredTarget(
            at: scrollPoint,
            explicitPid: preferredPid,
            explicitApp: preferredApp
        )
        let winContext = SyntheticFocusEnforcer.shared.resolveTargetWindow(
            at: scrollPoint,
            preferredPid: pref.pid,
            preferredAppName: pref.appName
        )

        if let pt = targetPoint {
            try moveSmoothly(to: pt, duration: 0.14, windowID: winContext?.windowID, pid: winContext?.pid)
            Thread.sleep(forTimeInterval: 0.05)
        }

        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "🛞 滚动视图", subtitle: "dx=\(Int(dx)), dy=\(Int(dy))")
        )

        let steps = 8
        let stepDx = Int32((dx / Double(steps)).rounded())
        let stepDy = Int32((dy / Double(steps)).rounded())
        let savedMousePos = PermissionManager.shared.currentMouseLocation().cgPoint
        let scrollLoc = scrollPoint.cgPoint

        let isBackgroundWindow: Bool = {
            guard let wc = winContext else { return false }
            return !SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(windowID: wc.windowID, pid: wc.pid)
        }()

        for _ in 0..<steps {
            try KillSwitchMonitor.shared.verifySafeToProceed()
            if useVirtualCursorByDefault, isBackgroundWindow, let wc = winContext {
                SyntheticFocusEnforcer.shared.postSynthesizedScrollEvent(
                    at: scrollPoint,
                    dx: stepDx,
                    dy: stepDy,
                    pid: wc.pid,
                    windowID: wc.windowID,
                    windowBounds: wc.bounds
                )
            } else if let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: stepDy,
                wheel2: stepDx,
                wheel3: 0
            ) {
                scrollEvent.location = scrollLoc
                scrollEvent.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.014)
        }
        if useVirtualCursorByDefault && !isBackgroundWindow {
            CGWarpMouseCursorPosition(savedMousePos)
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        let loc = targetPoint ?? PermissionManager.shared.currentMouseLocation()
        KillSwitchMonitor.shared.logAction("🛞 Scrolled dx=\(Int(dx)), dy=\(Int(dy))")
        return ActionOutcome(
            action: "scroll",
            targetDescription: "dx=\(Int(dx)), dy=\(Int(dy))",
            point: loc,
            elapsedMs: ms
        )
    }

    private func postMouseMove(to point: ScreenPoint) {
        CGWarpMouseCursorPosition(point.cgPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
        if let moveEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point.cgPoint,
            mouseButton: .left
        ) {
            moveEvent.post(tap: .cghidEventTap)
        }
    }

    private func mouseEventTypes(for button: MouseButton) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button {
        case .left:
            return (.leftMouseDown, .leftMouseUp, .left)
        case .right:
            return (.rightMouseDown, .rightMouseUp, .right)
        case .center:
            return (.otherMouseDown, .otherMouseUp, .center)
        }
    }
}
