import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import OCUCore

public enum DashboardSection: String, CaseIterable, Identifiable {
    case control = "控制与授权"
    case history = "调用历史与消费"

    public var id: String { rawValue }
}

public final class MainDashboardViewModel: ObservableObject, @unchecked Sendable {
    @Published public var selectedSection: DashboardSection = .control
    @Published public var allowAnyApp: Bool = true
    @Published public var chromeBridgeEnabled: Bool = true
    @Published public var showMoreBrowsers: Bool = false
    @Published public var backgroundVirtualMode: Bool = true
    @Published public var lockScreenSandboxEnabled: Bool = true

    @Published public var allowedApps: [String] = []
    @Published public var blockedApps: [String] = []
    @Published public var bills: [UsageSessionBill] = []
    @Published public var auditRecords: [AuditRecord] = []
    @Published public var expandedBillIds: Set<String> = []

    @Published public var operatorAgent: String = "Antigravity"
    @Published public var operatorModel: String = "Gemini 4 Argon Medium"
    @Published public var accessibilityGranted: Bool = true
    @Published public var screenRecordingGranted: Bool = true
    @Published public var newAppInput: String = ""
    @Published public var showAddAppSheet: Bool = false

    public init() {
        refresh()
    }

    public func refresh() {
        var cfg = AuditAndSecurityGuard.shared.loadConfig()
        if cfg.allowedApps.isEmpty {
            cfg.allowedApps = OCUSecurityConfig.defaultAllowedApps
            AuditAndSecurityGuard.shared.saveConfig(cfg)
        }
        let allBills = SessionBillingManager.shared.recentBills(limit: 100).reversed()
        let audits = AuditAndSecurityGuard.shared.recentAuditRecords(limit: 40).reversed()
        let op = SessionBillingManager.shared.detectCurrentOperator()
        let axOk = PermissionManager.shared.isAccessibilityGranted(prompt: false)
        let srOk = PermissionManager.shared.isScreenRecordingGranted(prompt: false)

        DispatchQueue.main.async {
            self.allowAnyApp = !cfg.interactiveAppConsent
            self.allowedApps = cfg.allowedApps
            self.blockedApps = cfg.blockedApps
            self.bills = Array(allBills)
            self.auditRecords = Array(audits)
            self.operatorAgent = op.agentName
            self.operatorModel = op.modelName
            self.accessibilityGranted = axOk
            self.screenRecordingGranted = srOk
            self.backgroundVirtualMode = MouseController.shared.useVirtualCursorByDefault
            if let firstBill = self.bills.first, self.expandedBillIds.isEmpty {
                self.expandedBillIds.insert(firstBill.billId)
            }
        }
    }

    public func toggleAllowAnyApp(_ allowed: Bool) {
        allowAnyApp = allowed
        AuditAndSecurityGuard.shared.setInteractiveConsentEnabled(!allowed)
    }

    public func toggleBackgroundVirtualMode(_ enabled: Bool) {
        backgroundVirtualMode = enabled
        MouseController.shared.useVirtualCursorByDefault = enabled
        MiniPreviewWindowController.shared.viewModel.isEnabled = enabled
        if !enabled {
            VirtualCursorWindowController.shared.hideCursor()
            MiniPreviewWindowController.shared.hidePreview()
        }
    }

    public func removeAllowedApp(_ name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "确认移除「\(name)」的始终允许权限？"
        alert.informativeText = "移除后，当 AI Agent 再次尝试操控「\(name)」时，将会重新弹窗请求您的授权确认。"
        if let appIcon = AppIconResolver.icon(for: name) {
            alert.icon = appIcon
        }
        alert.addButton(withTitle: "确认移除")
        alert.addButton(withTitle: "取消")
        if #available(macOS 11.0, *) {
            alert.buttons.first?.hasDestructiveAction = true
        }
        if alert.runModal() == .alertFirstButtonReturn {
            AuditAndSecurityGuard.shared.removeAllowedApp(name)
            refresh()
        }
    }

    public func addAllowedApp(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = AuditAndSecurityGuard.shared.updateAppPermission(appName: trimmed, allow: true)
        refresh()
    }

    public func pickAppFromFinder() {
        let panel = NSOpenPanel()
        panel.title = "选择始终允许操控的应用程序"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls {
                let appName = url.deletingPathExtension().lastPathComponent
                _ = AuditAndSecurityGuard.shared.updateAppPermission(appName: appName, allow: true)
            }
            refresh()
        }
    }

    public func updateOperatorModel(agent: String, model: String) {
        SessionBillingManager.shared.registerMCPClient(name: agent, modelHint: model)
        SessionBillWindowController.shared.viewModel.refreshFromDisk()
        refresh()
    }
}

public final class MainDashboardWindowController: @unchecked Sendable {
    public static let shared = MainDashboardWindowController()

