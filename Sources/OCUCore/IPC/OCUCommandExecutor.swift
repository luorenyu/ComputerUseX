import Foundation

public final class OCUCommandExecutor: @unchecked Sendable {
    public static let shared = OCUCommandExecutor()

    private init() {}

    public func execute(_ request: IPCRequest, isDaemonContext: Bool = false) -> IPCResponse {
        do {
            switch request.command {
            case "status":
                let status = PermissionManager.shared.currentStatus(
                    daemonConnected: isDaemonContext || UnixSocketIPC.isDaemonReachable(),
                    socketPath: UnixSocketIPC.defaultSocketPath
                )
                return IPCResponse(id: request.id, ok: true, status: status)

            case "reset_safety":
                KillSwitchMonitor.shared.reset()
                let status = PermissionManager.shared.currentStatus(
                    daemonConnected: isDaemonContext || UnixSocketIPC.isDaemonReachable(),
                    socketPath: UnixSocketIPC.defaultSocketPath
                )
                return IPCResponse(id: request.id, ok: true, status: status)

            case "apps":
                if let appTarget = request.app, !appTarget.isEmpty {
                    if let x = request.x, let y = request.y, let w = request.width, let h = request.height {
                        let outcome = try AppWorkspaceController.shared.setFocusedWindowFrame(
                            appName: appTarget,
                            rect: ScreenRect(x: x, y: y, width: w, height: h)
                        )
                        return IPCResponse(id: request.id, ok: true, outcome: outcome)
                    }
                    let outcome = try AppWorkspaceController.shared.focusOrLaunchApp(
                        identifierOrName: appTarget,
                        launchIfNeeded: request.launch ?? true
                    )
                    return IPCResponse(id: request.id, ok: true, outcome: outcome)
                }
                let apps = AppWorkspaceController.shared.listRunningApps()
                return IPCResponse(id: request.id, ok: true, apps: apps)

            case "snapshot":
                let snap = try ElementSnapshotStore.shared.captureSnapshot(
                    appName: request.app,
                    focusFirst: request.focus ?? false,
                    windowOnly: request.windowOnly ?? true,
                    enableOCR: request.ocr ?? true,
                    enableSoM: request.som ?? false,
                    outputPath: request.outputPath,
                    includeBase64: request.som ?? false
                )
                return IPCResponse(id: request.id, ok: true, snapshot: snap)

            case "click":
                let outcome = try MouseController.shared.click(
                    target: request.target,
                    x: request.x,
                    y: request.y,
                    dx: request.dx,
                    dy: request.dy,
                    button: request.button ?? .left,
                    clickCount: request.clickCount ?? 1,
                    axNative: request.axNative ?? false,
                    virtualCursor: request.virtualCursor
                )
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "move":
                let startTime = Date()
                let destination: ScreenPoint
                let desc: String
                let offsetX = request.dx ?? 0
                let offsetY = request.dy ?? 0
                var targetPid: Int32? = nil
                var badgeLabel: String? = nil
                if let targetRef = request.target, !targetRef.isEmpty {
                    let el = try ElementSnapshotStore.shared.resolveTarget(targetRef)
                    destination = ScreenPoint(x: el.centerPoint.x + offsetX, y: el.centerPoint.y + offsetY)
                    targetPid = el.pid
                    badgeLabel = el.ref
                    if abs(offsetX) > 0.1 || abs(offsetY) > 0.1 {
                        desc = "\(el.ref) [\(el.label)] + offset(\(Int(offsetX)),\(Int(offsetY)))"
                    } else {
                        desc = "\(el.ref) [\(el.label)]"
                    }
                    KillSwitchMonitor.shared.emitHUDEvent(.highlightElement(rect: el.frame, label: el.ref))
                } else if let px = request.x, let py = request.y {
                    destination = ScreenPoint(x: px + offsetX, y: py + offsetY)
                    desc = "(\(Int(destination.x)), \(Int(destination.y)))"
                } else {
                    throw OCUError(
                        code: .invalidArguments,
                        message: "Move requires either a target (@e1) or (x, y) coordinates.",
                        recoveryHint: "Pass --target @e1 or --x 500 --y 300."
                    )
                }
                KillSwitchMonitor.shared.emitHUDEvent(.statusPill(title: "🧭 移动指针至 \(desc)", subtitle: nil))
                try MouseController.shared.moveSmoothly(
                    to: destination,
                    virtualCursor: request.virtualCursor,
                    pid: targetPid,
                    label: badgeLabel
                )
                let outcome = ActionOutcome(
                    action: "move",
                    targetDescription: desc,
                    point: destination,
                    elapsedMs: Int(Date().timeIntervalSince(startTime) * 1000)
                )
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "type":
                guard let text = request.text else {
                    throw OCUError(
                        code: .invalidArguments,
                        message: "Missing 'text' parameter for type command.",
                        recoveryHint: "Provide the text string to type."
                    )
                }
                let outcome = try KeyboardController.shared.typeText(
                    text,
                    target: request.target,
                    x: request.x,
                    y: request.y,
                    dx: request.dx,
                    dy: request.dy,
                    clearFirst: request.clearFirst ?? false,
                    submit: request.submit ?? false,
                    virtualCursor: request.virtualCursor
                )
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "batch":
                guard let steps = request.steps, !steps.isEmpty else {
                    throw OCUError(
                        code: .invalidArguments,
                        message: "Batch command requires a non-empty 'steps' array.",
                        recoveryHint: "Provide steps to execute sequentially."
                    )
                }
                let batchStart = Date()
                var outcomes: [ActionOutcome] = []
                var lastSnapshot: SnapshotResult? = nil
                for (idx, var step) in steps.enumerated() {
                    if step.virtualCursor == nil {
                        step.virtualCursor = request.virtualCursor
                    }
                    let stepResp = execute(step, isDaemonContext: isDaemonContext)
                    if !stepResp.ok {
                        return IPCResponse(
                            id: request.id,
                            ok: false,
                            snapshot: lastSnapshot,
                            batchOutcomes: outcomes,
                            error: stepResp.error
                        )
                    }
                    if let out = stepResp.outcome {
                        outcomes.append(out)
                    }
                    if let snap = stepResp.snapshot {
                        lastSnapshot = snap
                        outcomes.append(ActionOutcome(
                            action: "snapshot",
                            targetDescription: "\(snap.activeApp) (\(snap.elements.count) elements)",
                            elapsedMs: 0
                        ))
                    }
                    if idx + 1 < steps.count {
                        Thread.sleep(forTimeInterval: 0.08)
                    }
                }
                let totalMs = Int(Date().timeIntervalSince(batchStart) * 1000)
                let summary = ActionOutcome(
                    action: "batch(\(steps.count) steps)",
                    targetDescription: outcomes.map { "\($0.action):\($0.targetDescription)" }.joined(separator: " -> "),
                    point: outcomes.last?.point,
                    elapsedMs: totalMs
                )
                return IPCResponse(
                    id: request.id,
                    ok: true,
                    snapshot: lastSnapshot,
                    outcome: summary,
                    batchOutcomes: outcomes
                )

            case "press":
                guard let keys = request.keys, !keys.isEmpty else {
                    throw OCUError(
                        code: .invalidArguments,
                        message: "Missing 'keys' parameter for press command.",
                        recoveryHint: "Provide a key or shortcut like 'enter' or 'cmd+c'."
                    )
                }
                let outcome = try KeyboardController.shared.pressShortcut(keys, virtualCursor: request.virtualCursor)
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "scroll":
                let outcome = try MouseController.shared.scroll(
                    dx: request.dx ?? 0,
                    dy: request.dy ?? -240,
                    target: request.target,
                    x: request.x,
                    y: request.y
                )
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "drag":
                let startPt: ScreenPoint
                let endPt: ScreenPoint
                if let fromRef = request.target, !fromRef.isEmpty {
                    startPt = try ElementSnapshotStore.shared.resolveTarget(fromRef).centerPoint
                } else if let fx = request.x, let fy = request.y {
                    startPt = ScreenPoint(x: fx, y: fy)
                } else {
                    throw OCUError(
                        code: .invalidArguments,
                        message: "Drag requires start target (--from @e1) or (--x, --y).",
                        recoveryHint: "Specify both start and destination for drag."
                    )
                }

                if let toRef = request.toTarget, !toRef.isEmpty {
                    endPt = try ElementSnapshotStore.shared.resolveTarget(toRef).centerPoint
                } else if let tx = request.toX, let ty = request.toY {
                    endPt = ScreenPoint(x: tx, y: ty)
                } else {
                    throw OCUError(
                        code: .invalidArguments,
                        message: "Drag requires destination (--to @e2) or (--to-x, --to-y).",
                        recoveryHint: "Specify destination coordinates or element reference."
                    )
                }

                let outcome = try MouseController.shared.drag(
                    from: startPt,
                    to: endPt,
                    duration: request.timeout ?? 0.30
                )
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "wait":
                let outcome = try AppWorkspaceController.shared.waitForCondition(
                    text: request.text,
                    timeoutSeconds: request.timeout ?? 3.0
                )
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "hud_event":
                if let event = request.hudEvent {
                    KillSwitchMonitor.shared.emitHUDEvent(event)
                }
                return IPCResponse(
                    id: request.id,
                    ok: true,
                    outcome: ActionOutcome(action: "hud_event", targetDescription: "HUD overlay")
                )

            case "hud_demo":
                let outcome = try runHUDDemoShowcase()
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            default:
                throw OCUError(
                    code: .invalidArguments,
                    message: "Unknown command '\(request.command)'.",
                    recoveryHint: "Valid commands: status, apps, snapshot, click, move, type, press, scroll, drag, wait, hud_demo."
                )
            }
        } catch let ocuErr as OCUError {
            return IPCResponse(id: request.id, ok: false, error: ocuErr)
        } catch {
            let wrapped = OCUError(
                code: .actionFailed,
                message: error.localizedDescription,
                recoveryHint: "Run 'ocu doctor' to verify permissions and system health."
            )
            return IPCResponse(id: request.id, ok: false, error: wrapped)
        }
    }

