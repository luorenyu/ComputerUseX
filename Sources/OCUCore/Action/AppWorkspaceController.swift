import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

public final class AppWorkspaceController: @unchecked Sendable {
    public static let shared = AppWorkspaceController()

    private init() {}

    public func listRunningApps() -> [AppInfo] {
        let workspace = NSWorkspace.shared
        let windowList = currentWindowsByPID()

        let guiApps = workspace.runningApplications.filter { app in
            app.activationPolicy == .regular
        }

        return guiApps.map { app in
            let pid = app.processIdentifier
            return AppInfo(
                name: app.localizedName ?? app.bundleIdentifier ?? "Unknown",
                bundleId: app.bundleIdentifier,
                pid: pid,
                isActive: app.isActive,
                isHidden: app.isHidden,
                windows: windowList[pid] ?? []
            )
        }.sorted { a, b in
            if a.isActive != b.isActive {
                return a.isActive
            }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    public func focusOrLaunchApp(
        identifierOrName: String,
        launchIfNeeded: Bool = true
    ) throws -> ActionOutcome {
        try AuditAndSecurityGuard.shared.verifyAppAllowed(appName: identifierOrName)
        let startTime = Date()
        let lower = identifierOrName.lowercased()
        let workspace = NSWorkspace.shared

        if let running = workspace.runningApplications.first(where: { app in
            (app.localizedName?.lowercased() == lower) ||
            (app.bundleIdentifier?.lowercased() == lower) ||
            (app.localizedName?.lowercased().contains(lower) == true)
        }) {
            let name = running.localizedName ?? identifierOrName
            let pid = running.processIdentifier

            // In default Virtual Cursor / background mode, pin and target the application in the background
            // WITHOUT calling `running.activate()` or `kAXRaiseAction` (which would steal the user's window/input focus
            // or pop minimized windows onto the desktop).
            if MouseController.shared.useVirtualCursorByDefault {
                var scan = AXScanner.shared.scanApplication(
                    appNameFilter: name,
                    maxDepth: 10,
                    maxElements: 40
                )
                if !hasOnScreenWindow(pid: pid) || scan.windowFrame == nil {
                    if reopenAppWindowIfNeeded(pid: pid, appName: name, preserveUserFocus: true) {
                        scan = AXScanner.shared.scanApplication(
                            appNameFilter: name,
                            maxDepth: 10,
                            maxElements: 40
                        )
                    }
                }
                let wid = scan.windowID ?? UInt32(listRunningApps().first(where: { $0.pid == pid })?.windows.first?.windowId ?? 0)
                let bounds = scan.windowFrame ?? listRunningApps().first(where: { $0.pid == pid })?.windows.first?.frame ?? PermissionManager.shared.mainScreenBounds()
                if wid > 0 {
                    MouseController.shared.saveTargetContext(
                        pid: pid,
                        windowID: wid,
                        bounds: bounds,
                        appName: name
                    )
                    KillSwitchMonitor.shared.emitHUDEvent(
                        .pipTargetWindow(
                            pid: pid,
                            windowID: wid,
                            appName: name,
                            windowTitle: scan.windowTitle,
                            windowBounds: bounds
                        )
                    )
                }
                KillSwitchMonitor.shared.emitHUDEvent(.statusPill(title: "🪟 已锁定后台目标: \(name)", subtitle: nil))
                return ActionOutcome(
                    action: "focus_app(background)",
                    targetDescription: name,
                    point: bounds.center,
                    details: "pid=\(pid), windowID=\(wid), mode=background-pinned",
                    elapsedMs: Int(Date().timeIntervalSince(startTime) * 1000)
                )
            }

            running.unhide()
            running.activate()
            let axApp = AXUIElementCreateApplication(pid)
            var winsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
               let wins = winsRef as? [AXUIElement], !wins.isEmpty {
                let unminimizedWins = wins.filter { w in
                    var minRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minRef) == .success,
                       let isMin = minRef as? Bool {
                        return !isMin
                    }
                    return true
                }
                if unminimizedWins.isEmpty, let firstMin = wins.first {
                    AXUIElementSetAttributeValue(firstMin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                    AXUIElementPerformAction(firstMin, kAXRaiseAction as CFString)
                } else if let topWin = unminimizedWins.first {
                    AXUIElementPerformAction(topWin, kAXRaiseAction as CFString)
                }
            }
            Thread.sleep(forTimeInterval: 0.22)
            KillSwitchMonitor.shared.emitHUDEvent(.statusPill(title: "🪟 已激活应用: \(name)", subtitle: nil))
            return ActionOutcome(
                action: "focus_app",
                targetDescription: name,
                details: "pid=\(pid)",
                elapsedMs: Int(Date().timeIntervalSince(startTime) * 1000)
            )
        }

        guard launchIfNeeded else {
            let available = listRunningApps().map(\.name).joined(separator: ", ")
            throw OCUError(
                code: .appNotFound,
                message: "Running application '\(identifierOrName)' not found.",
                recoveryHint: "Available running apps: [\(available)]. Pass launch=true to launch it."
            )
        }

        // Launch via `/usr/bin/open` (use `-g` in background mode so launching never steals foreground focus)
        let userFrontApp = workspace.frontmostApplication
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let bgFlags = MouseController.shared.useVirtualCursorByDefault ? ["-g"] : []
        if identifierOrName.contains(".") && !identifierOrName.hasSuffix(".app") {
            proc.arguments = bgFlags + ["-b", identifierOrName]
        } else {
            proc.arguments = bgFlags + ["-a", identifierOrName]
        }
        try? proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw OCUError(
                code: .appNotFound,
                message: "Could not launch application '\(identifierOrName)'.",
                recoveryHint: "Verify the application name or bundle identifier."
            )
        }

        if MouseController.shared.useVirtualCursorByDefault {
            for _ in 0..<10 {
                Thread.sleep(forTimeInterval: 0.15)
                if let launched = workspace.runningApplications.first(where: { app in
                    (app.localizedName?.lowercased() == lower) ||
                    (app.bundleIdentifier?.lowercased() == lower) ||
                    (app.localizedName?.lowercased().contains(lower) == true)
                }), hasOnScreenWindow(pid: launched.processIdentifier) {
                    VirtualDisplayManager.shared.tuckWindowUnderFrontmost(pid: launched.processIdentifier)
                    break
                }
            }
            if let front = userFrontApp, workspace.frontmostApplication?.processIdentifier != front.processIdentifier {
                front.activate()
            }
        } else {
            Thread.sleep(forTimeInterval: 0.35)
        }
        KillSwitchMonitor.shared.emitHUDEvent(.statusPill(title: "🚀 已后台唤起应用: \(identifierOrName)", subtitle: nil))
        return ActionOutcome(
            action: "launch_app",
            targetDescription: identifierOrName,
            elapsedMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
    }

    public func hasOnScreenWindow(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if VirtualDisplayManager.shared.isAppMinimizedOrHidden(pid: pid) {
            return false
        }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.4)
        var winsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
           let wins = winsRef as? [AXUIElement] {
            let unminimized = wins.filter { w in
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
                if let t = titleRef as? String, t.lowercased().contains("watermark") {
                    return false
                }
                var minRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(w, kAXMinimizedAttribute as CFString, &minRef) == .success,
                   let isMin = minRef as? Bool {
                    return !isMin
                }
                return true
            }
            if !unminimized.isEmpty {
                return true
            }
        }
        return !(currentWindowsByPID()[pid] ?? []).isEmpty
    }

    /// Ensures a running application that currently has 0 open windows across all Spaces (e.g. closed to Dock/tray via Cmd+W or minimized)
    /// reopens or unminimizes its primary window in the background and tucks it underneath the user's active foreground window (e.g. `Antigravity`).
    @discardableResult
    public func reopenAppWindowIfNeeded(
        pid: Int32,
        appName: String,
        preserveUserFocus: Bool = true
    ) -> Bool {
        guard pid > 0 else { return false }
        if VirtualDisplayManager.shared.ensureWindowUnminimizedInBackground(pid: pid) {
            return true
        }
        if hasOnScreenWindow(pid: pid) {
            return true
        }

        // Only launch/reopen with `-g` (background, no foreground activation, no Space switch)
        let running = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == pid })
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let bgFlags = preserveUserFocus ? ["-g"] : []
        if let bundleId = running?.bundleIdentifier, !bundleId.isEmpty {
            proc.arguments = bgFlags + ["-b", bundleId]
        } else {
            proc.arguments = bgFlags + ["-a", appName]
        }
        try? proc.run()
        proc.waitUntilExit()