    public let viewModel = MainDashboardViewModel()
    private var window: NSWindow?
    fileprivate var tabProbeViews: [DashboardSection: DashboardTabProbeNSView] = [:]

    private init() {}

    public func dismissMenuBarPopup() {
        StatusBarPopoverController.shared.closePopover()
    }

    public func showWindow(section: DashboardSection? = nil) {
        DispatchQueue.main.async {
            self.dismissMenuBarPopup()

            if let sec = section {
                self.viewModel.selectedSection = sec
            }
            self.viewModel.refresh()

            if self.window == nil {
                let rect = NSRect(x: 0, y: 0, width: 860, height: 760)
                let win = NSWindow(
                    contentRect: rect,
                    styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                    backing: .buffered,
                    defer: false
                )
                win.title = "ComputerUseX — 电脑操控中心"
                win.titlebarAppearsTransparent = true
                win.titleVisibility = .hidden
                win.appearance = NSAppearance(named: .darkAqua)
                win.isOpaque = false
                win.backgroundColor = .clear
                win.minSize = NSSize(width: 780, height: 620)
                win.isReleasedWhenClosed = false
                win.center()
                win.contentView = NSHostingView(
                    rootView: MainDashboardRootView(viewModel: self.viewModel)
                        .preferredColorScheme(.dark)
                        .environment(\.colorScheme, .dark)
                )
                self.window = win
            }

            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func refreshData() {
        viewModel.refresh()
    }

    public func screenRectForTab(_ sec: DashboardSection) -> ScreenRect {
        var result = ScreenRect(x: 400, y: 300, width: 140, height: 34)
        let block = {
            if let probe = self.tabProbeViews[sec], let liveRect = probe.currentScreenRect() {
                result = liveRect
                return
            }
            guard let win = self.window else { return }
            let mainScreenH = NSScreen.screens.first?.frame.height ?? 900.0
            let contentTopY = win.frame.minY + win.contentLayoutRect.maxY
            let winTopLeftX = Double(win.frame.minX)
            let winTopLeftY = Double(mainScreenH - contentTopY)
            if sec == .control {
                result = ScreenRect(x: winTopLeftX + 36, y: winTopLeftY + 112, width: 126, height: 34)
            } else {
                result = ScreenRect(x: winTopLeftX + 174, y: winTopLeftY + 112, width: 162, height: 34)
            }
        }
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
        return result
    }

    public func switchTabOnMainThread(_ sec: DashboardSection) {
        let block = {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                self.viewModel.selectedSection = sec
            }
        }
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }

    public func runInteractiveDashboardDemo() throws -> ActionOutcome {
        let startTime = Date()
        showWindow(section: .control)
        Thread.sleep(forTimeInterval: 0.20)

        var startPoint = PermissionManager.shared.currentMouseLocation()
        DispatchQueue.main.sync {
            MiniPreviewWindowController.shared.viewModel.targetWindowID = 0
            if let win = self.window {
                let mainScreenH = NSScreen.screens.first?.frame.height ?? 900.0
                let winTopLeftX = Double(win.frame.minX)
                let winTopLeftY = Double(mainScreenH - win.frame.maxY)
                startPoint = ScreenPoint(
                    x: winTopLeftX + Double(win.frame.width) * 0.65,
                    y: winTopLeftY + 128
                )
            }
            OverlayHUDWindowController.shared.viewModel.updateActiveScreen(for: startPoint)
        }

        KillSwitchMonitor.shared.reset()
        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "ComputerUseX 视觉引擎演示", subtitle: "正在操控「电脑操控中心」来回切换功能面板")
        )
        KillSwitchMonitor.shared.emitHUDEvent(.setActiveGlow(true))

        func animateDemoPointer(from start: ScreenPoint, to end: ScreenPoint, duration: TimeInterval) throws {
            let steps = 22
            let pts = CubicBezierTrajectory.sample(from: start, to: end, steps: steps)
            let dt = max(0.008, duration / Double(pts.count))
            var prev = start
            for pt in pts {
                try KillSwitchMonitor.shared.verifySafeToProceed()
                let vx = pt.x - prev.x
                let tilt = max(-18.0, min(18.0, vx * 0.45))
                KillSwitchMonitor.shared.emitHUDEvent(
                    .virtualCursorMove(point: pt, windowID: 0, pid: 0, tiltAngle: tilt, label: nil)
                )
                prev = pt
                Thread.sleep(forTimeInterval: dt)
            }
            KillSwitchMonitor.shared.emitHUDEvent(
                .virtualCursorMove(point: end, windowID: 0, pid: 0, tiltAngle: 0.0, label: nil)
            )
        }

