import Foundation

public final class OCUCommandExecutor: @unchecked Sendable {
    public static let shared = OCUCommandExecutor()

    private init() {}

    public func execute(_ request: IPCRequest, isDaemonContext: Bool = false) -> IPCResponse {
        let startTime = Date()
        let response = executeCore(request, isDaemonContext: isDaemonContext)
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        if response.ok {
            SessionBillingManager.shared.recordCommandUsage(
                request: request,
                response: response,
                elapsedMs: elapsedMs
            )
        }
        return response
    }

    private func executeCore(_ request: IPCRequest, isDaemonContext: Bool = false) -> IPCResponse {
        do {
            switch request.command {
            case "status":
                var status = PermissionManager.shared.currentStatus(
                    daemonConnected: isDaemonContext || UnixSocketIPC.isDaemonReachable(),
                    socketPath: UnixSocketIPC.defaultSocketPath
                )
                status.screenLocked = VirtualDisplayManager.shared.isScreenLocked()
                status.activeOperator = SessionBillingManager.shared.detectCurrentOperator(
                    explicitAgent: request.agentName,
                    explicitModel: request.modelName
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
                    preferredWindowID: request.windowID,
                    windowTitleFilter: request.windowTitle,
                    focusFirst: request.focus ?? false,
                    windowOnly: request.windowOnly ?? true,
                    enableOCR: request.ocr ?? true,
                    enableSoM: request.som ?? false,
                    dedupImage: request.dedupImage ?? true,
                    outputPath: request.outputPath,
                    includeBase64: request.som ?? false
                )
                AuditAndSecurityGuard.shared.recordAudit(AuditRecord(
                    command: "snapshot",
                    app: snap.activeApp,
                    windowID: snap.windowID,
                    success: true,
                    details: "elements=\(snap.elements.count)",
                    elapsedMs: 0
                ))
                return IPCResponse(id: request.id, ok: true, snapshot: snap)

            case "query":
                let snap = try ElementSnapshotStore.shared.queryElements(
                    appName: request.app,
                    preferredWindowID: request.windowID,
                    windowTitleFilter: request.windowTitle,
                    textQuery: request.text ?? request.target,
                    roleFilter: request.role,
                    enableOCR: request.ocr ?? false
                )
                AuditAndSecurityGuard.shared.recordAudit(AuditRecord(
                    command: "query",
                    app: snap.activeApp,
                    windowID: snap.windowID,
                    target: request.text ?? request.target,
                    success: true,
                    details: "matched=\(snap.elements.count)",
                    elapsedMs: 0
                ))
                return IPCResponse(id: request.id, ok: true, snapshot: snap)

            case "click":
                var outcome = try MouseController.shared.click(
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
                if let diff = ElementSnapshotStore.shared.computePostActionDiff() {
                    outcome.details = [outcome.details, diff].compactMap { $0 }.joined(separator: " | ")
                }
                AuditAndSecurityGuard.shared.recordAudit(AuditRecord(
                    command: "click",
                    target: outcome.targetDescription,
                    point: outcome.point,
                    success: true,
                    details: outcome.details,
                    elapsedMs: outcome.elapsedMs
                ))
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
                var outcome = try KeyboardController.shared.typeText(
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
                if let diff = ElementSnapshotStore.shared.computePostActionDiff() {
                    outcome.details = [outcome.details, diff].compactMap { $0 }.joined(separator: " | ")
                }
                AuditAndSecurityGuard.shared.recordAudit(AuditRecord(
                    command: "type",
                    target: outcome.targetDescription,
                    point: outcome.point,
                    success: true,
                    details: outcome.details,
                    elapsedMs: outcome.elapsedMs
                ))
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
                    if step.agentName == nil {
                        step.agentName = request.agentName
                    }
                    if step.modelName == nil {
                        step.modelName = request.modelName
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
                var outcome = try KeyboardController.shared.pressShortcut(keys, virtualCursor: request.virtualCursor)
                if let diff = ElementSnapshotStore.shared.computePostActionDiff() {
                    outcome.details = [outcome.details, diff].compactMap { $0 }.joined(separator: " | ")
                }
                AuditAndSecurityGuard.shared.recordAudit(AuditRecord(
                    command: "press",
                    target: keys,
                    success: true,
                    details: outcome.details,
                    elapsedMs: outcome.elapsedMs
                ))
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "scroll":
                var outcome = try MouseController.shared.scroll(
                    dx: request.dx ?? 0,
                    dy: request.dy ?? -240,
                    target: request.target,
                    x: request.x,
                    y: request.y
                )
                if let diff = ElementSnapshotStore.shared.computePostActionDiff() {
                    outcome.details = [outcome.details, diff].compactMap { $0 }.joined(separator: " | ")
                }
                AuditAndSecurityGuard.shared.recordAudit(AuditRecord(
                    command: "scroll",
                    target: outcome.targetDescription,
                    point: outcome.point,
                    success: true,
                    details: outcome.details,
                    elapsedMs: outcome.elapsedMs
                ))
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
                AuditAndSecurityGuard.shared.recordAudit(AuditRecord(
                    command: "drag",
                    target: outcome.targetDescription,
                    point: outcome.point,
                    success: true,
                    details: outcome.details,
                    elapsedMs: outcome.elapsedMs
                ))
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "upload_file", "upload-file":
                guard let path = request.outputPath ?? request.text ?? request.target, !path.isEmpty else {
                    throw OCUError(
                        code: .invalidArguments,
                        message: "upload-file requires a file path (--path <file>).",
                        recoveryHint: "Pass --path /absolute/path/to/file."
                    )
                }
                let outcome = try AppWorkspaceController.shared.uploadFileInOpenPanel(
                    filePath: path,
                    appName: request.app
                )
                AuditAndSecurityGuard.shared.recordAudit(AuditRecord(
                    command: "upload_file",
                    app: request.app,
                    target: path,
                    success: true,
                    details: outcome.details,
                    elapsedMs: outcome.elapsedMs
                ))
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "secondary_action", "secondary-action":
                guard let targetRef = request.target, !targetRef.isEmpty else {
                    throw OCUError(
                        code: .invalidArguments,
                        message: "secondary-action requires a target element (@e1).",
                        recoveryHint: "Pass --target @e1 --action AXShowMenu."
                    )
                }
                let el = try ElementSnapshotStore.shared.resolveTarget(targetRef)
                let actionName = request.text ?? "AXShowMenu"
                let ok = AXScanner.shared.performSecondaryAction(ref: el.ref, actionName: actionName)
                guard ok else {
                    throw OCUError(
                        code: .actionFailed,
                        message: "Secondary action '\(actionName)' failed on \(el.ref) [\(el.label)].",
                        recoveryHint: "Try right-clicking via 'ocu click --target \(el.ref) --right'."
                    )
                }
                let outcome = ActionOutcome(
                    action: "secondary_action",
                    targetDescription: "\(el.ref) [\(el.label)]",
                    point: el.centerPoint,
                    details: "action=\(actionName)",
                    elapsedMs: 12
                )
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "install_mcp", "install-mcp":
                let outcome = try AuditAndSecurityGuard.shared.installMCPConfiguration(
                    target: request.target ?? "all",
                    binaryPath: request.outputPath
                )
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "audit":
                let records = AuditAndSecurityGuard.shared.recentAuditRecords(limit: request.clickCount ?? 20)
                let lines = records.map { rec in
                    "[\(rec.timestamp)] \(rec.command) | target=\(rec.target ?? rec.app ?? "-") | ok=\(rec.success) | \(rec.details ?? "") (\(rec.elapsedMs)ms)"
                }
                let outcome = ActionOutcome(
                    action: "audit",
                    targetDescription: "\(records.count) recent audit records (\(AuditAndSecurityGuard.shared.auditFileURL.path))",
                    details: lines.joined(separator: "\n"),
                    elapsedMs: 2
                )
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "allow_app", "allow-app":
                guard let appName = request.app ?? request.target ?? request.text, !appName.isEmpty else {
                    throw OCUError(
                        code: .invalidArguments,
                        message: "allow-app requires an application name.",
                        recoveryHint: "Pass --app <AppName>."
                    )
                }
                let outcome = AuditAndSecurityGuard.shared.updateAppPermission(appName: appName, allow: true)
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "block_app", "block-app":
                guard let appName = request.app ?? request.target ?? request.text, !appName.isEmpty else {
                    throw OCUError(
                        code: .invalidArguments,
                        message: "block-app requires an application name.",
                        recoveryHint: "Pass --app <AppName>."
                    )
                }
                let outcome = AuditAndSecurityGuard.shared.updateAppPermission(appName: appName, allow: false)
                return IPCResponse(id: request.id, ok: true, outcome: outcome)

            case "browser":
                let subAction = (request.role ?? "tabs").lowercased()
                switch subAction {
                case "tabs", "list":
                    let tabs = try BrowserBridgeController.shared.listTabs(browser: request.app)
                    let summaryLines = tabs.map { t in
                        "\(t.isActive ? "★" : " ") [Win \(t.windowIndex) Tab \(t.tabIndex)] \(t.title) — \(t.url)"
                    }
                    let out = ActionOutcome(
                        action: "browser_tabs",
                        targetDescription: "\(tabs.count) open tab(s) in \(BrowserBridgeController.shared.resolveBrowserAppName(preferred: request.app))",
                        details: summaryLines.joined(separator: "\n"),
                        elapsedMs: 15
                    )
                    return IPCResponse(id: request.id, ok: true, outcome: out, browserTabs: tabs)
                case "navigate", "open":
                    guard let url = request.text ?? request.target, !url.isEmpty else {
                        throw OCUError(code: .invalidArguments, message: "browser navigate requires a URL.", recoveryHint: "Pass --url https://example.com")
                    }
                    let out = try BrowserBridgeController.shared.navigateURL(url, browser: request.app, newTab: request.launch ?? false)
                    return IPCResponse(id: request.id, ok: true, outcome: out)
                case "eval", "js":
                    guard let js = request.text ?? request.target, !js.isEmpty else {
                        throw OCUError(code: .invalidArguments, message: "browser eval requires JavaScript code.", recoveryHint: "Pass --eval 'document.title'")
                    }
                    let out = try BrowserBridgeController.shared.evaluateJavaScript(js, browser: request.app, tabFilter: request.windowTitle)
                    return IPCResponse(id: request.id, ok: true, outcome: out)
                case "click":
                    guard let sel = request.target ?? request.text, !sel.isEmpty else {
                        throw OCUError(code: .invalidArguments, message: "browser click requires a CSS selector or text.", recoveryHint: "Pass --selector 'button.submit'")
                    }
                    let out = try BrowserBridgeController.shared.clickDOMSelector(sel, browser: request.app, tabFilter: request.windowTitle)
                    return IPCResponse(id: request.id, ok: true, outcome: out)
                case "dom", "snapshot":
                    let out = try BrowserBridgeController.shared.extractDOMSummary(browser: request.app, tabFilter: request.windowTitle)
                    return IPCResponse(id: request.id, ok: true, outcome: out)
                default:
                    let tabs = try BrowserBridgeController.shared.listTabs(browser: request.app)
                    return IPCResponse(id: request.id, ok: true, browserTabs: tabs)
                }

            case "sandbox":
                let mode = (request.role ?? "status").lowercased()
                if mode == "park", let appName = request.app ?? request.target, !appName.isEmpty {
                    let out = try VirtualDisplayManager.shared.parkWindowInGhostSandbox(appName: appName)
                    return IPCResponse(id: request.id, ok: true, outcome: out)
                } else if mode == "restore" {
                    let out = VirtualDisplayManager.shared.restoreParkedWindows(appName: request.app ?? request.target)
                    return IPCResponse(id: request.id, ok: true, outcome: out)
                } else {
                    let locked = VirtualDisplayManager.shared.isScreenLocked()
                    let cgVirt = VirtualDisplayManager.shared.isCGVirtualDisplayRuntimeAvailable()
                    let parked = VirtualDisplayManager.shared.currentParkedWindows()
                    let out = ActionOutcome(
                        action: "sandbox_status",
                        targetDescription: "ScreenLocked=\(locked) | CGVirtualDisplayAvailable=\(cgVirt) | ParkedWindows=\(parked.count)",
                        details: parked.map { "\($0.appName) (#\($0.windowID))" }.joined(separator: ", "),
                        elapsedMs: 1
                    )
                    return IPCResponse(id: request.id, ok: true, outcome: out)
                }

            case "bill", "bills", "session_finish":
                if request.submit == true || request.command == "session_finish" {
                    if let finalized = SessionBillingManager.shared.finalizeCurrentSessionIfActive() {
                        return IPCResponse(id: request.id, ok: true, bill: finalized)
                    }
                }
                if request.command == "bills" {
                    let recent = SessionBillingManager.shared.recentBills(limit: request.clickCount ?? 10)
                    return IPCResponse(id: request.id, ok: true, bill: recent.last, bills: recent)
                }
                if let current = SessionBillingManager.shared.currentOrLatestBill() {
                    if request.focus == true {
                        KillSwitchMonitor.shared.emitHUDEvent(.sessionBillCompleted(current))
                    }
                    return IPCResponse(id: request.id, ok: true, bill: current)
                } else {
                    let op = SessionBillingManager.shared.detectCurrentOperator(
                        explicitAgent: request.agentName,
                        explicitModel: request.modelName
                    )
                    let emptyBill = UsageSessionBill(
                        startTime: ISO8601DateFormatter().string(from: Date()),
                        endTime: ISO8601DateFormatter().string(from: Date()),
                        agentName: op.agentName,
                        modelName: op.modelName,
                        targetApps: [],
                        actionCount: 0,
                        totalDurationSeconds: 0.0,
                        activeExecutionMs: 0,
                        inputTokens: 0,
                        outputTokens: 0,
                        visionTokens: 0,
                        totalTokens: 0,
                        savedTokens: 0,
                        costUSD: 0.0,
                        savedCostUSD: 0.0,
                        steps: []
                    )
                    return IPCResponse(id: request.id, ok: true, bill: emptyBill)
                }

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