        for _ in 0..<6 {
            Thread.sleep(forTimeInterval: 0.14)
            if hasOnScreenWindow(pid: pid) {
                if preserveUserFocus {
                    VirtualDisplayManager.shared.tuckWindowUnderFrontmost(pid: pid)
                }
                return true
            }
        }
        return false
    }

    public func setFocusedWindowFrame(appName: String? = nil, rect: ScreenRect) throws -> ActionOutcome {
        let startTime = Date()
        let workspace = NSWorkspace.shared
        let targetApp: NSRunningApplication?

        if let name = appName, !name.isEmpty {
            let lower = name.lowercased()
            targetApp = workspace.runningApplications.first {
                $0.localizedName?.lowercased().contains(lower) == true ||
                $0.bundleIdentifier?.lowercased().contains(lower) == true
            }
        } else {
            targetApp = workspace.frontmostApplication
        }

        guard let app = targetApp else {
            throw OCUError(
                code: .appNotFound,
                message: "Target application not found for window resize.",
                recoveryHint: "Specify a running application name."
            )
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let windowObj = winRef else {
            throw OCUError(
                code: .actionFailed,
                message: "Could not obtain focused AXWindow for '\(app.localizedName ?? "")'.",
                recoveryHint: "Ensure Accessibility permission is granted and the app has an open window."
            )
        }

        let axWindow = windowObj as! AXUIElement
        var pt = CGPoint(x: rect.x, y: rect.y)
        var sz = CGSize(x: rect.width, y: rect.height)
        if let posVal = AXValueCreate(.cgPoint, &pt) {
            AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeVal)
        }

        return ActionOutcome(
            action: "resize_window",
            targetDescription: app.localizedName ?? "Window",
            point: rect.center,
            details: "frame=(\(Int(rect.x)), \(Int(rect.y)), \(Int(rect.width))x\(Int(rect.height)))",
            elapsedMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
    }

    public func waitForCondition(
        text: String? = nil,
        timeoutSeconds: Double = 5.0
    ) throws -> ActionOutcome {
        let startTime = Date()
        guard let query = text, !query.isEmpty else {
            let delay = max(0.05, min(30.0, timeoutSeconds))
            KillSwitchMonitor.shared.emitHUDEvent(.statusPill(title: "⏳ 等待 \(String(format: "%.1f", delay))s...", subtitle: nil))
            Thread.sleep(forTimeInterval: delay)
            return ActionOutcome(
                action: "wait",
                targetDescription: "\(delay)s",
                elapsedMs: Int(Date().timeIntervalSince(startTime) * 1000)
            )
        }

        let deadline = Date().addingTimeInterval(max(0.5, timeoutSeconds))
        let lower = query.lowercased()
        KillSwitchMonitor.shared.emitHUDEvent(.statusPill(title: "🔎 等待界面出现: \"\(query)\"", subtitle: nil))

        while Date() < deadline {
            try KillSwitchMonitor.shared.verifySafeToProceed()
            let snap = try ElementSnapshotStore.shared.captureSnapshot(enableOCR: true, enableSoM: false)
            if let found = snap.elements.first(where: { $0.label.lowercased().contains(lower) }) {
                return ActionOutcome(
                    action: "wait_for_text",
                    targetDescription: "\(found.ref) [\(found.label)]",
                    point: found.centerPoint,
                    details: "Found element \(found.ref) at (\(Int(found.centerPoint.x)), \(Int(found.centerPoint.y)))",
                    elapsedMs: Int(Date().timeIntervalSince(startTime) * 1000)
                )
            }
            Thread.sleep(forTimeInterval: 0.35)
        }

        throw OCUError(
            code: .timeout,
            message: "Timed out after \(timeoutSeconds)s waiting for text '\(query)' on screen.",
            recoveryHint: "Take a cux_snapshot to inspect the current UI state."
        )
    }

    /// Automates the macOS native File Picker (`NSOpenPanel` / `openAndSavePanelService`) in one command:
    /// sends `Cmd+Shift+G` (Go to Folder), pastes the absolute file path, confirms the path selection, and confirms the Open dialog.
    public func uploadFileInOpenPanel(filePath: String, appName: String? = nil) throws -> ActionOutcome {
        let startTime = Date()
        try KillSwitchMonitor.shared.verifySafeToProceed()
        let expandedPath = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            throw OCUError(
                code: .invalidArguments,
                message: "File to upload does not exist at path: \(expandedPath)",
                recoveryHint: "Provide a valid absolute file path."
            )
        }

        if let app = appName, !app.isEmpty {
            _ = try? focusOrLaunchApp(identifierOrName: app, launchIfNeeded: false)
            Thread.sleep(forTimeInterval: 0.15)
        }

        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "📂 正在自动选择上传文件...", subtitle: (expandedPath as NSString).lastPathComponent)
        )

        // 1. Open "Go to Folder" sheet inside macOS NSOpenPanel via Cmd+Shift+G
        _ = try KeyboardController.shared.pressShortcut("cmd+shift+g", virtualCursor: false)
        Thread.sleep(forTimeInterval: 0.32)

        // 2. Paste the absolute file path and press Return to navigate to and highlight the file
        _ = try KeyboardController.shared.typeText(expandedPath, clearFirst: true, submit: true, virtualCursor: false)
        Thread.sleep(forTimeInterval: 0.38)

        // 3. Press Return again to confirm the Open dialog
        _ = try KeyboardController.shared.pressShortcut("enter", virtualCursor: false)
        Thread.sleep(forTimeInterval: 0.18)

        let ms = Int(Date().timeIntervalSince(startTime) * 1000)
        return ActionOutcome(
            action: "upload_file",
            targetDescription: expandedPath,
            details: "Selected and submitted via macOS NSOpenPanel Cmd+Shift+G",
            elapsedMs: ms
        )
    }

    private func currentWindowsByPID() -> [Int32: [WindowInfo]] {
        var result: [Int32: [WindowInfo]] = [:]
        let onScreenList = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let allList = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? onScreenList

        var onScreenIDs = Set<Int>()
        for dict in onScreenList {
            if let winId = dict[kCGWindowNumber as String] as? Int {
                onScreenIDs.insert(winId)
            }
        }

        var seenIDs = Set<Int>()
        // 1. Add all windows on the current Space first, then windows on other Spaces (so cross-Space apps are never mistaken for closed)
        for dict in (onScreenList + allList) {
            guard let pid = dict[kCGWindowOwnerPID as String] as? Int32,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let winId = dict[kCGWindowNumber as String] as? Int,
                  !seenIDs.contains(winId),
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let alpha = (dict[kCGWindowAlpha as String] as? Double) ?? 1.0
            guard alpha > 0.01 else { continue }
            let x = Double(boundsDict["X"] ?? 0)
            let y = Double(boundsDict["Y"] ?? 0)
            let w = Double(boundsDict["Width"] ?? 0)
            let h = Double(boundsDict["Height"] ?? 0)
            let isOnCurrentSpace = onScreenIDs.contains(winId)
            // For off-Space windows (.optionAll), require standard main-window dimensions (>= 200x160) to ignore tiny helper surfaces
            if isOnCurrentSpace {
                guard w >= 40 && h >= 40 else { continue }
            } else {
                guard w >= 200 && h >= 160 else { continue }
            }
            seenIDs.insert(winId)

            let title = dict[kCGWindowName as String] as? String ?? ""
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""

            let info = WindowInfo(
                windowId: winId,
                title: title,
                appName: owner,
                pid: pid,
                frame: ScreenRect(x: x, y: y, width: w, height: h),
                isOnScreen: isOnCurrentSpace,
                layer: layer
            )
            result[pid, default: []].append(info)
        }
        for (pid, wins) in result {
            result[pid] = wins.sorted { a, b in
                if a.isOnScreen != b.isOnScreen { return a.isOnScreen }
                let aHasTitle = !a.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let bHasTitle = !b.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if aHasTitle != bHasTitle { return aHasTitle }
                return (a.frame.width * a.frame.height) > (b.frame.width * b.frame.height)
            }
        }
        return result
    }
}

extension CGSize {
    init(x: Double, y: Double) {
        self.init(width: x, height: y)
    }
}