        func clickDashboardTab(
            from currentPt: ScreenPoint,
            section: DashboardSection,
            refTag: String,
            subtitle: String,
            moveDuration: TimeInterval,
            dwellSeconds: TimeInterval
        ) throws -> ScreenPoint {
            let tabRect = self.screenRectForTab(section)
            let targetPt = tabRect.center
            KillSwitchMonitor.shared.emitHUDEvent(
                .statusPill(title: "点击 \(refTag)「\(section.rawValue)」", subtitle: subtitle)
            )
            KillSwitchMonitor.shared.emitHUDEvent(
                .highlightElement(rect: tabRect, label: "\(refTag) \(section.rawValue)")
            )
            try animateDemoPointer(from: currentPt, to: targetPt, duration: moveDuration)
            KillSwitchMonitor.shared.emitHUDEvent(.virtualCursorPress(point: targetPt, windowID: 0, isPressed: true))
            KillSwitchMonitor.shared.emitHUDEvent(.clickRipple(point: targetPt, button: .left, clickCount: 1))
            self.switchTabOnMainThread(section)
            Thread.sleep(forTimeInterval: 0.12)
            KillSwitchMonitor.shared.emitHUDEvent(.virtualCursorPress(point: targetPt, windowID: 0, isPressed: false))
            Thread.sleep(forTimeInterval: dwellSeconds)
            return targetPt
        }

        // Round 1: Switch to「调用历史与消费」-> Switch back to「控制与授权」
        let pt1 = try clickDashboardTab(
            from: startPoint,
            section: .history,
            refTag: "@e2",
            subtitle: "查看 AI Agent 任务消费账单、耗时与 Token 统计",
            moveDuration: 0.40,
            dwellSeconds: 0.65
        )
        let pt2 = try clickDashboardTab(
            from: pt1,
            section: .control,
            refTag: "@e1",
            subtitle: "管理应用授权白名单、浏览器桥接与后台沙箱策略",
            moveDuration: 0.38,
            dwellSeconds: 0.55
        )

        // Round 2: One more back-and-forth between「调用历史与消费」and「控制与授权」
        let pt3 = try clickDashboardTab(
            from: pt2,
            section: .history,
            refTag: "@e2",
            subtitle: "第二次切换至「调用历史与消费」验证平滑轨迹",
            moveDuration: 0.36,
            dwellSeconds: 0.55
        )
        let pt4 = try clickDashboardTab(
            from: pt3,
            section: .control,
            refTag: "@e1",
            subtitle: "切回「控制与授权」主面板",
            moveDuration: 0.36,
            dwellSeconds: 0.30
        )

        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "ComputerUseX 面板操控演示完成", subtitle: "按下 Option+Esc 可随时紧急停止")
        )
        Thread.sleep(forTimeInterval: 0.35)
        KillSwitchMonitor.shared.emitHUDEvent(.virtualCursorHide)

        return ActionOutcome(
            action: "hud_demo",
            targetDescription: "Interactive Dashboard Tab Switching Demo (调用历史与消费 <-> 控制与授权)",
            point: pt4,
            elapsedMs: Int(Date().timeIntervalSince(startTime) * 1000)
        )
    }
}

// MARK: - App Icon Lookup Helper

enum AppIconResolver {
    static func icon(for appIdentifierOrName: String) -> NSImage? {
        let trimmed = appIdentifierOrName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        // 1. Check standard application bundle paths first (avoids matching helper processes like WeChatAppEx Helper)
        let candidatePaths: [String] = [
            "/Applications/\(trimmed).app",
            "/System/Applications/\(trimmed).app",
            "/System/Applications/Utilities/\(trimmed).app",
            "/System/Library/CoreServices/Applications/\(trimmed).app",
            "\(NSHomeDirectory())/Applications/\(trimmed).app"
        ]
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                return NSWorkspace.shared.icon(forFile: path)
            }
        }

        // 2. Check known bundle ID mappings (WeChat, iPhone Mirroring, Chrome, etc.)
        let knownBundleIDs: [String: String] = [
            "wechat": "com.tencent.xinWeChat",
            "微信": "com.tencent.xinWeChat",
            "iphone mirroring": "com.apple.ScreenContinuity",
            "google chrome": "com.google.Chrome",
            "android studio": "com.google.android.studio",
            "safari": "com.apple.Safari",
            "finder": "com.apple.finder"
        ]
        if let bid = knownBundleIDs[lower],
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        // 3. Check running top-level GUI applications (.regular policy only)
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && (
                ($0.localizedName?.lowercased() == lower) ||
                ($0.bundleIdentifier?.lowercased() == lower) ||
                ($0.bundleURL?.deletingPathExtension().lastPathComponent.lowercased() == lower) ||
                ($0.localizedName?.lowercased().contains(lower) == true)
            )
        }) {
            if let bundleURL = running.bundleURL {
                return NSWorkspace.shared.icon(forFile: bundleURL.path)
            }
            if let icon = running.icon {
                return icon
            }
        }

        return nil
    }
}

