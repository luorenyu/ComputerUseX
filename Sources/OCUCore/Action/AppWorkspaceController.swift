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
        let startTime = Date()
        let lower = identifierOrName.lowercased()
        let workspace = NSWorkspace.shared

        if let running = workspace.runningApplications.first(where: { app in
            (app.localizedName?.lowercased() == lower) ||
            (app.bundleIdentifier?.lowercased() == lower) ||
            (app.localizedName?.lowercased().contains(lower) == true)
        }) {
            running.unhide()
            running.activate()
            let axApp = AXUIElementCreateApplication(running.processIdentifier)
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
            let name = running.localizedName ?? identifierOrName
            KillSwitchMonitor.shared.emitHUDEvent(.statusPill(title: "🪟 已激活应用: \(name)", subtitle: nil))
            return ActionOutcome(
                action: "focus_app",
                targetDescription: name,
                details: "pid=\(running.processIdentifier)",
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

        // Launch via `/usr/bin/open -a <name>`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if identifierOrName.contains(".") && !identifierOrName.hasSuffix(".app") {
            proc.arguments = ["-b", identifierOrName]
        } else {
            proc.arguments = ["-a", identifierOrName]
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

        Thread.sleep(forTimeInterval: 0.35)
        KillSwitchMonitor.shared.emitHUDEvent(.statusPill(title: "🚀 已启动应用: \(identifierOrName)", subtitle: nil))
        return ActionOutcome(
            action: "launch_app",
            targetDescription: identifierOrName,
            elapsedMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
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
            recoveryHint: "Take an ocu_snapshot to inspect the current UI state."
        )
    }

    private func currentWindowsByPID() -> [Int32: [WindowInfo]] {
        var result: [Int32: [WindowInfo]] = [:]
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return result
        }

        for dict in infoList {
            guard let pid = dict[kCGWindowOwnerPID as String] as? Int32,
                  let layer = dict[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let x = Double(boundsDict["X"] ?? 0)
            let y = Double(boundsDict["Y"] ?? 0)
            let w = Double(boundsDict["Width"] ?? 0)
            let h = Double(boundsDict["Height"] ?? 0)
            guard w >= 40 && h >= 40 else { continue }

            let winId = dict[kCGWindowNumber as String] as? Int ?? 0
            let title = dict[kCGWindowName as String] as? String ?? ""
            let owner = dict[kCGWindowOwnerName as String] as? String ?? ""

            let info = WindowInfo(
                windowId: winId,
                title: title,
                appName: owner,
                pid: pid,
                frame: ScreenRect(x: x, y: y, width: w, height: h),
                isOnScreen: true,
                layer: layer
            )
            result[pid, default: []].append(info)
        }
        return result
    }
}

extension CGSize {
    init(x: Double, y: Double) {
        self.init(width: x, height: y)
    }
}
