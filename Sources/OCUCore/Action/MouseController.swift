import Foundation
import CoreGraphics
import AppKit

public final class MouseController: @unchecked Sendable {
    public static let shared = MouseController()

    private init() {}

    public func moveSmoothly(
        to destination: ScreenPoint,
        duration: TimeInterval = 0.18
    ) throws {
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
        KillSwitchMonitor.shared.emitHUDEvent(.pointerTrail(points: [start] + points))

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
        button: MouseButton = .left,
        clickCount: Int = 1,
        axNative: Bool = false
    ) throws -> ActionOutcome {
        let startTime = Date()
        try KillSwitchMonitor.shared.verifySafeToProceed()

        var resolvedElement: UIElementRef? = nil
        let targetPoint: ScreenPoint
        let targetDesc: String

        if let targetRef = target, !targetRef.isEmpty {
            let el = try ElementSnapshotStore.shared.resolveTarget(targetRef)
            try KillSwitchMonitor.shared.verifyAppAllowed(el.appName)
            resolvedElement = el
            targetPoint = el.centerPoint
            targetDesc = "\(el.ref) [\(el.role): \(el.label)]"
        } else if let px = x, let py = y {
            targetPoint = ScreenPoint(x: px, y: py)
            targetDesc = "(\(Int(px)), \(Int(py)))"
        } else {
            targetPoint = PermissionManager.shared.currentMouseLocation()
            targetDesc = "current (\(Int(targetPoint.x)), \(Int(targetPoint.y)))"
        }

        if let el = resolvedElement {
            KillSwitchMonitor.shared.emitHUDEvent(
                .highlightElement(rect: el.frame, label: "\(el.ref) \(el.label)")
            )
        }

        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(
                title: "🖱️ 点击 \(targetDesc)",
                subtitle: "\(button.rawValue) ×\(clickCount)"
            )
        )

        // Optional silent AXPress mode if requested and element supports it
        if axNative, let el = resolvedElement, button == .left, clickCount == 1 {
            if AXScanner.shared.performNativePress(ref: el.ref) {
                KillSwitchMonitor.shared.emitHUDEvent(
                    .clickRipple(point: targetPoint, button: button, clickCount: clickCount)
                )
                let ms = Int(Date().timeIntervalSince(startTime) * 1000)
                KillSwitchMonitor.shared.logAction("🖱️ AXPress \(targetDesc)")
                return ActionOutcome(
                    action: "click(ax-native)",
                    targetDescription: targetDesc,
                    point: targetPoint,
                    details: "Triggered native kAXPressAction",
                    elapsedMs: ms
                )
            }
        }

        try moveSmoothly(to: targetPoint)
        KillSwitchMonitor.shared.emitHUDEvent(
            .clickRipple(point: targetPoint, button: button, clickCount: clickCount)
        )

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
        KillSwitchMonitor.shared.emitHUDEvent(.clickRipple(point: startPoint, button: .left, clickCount: 1))

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
        downEvent.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.04)

        let points = CubicBezierTrajectory.sample(from: startPoint, to: endPoint, steps: 20, curvature: 0.06)
        KillSwitchMonitor.shared.emitHUDEvent(.pointerTrail(points: [startPoint] + points))
        let stepInterval = max(0.006, duration / Double(points.count))

        for pt in points {
            try KillSwitchMonitor.shared.verifySafeToProceed()
            if let dragEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDragged,
                mouseCursorPosition: pt.cgPoint,
                mouseButton: .left
            ) {
                dragEvent.post(tap: .cghidEventTap)
                KillSwitchMonitor.shared.recordAgentMousePosition(pt)
            }
            Thread.sleep(forTimeInterval: stepInterval)
        }

        if let upEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: endPoint.cgPoint,
            mouseButton: .left
        ) {
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
        if let targetRef = target, !targetRef.isEmpty {
            let el = try ElementSnapshotStore.shared.resolveTarget(targetRef)
            targetPoint = el.centerPoint
        } else if let px = x, let py = y {
            targetPoint = ScreenPoint(x: px, y: py)
        }

        if let pt = targetPoint {
            try moveSmoothly(to: pt, duration: 0.12)
        }

        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "🛞 滚动视图", subtitle: "dx=\(Int(dx)), dy=\(Int(dy))")
        )

        let steps = 8
        let stepDx = Int32((dx / Double(steps)).rounded())
        let stepDy = Int32((dy / Double(steps)).rounded())

        for _ in 0..<steps {
            try KillSwitchMonitor.shared.verifySafeToProceed()
            if let scrollEvent = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: stepDy,
                wheel2: stepDx,
                wheel3: 0
            ) {
                scrollEvent.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 0.014)
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