// MARK: - Native AppKit Screen Coordinate Probe for Dashboard Tabs

final class DashboardTabProbeNSView: NSView {
    func currentScreenRect() -> ScreenRect? {
        guard let win = self.window, self.bounds.width > 10, self.bounds.height > 10 else {
            return nil
        }
        let rectInWindow = self.convert(self.bounds, to: nil)
        let rectInScreen = win.convertToScreen(rectInWindow)
        let mainScreenH = NSScreen.screens.first?.frame.height ?? 900.0
        return ScreenRect(
            x: Double(rectInScreen.minX),
            y: Double(mainScreenH - rectInScreen.maxY),
            width: Double(rectInScreen.width),
            height: Double(rectInScreen.height)
        )
    }
}

private struct DashboardTabProbeRepresentable: NSViewRepresentable {
    let section: DashboardSection

    func makeNSView(context: Context) -> DashboardTabProbeNSView {
        let view = DashboardTabProbeNSView(frame: .zero)
        DispatchQueue.main.async {
            MainDashboardWindowController.shared.tabProbeViews[section] = view
        }
        return view
    }

    func updateNSView(_ nsView: DashboardTabProbeNSView, context: Context) {
        DispatchQueue.main.async {
            MainDashboardWindowController.shared.tabProbeViews[section] = nsView
        }
    }
}

// MARK: - Main Dashboard SwiftUI View (Frosted Glass & Spacious Grid Layout)

struct MainDashboardRootView: View {
    @ObservedObject var viewModel: MainDashboardViewModel
    @State private var refreshRotationAngle: Double = 0.0

    private let cardDark = GeminiPalette.surfaceCard.opacity(0.32)