    private func runHUDDemoShowcase() throws -> ActionOutcome {
        let startTime = Date()
        let bounds = PermissionManager.shared.mainScreenBounds()
        let center = bounds.center
        let p1 = ScreenPoint(x: center.x - 180, y: center.y - 90)
        let p2 = ScreenPoint(x: center.x + 180, y: center.y - 60)
        let p3 = ScreenPoint(x: center.x, y: center.y + 110)

        KillSwitchMonitor.shared.reset()
        KillSwitchMonitor.shared.emitHUDEvent(.setActiveGlow(true))
        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "✨ OpenComputerUse 视觉引擎演示", subtitle: "三次贝塞尔平滑轨迹 + 元素高亮 + 波纹反馈")
        )

        let demoBox = ScreenRect(x: p1.x - 70, y: p1.y - 22, width: 140, height: 44)
        KillSwitchMonitor.shared.emitHUDEvent(.highlightElement(rect: demoBox, label: "@e1 [演示按钮]"))
        try MouseController.shared.moveSmoothly(to: p1, duration: 0.28)
        KillSwitchMonitor.shared.emitHUDEvent(.clickRipple(point: p1, button: .left, clickCount: 1))
        Thread.sleep(forTimeInterval: 0.22)

        let demoBox2 = ScreenRect(x: p2.x - 80, y: p2.y - 22, width: 160, height: 44)
        KillSwitchMonitor.shared.emitHUDEvent(.highlightElement(rect: demoBox2, label: "@e2 [搜索输入框]"))
        try MouseController.shared.moveSmoothly(to: p2, duration: 0.28)
        KillSwitchMonitor.shared.emitHUDEvent(.clickRipple(point: p2, button: .right, clickCount: 1))
        Thread.sleep(forTimeInterval: 0.22)

        try MouseController.shared.moveSmoothly(to: p3, duration: 0.25)
        KillSwitchMonitor.shared.emitHUDEvent(.clickRipple(point: p3, button: .left, clickCount: 2))
        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "✅ HUD 视觉演示完成", subtitle: "按下 Option+Esc 可随时急停")
        )

        return ActionOutcome(
            action: "hud_demo",
            targetDescription: "Visual HUD Trajectory & Ripple Showcase",
            point: p3,
            elapsedMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
    }
}