    var body: some View {
        ZStack {
            // 1. Frosted Glass + Ambient Aurora Backdrop
            GeminiAmbientBackdropView(intensity: 1.15)

            VStack(alignment: .leading, spacing: 0) {
                // Top Header Bar (Cleaned up: removed Operator Agent capsule)
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 12) {
                            GeminiSparkleIcon(size: 26, showHalo: true)
                            Text("电脑操控")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)
                        }
                        Text("管理 AI Agent 应用操控权限、后台画中画预览策略与任务使用账单")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(GeminiPalette.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.horizontal, 36)
                .padding(.top, 32)
                .padding(.bottom, 18)

                // Segmented Section Switcher & Right Action Toolbar
                HStack(spacing: 12) {
                    // Left: Unified Frosted-Glass Segmented Tab Track
                    HStack(spacing: 6) {
                        ForEach(DashboardSection.allCases) { sec in
                            let isSelected = (viewModel.selectedSection == sec)
                            Button(action: {
                                withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                                    viewModel.selectedSection = sec
                                }
                            }) {
                                HStack(spacing: 7) {
                                    if isSelected {
                                        GeminiSparkleIcon(size: 13, showHalo: false)
                                    } else {
                                        Image(systemName: sec == .control ? "slider.horizontal.3" : "doc.text.magnifyingglass")
                                            .font(.system(size: 12.5, weight: .semibold))
                                    }
                                    Text(sec.rawValue)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    if sec == .history && !viewModel.bills.isEmpty {
                                        Text("\(viewModel.bills.count)")
                                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                            .padding(.horizontal, 6.5)
                                            .padding(.vertical, 1.5)
                                            .background(
                                                Capsule().fill(isSelected ? GeminiPalette.blue.opacity(0.34) : Color.white.opacity(0.10))
                                            )
                                    }
                                }
                                .fixedSize(horizontal: true, vertical: false)
                                .foregroundColor(isSelected ? .white : .white.opacity(0.66))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 8)
                                .background(
                                    ZStack {
                                        if isSelected {
                                            Capsule().fill(.ultraThinMaterial)
                                            Capsule().fill(GeminiPalette.surfaceElevated.opacity(0.62))
                                            Capsule().strokeBorder(GeminiPalette.auroraGradient, lineWidth: 1.3)
                                        }
                                    }
                                    .shadow(
                                        color: isSelected ? GeminiPalette.blue.opacity(0.32) : Color.clear,
                                        radius: 8,
                                        y: 2
                                    )
                                )
                                .background(DashboardTabProbeRepresentable(section: sec))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                    .background(
                        ZStack {
                            Capsule().fill(.ultraThinMaterial)
                            Capsule().fill(Color.black.opacity(0.18))
                            Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                        }
                    )

                    Spacer()

                    // Right Action Toolbar: Copy MCP Config + Demo + Icon-Only Refresh
                    Button(action: {
                        DaemonAppCoordinator.shared.copyMCPConfigToClipboard()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(GeminiPalette.textSkyBright)
                            Text("复制 MCP 配置")
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(
                            ZStack {
                                Capsule().fill(.ultraThinMaterial)
                                Capsule().fill(cardDark)
                                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                            }
                        )
                    }
                    .buttonStyle(.plain)
                    .help("一键复制 MCP Server 配置 JSON 到剪贴板")

                    Button(action: {
                        DaemonAppCoordinator.shared.runVisualHUDDemo()
                    }) {
                        HStack(spacing: 6) {
                            GeminiSparkleIcon(size: 13, showHalo: false)
                            Image(systemName: "play.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(GeminiPalette.textSkyBright)
                            Text("演示效果 (Demo)")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 8)
                        .background(
                            ZStack {
                                Capsule().fill(.ultraThinMaterial)
                                Capsule().fill(GeminiPalette.auroraHorizontalGradient.opacity(0.24))
                                Capsule().strokeBorder(GeminiPalette.auroraHorizontalGradient.opacity(0.75), lineWidth: 1)
                            }
                        )
                        .shadow(color: GeminiPalette.blue.opacity(0.28), radius: 8, y: 1)
                    }
                    .buttonStyle(.plain)
                    .help("在主控中心演示虚拟指针跨 Tab 点击切换动画")

                    // Icon-Only Circular Refresh Button with 360° Spin Animation
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.55)) {
                            refreshRotationAngle += 360.0
                        }
                        viewModel.refresh()
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.88))
                            .rotationEffect(.degrees(refreshRotationAngle))
                            .frame(width: 34, height: 34)
                            .background(
                                ZStack {
                                    Circle().fill(.ultraThinMaterial)
                                    Circle().fill(cardDark)
                                    Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                }
                            )
                    }
                    .buttonStyle(.plain)
                    .help("刷新控制面板与账单数据")
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 16)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                GeminiPalette.blue.opacity(0.32),
                                GeminiPalette.violet.opacity(0.32),
                                GeminiPalette.coral.opacity(0.22),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1)

                // Main Scrollable Content
                ScrollView(.vertical, showsIndicators: true) {
                    if viewModel.selectedSection == .control {
                        controlAndAppsView
                            .padding(.horizontal, 36)
                            .padding(.vertical, 24)
                    } else {
                        historyAndBillingView
                            .padding(.horizontal, 36)
                            .padding(.vertical, 24)
                    }
                }
            }
        }
        .coordinateSpace(name: "DashboardRootSpace")
    }

    // MARK: - Section 1: Control & App Permissions (Spacious 2x2 Strategy Grid + 3-Col App Grid)

    private var controlAndAppsView: some View {
        let twoColumns = [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16)
        ]
        let threeColumns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12)
        ]

        return VStack(alignment: .leading, spacing: 26) {
            // 0. Permission Onboarding Banner (only shown if Accessibility or Screen Recording is missing)
            if !viewModel.accessibilityGranted || !viewModel.screenRecordingGranted {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(GeminiPalette.peach.opacity(0.20))
                            .frame(width: 36, height: 36)
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(GeminiPalette.peach)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("需要完成 macOS 系统权限授权")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundColor(.white)
                        Text("请开启「辅助功能」（读取界面元素树与合成点击）与「屏幕录制」（OCR 视觉兜底与实时画中画预览）权限。")
                            .font(.system(size: 12))
                            .foregroundColor(GeminiPalette.textSecondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if !viewModel.accessibilityGranted {
                            Button(action: {
                                DaemonAppCoordinator.shared.resetAndPromptAccessibility()
                            }) {
                                Text("授权辅助功能")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(GeminiPalette.blue.opacity(0.35)))
                            }
                            .buttonStyle(.plain)
                        }
                        if !viewModel.screenRecordingGranted {
                            Button(action: {
                                DaemonAppCoordinator.shared.resetAndPromptScreenRecording()
                            }) {
                                Text("授权屏幕录制")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Capsule().fill(GeminiPalette.violet.opacity(0.38)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(16)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(cardDark)
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(GeminiPalette.peach.opacity(0.45), lineWidth: 1)
                    }
                )
            }

            // 1. Core Control Strategy (2x2 Frosted Glass Grid)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("核心操控策略")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.92))
                    Text("配置后台零焦点操控、画中画预览与跨应用授权行为")
                        .font(.system(size: 12))
                        .foregroundColor(GeminiPalette.textSecondary)
                }

                LazyVGrid(columns: twoColumns, spacing: 14) {
                    // Card 1: 任意应用访问
                    StrategyGridCardView(
                        iconView: AnyView(
                            ZStack {
                                GeminiPalette.auroraGradient
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: GeminiPalette.blue.opacity(0.35), radius: 6)
                        ),
                        title: "任意应用访问",
                        badgeText: viewModel.allowAnyApp ? "全局允许" : "白名单模式",
                        badgeColor: viewModel.allowAnyApp ? GeminiPalette.mintGreen : GeminiPalette.peach,
                        subtitle: "允许 \(viewModel.operatorAgent) 直接操控桌面应用；关闭后首次访问未知应用将弹窗询问授权。",
                        trailing: AnyView(
                            Toggle("", isOn: Binding(
                                get: { viewModel.allowAnyApp },
                                set: { viewModel.toggleAllowAnyApp($0) }
                            ))
                            .toggleStyle(.switch)
                            .tint(GeminiPalette.blue)
                            .labelsHidden()
                        )
                    )

                    // Card 2: 后台虚拟指针与实时预览窗
                    StrategyGridCardView(
                        iconView: AnyView(
                            ZStack {
                                LinearGradient(colors: [GeminiPalette.indigo, GeminiPalette.violet, GeminiPalette.coral], startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "pip.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: GeminiPalette.violet.opacity(0.35), radius: 6)
                        ),
                        title: "后台虚拟指针与画中画预览",
                        badgeText: "零焦点合成",
                        badgeColor: GeminiPalette.skyBlue,
                        subtitle: "不抢占物理鼠标与前台焦点，在任务执行期间于右下角持续显示被操作窗口实时画面。",
                        trailing: AnyView(
                            Toggle("", isOn: Binding(
                                get: { viewModel.backgroundVirtualMode },
                                set: { viewModel.toggleBackgroundVirtualMode($0) }
                            ))
                            .toggleStyle(.switch)
                            .tint(GeminiPalette.blue)
                            .labelsHidden()
                        )
                    )

                    // Card 3: 浏览器免焦点 DOM / JS 桥接
                    StrategyGridCardView(
                        iconView: AnyView(
                            ZStack {
                                LinearGradient(
                                    colors: [GeminiPalette.mintGreen, GeminiPalette.skyBlue, GeminiPalette.blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: "globe")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: GeminiPalette.mintGreen.opacity(0.32), radius: 6)
                        ),
                        title: "浏览器免焦点桥接",
                        badgeText: "Chrome · Safari · Arc · Edge",
                        badgeColor: GeminiPalette.mintGreen,
                        subtitle: "无需将浏览器切到前台，直接读取打开的标签页、提取精简交互 DOM 或执行 JS 脚本。",
                        trailing: AnyView(
                            Toggle("", isOn: $viewModel.chromeBridgeEnabled)
                                .toggleStyle(.switch)
                                .tint(GeminiPalette.blue)
                                .labelsHidden()
                        )
                    )

                    // Card 4: 锁屏与后台边缘沙箱
                    StrategyGridCardView(
                        iconView: AnyView(
                            ZStack {
                                LinearGradient(colors: [GeminiPalette.skyBlue.opacity(0.85), GeminiPalette.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
                                Image(systemName: "macwindow.on.rectangle")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        ),
                        title: "后台沙箱与最小化恢复",
                        badgeText: "Ghost Space",
                        badgeColor: GeminiPalette.skyBlue,
                        subtitle: "当目标窗口最小化或停靠在屏幕边缘沙箱时，支持在后台自动唤醒并完成感知与点击。",
                        trailing: AnyView(
                            Toggle("", isOn: $viewModel.lockScreenSandboxEnabled)
                                .toggleStyle(.switch)
                                .tint(GeminiPalette.blue)
                                .labelsHidden()
                        )
                    )
                }
            }

            // 2. Always Allowed Applications (3-Column Compact Frosted Glass Grid)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    HStack(spacing: 8) {
                        Text("始终允许的应用")
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundColor(.white.opacity(0.92))
                        Text("\(viewModel.allowedApps.count)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(GeminiPalette.textSkyBright)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(GeminiPalette.blue.opacity(0.22)))
                    }

                    Spacer()

                    HStack(spacing: 10) {
                        HStack(spacing: 7) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(GeminiPalette.textSkyBright.opacity(0.88))

                            ZStack(alignment: .leading) {
                                if viewModel.newAppInput.isEmpty {
                                    Text("输入应用名或 Bundle ID...")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(Color.white.opacity(0.55))
                                        .allowsHitTesting(false)
                                }
                                TextField("", text: $viewModel.newAppInput)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                    .onSubmit {
                                        if !viewModel.newAppInput.isEmpty {
                                            viewModel.addAllowedApp(viewModel.newAppInput)
                                            viewModel.newAppInput = ""
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(width: 220)
                        .background(
                            ZStack {
                                Capsule().fill(.ultraThinMaterial)
                                Capsule().fill(cardDark)
                                Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            }
                        )

                        Button(action: {
                            if !viewModel.newAppInput.isEmpty {
                                viewModel.addAllowedApp(viewModel.newAppInput)
                                viewModel.newAppInput = ""
                            } else {
                                viewModel.pickAppFromFinder()
                            }
                        }) {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))
                                Text("添加应用")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                ZStack {
                                    Capsule().fill(.ultraThinMaterial)
                                    Capsule().fill(GeminiPalette.auroraHorizontalGradient.opacity(0.36))
                                    Capsule().strokeBorder(GeminiPalette.auroraHorizontalGradient.opacity(0.82), lineWidth: 1)
                                }
                            )
                            .shadow(color: GeminiPalette.blue.opacity(0.32), radius: 6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                LazyVGrid(columns: threeColumns, spacing: 12) {
                    ForEach(Array(viewModel.allowedApps.enumerated()), id: \.offset) { _, appName in
                        HStack(spacing: 11) {
                            AppBadgeIcon(appName: appName)

                            Text(appName)
                                .font(.system(size: 13, weight: .medium, design: appName.contains(".") ? .monospaced : .default))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            Button(action: {
                                viewModel.removeAllowedApp(appName)
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(.white.opacity(0.48))
                                    .frame(width: 24, height: 24)
                                    .background(Circle().fill(Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .help("从始终允许列表中移除 \(appName)")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(.ultraThinMaterial)
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(cardDark)
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(GeminiPalette.subtleBorderGradient, lineWidth: 1)
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Section 2: Call History & Usage Billing

    private var historyAndBillingView: some View {
        let totalSessions = viewModel.bills.count
        let sumTotalSec = viewModel.bills.reduce(0.0) { $0 + max($1.totalDurationSeconds, $1.toolExecutionSeconds) }
        let sumToolSec = viewModel.bills.reduce(0.0) { $0 + $1.toolExecutionSeconds }
        let sumTokens = viewModel.bills.reduce(0) { $0 + $1.totalTokens }
        let sumCostUSD = viewModel.bills.reduce(0.0) { $0 + $1.costUSD }

        return VStack(alignment: .leading, spacing: 22) {
            // 1. Summary KPI Row
            HStack(spacing: 14) {
                DashboardKPIBox(
                    title: "累计任务次数",
                    value: "\(totalSessions) 次",
                    subtitle: "当前 Agent: \(viewModel.operatorAgent)",
                    accent: GeminiPalette.skyBlue
                )
                DashboardKPIBox(
                    title: "累计总耗时 / 工具耗时",
                    value: String(format: "%.1fs", sumTotalSec),
                    subtitle: String(format: "工具执行耗时: %.1fs", sumToolSec),
                    accent: GeminiPalette.violet
                )
                DashboardKPIBox(
                    title: "累计消耗 Token",
                    value: "\(sumTokens)",
                    subtitle: "含输入与界面快照输出",
                    accent: GeminiPalette.coral
                )
                DashboardKPIBox(
                    title: "累计消费金额",
                    value: String(format: "$%.4f", sumCostUSD),
                    subtitle: String(format: "折合人民币 ≈ ¥%.3f", sumCostUSD * 7.20),
                    accent: GeminiPalette.mintGreen
                )
            }

            // 2. Session Bills List
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    GeminiSparkleIcon(size: 13, showHalo: false)
                    Text("每次任务完整使用账单 (\(viewModel.bills.count))")
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.92))
                }

                if viewModel.bills.isEmpty {
                    Text("暂无历史账单记录。当 Agent 调用 ComputerUse 完成任务后将自动生成账单。")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .background(
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial)
                                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(cardDark)
                            }
                        )
                } else {
                    VStack(spacing: 12) {
                        ForEach(viewModel.bills) { bill in
                            let isExpanded = viewModel.expandedBillIds.contains(bill.billId)
                            VStack(alignment: .leading, spacing: 0) {
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.16)) {
                                        if isExpanded {
                                            viewModel.expandedBillIds.remove(bill.billId)
                                        } else {
                                            viewModel.expandedBillIds.insert(bill.billId)
                                        }
                                    }
                                }) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            AppBadgeIcon(appName: bill.targetApps.first ?? "Finder")

                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(spacing: 8) {
                                                    HStack(spacing: 5) {
                                                        GeminiSparkleIcon(size: 13, showHalo: false)
                                                        Text(bill.agentName)
                                                            .font(.system(size: 13.5, weight: .bold))
                                                            .foregroundColor(.white)
                                                    }
                                                    Text(bill.modelName)
                                                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                                        .foregroundColor(GeminiPalette.skyBlue)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 2)
                                                        .background(
                                                            Capsule()
                                                                .fill(GeminiPalette.blue.opacity(0.18))
                                                                .overlay(Capsule().strokeBorder(GeminiPalette.skyBlue.opacity(0.32), lineWidth: 0.8))
                                                        )
                                                    if !bill.targetApps.isEmpty {
                                                        Text("→ " + bill.targetApps.joined(separator: ", "))
                                                            .font(.system(size: 12, weight: .medium))
                                                            .foregroundColor(.white.opacity(0.75))
                                                            .lineLimit(1)
                                                    }
                                                }

                                                Text("#\(bill.billId) · \(bill.endTime)")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundColor(.white.opacity(0.45))
                                            }

                                            Spacer()

                                            VStack(alignment: .trailing, spacing: 2) {
                                                Text(String(format: "$%.5f USD", bill.costUSD))
                                                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                                                    .foregroundColor(GeminiPalette.mintGreen)
                                                Text(String(format: "≈ ¥%.4f CNY", bill.costUSD * 7.20))
                                                    .font(.system(size: 10.5, design: .monospaced))
                                                    .foregroundColor(.white.opacity(0.55))
                                            }

                                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.white.opacity(0.45))
                                                .padding(.leading, 6)
                                        }

                                        // Duration (Total + Tool Execution) & Token Bar
                                        HStack(spacing: 16) {
                                            HStack(spacing: 5) {
                                                Image(systemName: "clock.fill")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(GeminiPalette.skyBlue)
                                                Text(bill.formattedDurationSummary)
                                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                                    .foregroundColor(.white.opacity(0.88))
                                            }

                                            Spacer()

                                            HStack(spacing: 5) {
                                                GeminiSparkleIcon(size: 12, showHalo: false)
                                                Text("共 \(bill.totalTokens) Tokens (输入 \(bill.inputTokens) / 输出 \(bill.outputTokens))")
                                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                                    .foregroundColor(.white.opacity(0.82))
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7.5)
                                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.05)))
                                    }
                                    .padding(16)
                                }
                                .buttonStyle(.plain)

                                if isExpanded && !bill.steps.isEmpty {
                                    Divider().background(Color.white.opacity(0.07)).padding(.horizontal, 16)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("操作步骤流水 (\(bill.steps.count) 步):")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.55))
                                            .padding(.bottom, 2)

                                        ForEach(Array(bill.steps.enumerated()), id: \.offset) { sIdx, step in
                                            HStack(spacing: 8) {
                                                Text("\(sIdx + 1).")
                                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                    .foregroundColor(.white.opacity(0.45))
                                                    .frame(width: 20, alignment: .trailing)
                                                Text(step.command)
                                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                    .foregroundColor(GeminiPalette.skyBlue)
                                                    .frame(width: 68, alignment: .leading)
                                                Text(step.targetDescription)
                                                    .font(.system(size: 11.5))
                                                    .foregroundColor(.white.opacity(0.85))
                                                    .lineLimit(1)
                                                Spacer()
                                                Text("\(step.elapsedMs)ms")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundColor(GeminiPalette.mintGreen.opacity(0.85))
                                                Text("\(step.inputTokens + step.outputTokens) tok")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundColor(.white.opacity(0.5))
                                                    .frame(width: 64, alignment: .trailing)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(Color.black.opacity(0.18))
                                }
                            }
                            .background(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(.ultraThinMaterial)
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(cardDark)
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(GeminiPalette.subtleBorderGradient, lineWidth: 1)
                                }
                            )
                        }
                    }
                }
            }
        }
    }
}

private struct StrategyGridCardView: View {
    let iconView: AnyView
    let title: String
    let badgeText: String
    let badgeColor: Color
    let subtitle: String
    let trailing: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                iconView

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(badgeText)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(badgeColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(badgeColor.opacity(0.15))
                                .overlay(Capsule().strokeBorder(badgeColor.opacity(0.32), lineWidth: 0.8))
                        )
                }

                Spacer()

                trailing
            }

            Text(subtitle)
                .font(.system(size: 12))
                .foregroundColor(GeminiPalette.textSecondary)
                .lineSpacing(2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(GeminiPalette.surfaceCard.opacity(0.32))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(GeminiPalette.subtleBorderGradient, lineWidth: 1)
            }
        )
    }
}

private struct AppBadgeIcon: View {
    let appName: String

    var body: some View {
        if let nsImg = AppIconResolver.icon(for: appName) {
            Image(nsImage: nsImg)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(GeminiPalette.auroraGradient.opacity(0.28))
                    .frame(width: 28, height: 28)
                Text(String(appName.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
    }
}

private struct DashboardKPIBox: View {
    let title: String
    let value: String
    let subtitle: String
    let accent: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accent.opacity(0.24), .clear],
                        center: .center,
                        startRadius: 2,
                        endRadius: 55
                    )
                )
                .frame(width: 90, height: 90)
                .offset(x: 24, y: -24)
                .blur(radius: 10)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(GeminiPalette.textSecondary)
                    .lineLimit(1)
                Text(value)
                    .font(.system(size: 20, weight: .heavy, design: .monospaced))
                    .foregroundColor(accent)
                    .shadow(color: accent.opacity(0.35), radius: 6)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(GeminiPalette.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(GeminiPalette.surfaceCard.opacity(0.32))
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(GeminiPalette.subtleBorderGradient, lineWidth: 1)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}
