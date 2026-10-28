import Foundation
import AppKit
import SwiftUI
import OCUCore

public final class DaemonAppCoordinator: ObservableObject, @unchecked Sendable {
    public static let shared = DaemonAppCoordinator()

    @Published public var accessibilityGranted: Bool = false
    @Published public var screenRecordingGranted: Bool = false
    @Published public var ipcListening: Bool = false
    @Published public var killSwitchTripped: Bool = false
    @Published public var humanTakeoverGuard: Bool = true
    @Published public var virtualCursorMode: Bool = true
    @Published public var miniPiPPreviewMode: Bool = true
    @Published public var interactiveAppConsent: Bool = AuditAndSecurityGuard.shared.loadConfig().interactiveAppConsent

    private let ipcServer = UnixSocketIPC()
    private var timer: Timer?

    private init() {
        refreshPermissions()
    }

    /// Ensures only a single `ComputerUseXApp` menu bar daemon is ever active at once,
    /// terminating any stale/duplicate `ComputerUseXApp` instances before registering the StatusBar icon and IPC socket.
    private func terminateOlderDuplicateInstances() {
        let myPid = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != myPid else { continue }
            let isMatchingExec = app.executableURL?.lastPathComponent == "ComputerUseXApp"
            let isMatchingBundle = app.bundleIdentifier == "org.computerusex.app" && app.executableURL?.lastPathComponent != "cux"
            if isMatchingExec || isMatchingBundle {
                _ = app.forceTerminate()
            }
        }
    }

    public func startServices() {
        terminateOlderDuplicateInstances()
        OverlayHUDWindowController.shared.setupOverlayWindow()
        VirtualCursorWindowController.shared.ensureWindowCreated()
        MiniPreviewWindowController.shared.ensureWindowCreated()
        SessionBillWindowController.shared.ensureWindowCreated()
        StatusBarPopoverController.shared.setupStatusItem()

        KillSwitchMonitor.shared.setHUDHandler { event in
            OverlayHUDWindowController.shared.viewModel.handle(event)
        }
        KillSwitchMonitor.shared.setActionLogHandler { entry in
            OverlayHUDWindowController.shared.viewModel.appendLog(entry)
        }
        OCUCommandExecutor.shared.customHUDDemoHandler = {
            try MainDashboardWindowController.shared.runInteractiveDashboardDemo()
        }
        KillSwitchMonitor.shared.startMonitoringHotkey()

        do {
            try ipcServer.startServer()
            ipcListening = true
            OverlayHUDWindowController.shared.viewModel.appendLog("🟢 IPC Server started at \(UnixSocketIPC.defaultSocketPath)")
        } catch {
            ipcListening = false
            OverlayHUDWindowController.shared.viewModel.appendLog("❌ IPC Server error: \(error.localizedDescription)")
        }

        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func refreshPermissions() {
        let ax = PermissionManager.shared.isAccessibilityGranted(prompt: false)
        let sr = PermissionManager.shared.isScreenRecordingGranted(prompt: false)
        let tripped = KillSwitchMonitor.shared.isTripped
        DispatchQueue.main.async {
            self.accessibilityGranted = ax
            self.screenRecordingGranted = sr
            self.killSwitchTripped = tripped
            StatusBarPopoverController.shared.updateIcon(killSwitchTripped: tripped)
        }
    }

    public func resetAndPromptAccessibility() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Accessibility", "org.computerusex.app"]
        try? proc.run()
        proc.waitUntilExit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            _ = PermissionManager.shared.isAccessibilityGranted(prompt: true)
            PermissionManager.shared.openAccessibilitySettings()
            self.refreshPermissions()
        }
    }

    public func resetAndPromptScreenRecording() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "ScreenCapture", "org.computerusex.app"]
        try? proc.run()
        proc.waitUntilExit()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            _ = PermissionManager.shared.isScreenRecordingGranted(prompt: true)
            PermissionManager.shared.openScreenRecordingSettings()
            self.refreshPermissions()
        }
    }

    public func relaunchApp() {
        let bundlePath = Bundle.main.bundleURL.path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 0.4 && open -g \"\(bundlePath)\""]
        try? proc.run()
        NSApplication.shared.terminate(nil)
    }

    public func runVisualHUDDemo() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = OCUCommandExecutor.shared.execute(IPCRequest(command: "hud_demo"), isDaemonContext: true)
        }
    }

    public func copyMCPConfigToClipboard() {
        let binaryPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/cux").path
        let fallbackPath = FileManager.default.currentDirectoryPath + "/.build/release/cux"
        let resolvedPath = FileManager.default.fileExists(atPath: binaryPath) ? binaryPath : fallbackPath

        let config = """
        {
          "mcpServers": {
            "computer-use-x": {
              "command": "\(resolvedPath)",
              "args": ["mcp"]
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)
        OverlayHUDWindowController.shared.viewModel.handle(
            .statusPill(title: "已复制 MCP 配置 JSON", subtitle: resolvedPath)
        )
    }

    public func installToAllAgentsAndCodexPlugin() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let outcome = try? AuditAndSecurityGuard.shared.installMCPConfiguration(target: "all") {
                OverlayHUDWindowController.shared.viewModel.handle(
                    .statusPill(
                        title: "已安装 Codex 插件 / Skill 与 MCP 配置",
                        subtitle: outcome.details ?? "Codex · Claude · Gemini · Cursor"
                    )
                )
            }
        }
    }
}

@main
struct ComputerUseXMenuBarApp: App {
    init() {
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            DaemonAppCoordinator.shared.startServices()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

public final class StatusBarPopoverController: NSObject, @unchecked Sendable {
    public static let shared = StatusBarPopoverController()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var globalClickMonitor: Any?

    private override init() {
        super.init()
    }

    public func setupStatusItem() {
        DispatchQueue.main.async {
            guard self.statusItem == nil else { return }

            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item.button {
                button.image = GeminiBrandIconRenderer.statusBarImage(pointSize: 18)
                button.image?.isTemplate = true
                button.target = self
                button.action = #selector(self.togglePopover(_:))
            }
            self.statusItem = item

            let contentView = MenuBarPopupContentView(
                coordinator: DaemonAppCoordinator.shared,
                billViewModel: SessionBillWindowController.shared.viewModel
            )
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)

            let hostingController = NSHostingController(rootView: contentView)
            self.popover.contentSize = NSSize(width: 336, height: 320)
            self.popover.behavior = .transient
            self.popover.animates = true
            self.popover.appearance = NSAppearance(named: .darkAqua)
            self.popover.contentViewController = hostingController
        }
    }

    public func updateIcon(killSwitchTripped: Bool) {
        DispatchQueue.main.async {
            if let button = self.statusItem?.button {
                if killSwitchTripped {
                    button.image = NSImage(systemSymbolName: "exclamationmark.octagon.fill", accessibilityDescription: "ComputerUseX")
                    button.image?.isTemplate = true
                } else {
                    button.image = GeminiBrandIconRenderer.statusBarImage(pointSize: 18)
                    button.image?.isTemplate = true
                }
            }
        }
    }

    @objc public func togglePopover(_ sender: AnyObject?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    public func showPopover() {
        DispatchQueue.main.async {
            guard let button = self.statusItem?.button else { return }
            DaemonAppCoordinator.shared.refreshPermissions()
            SessionBillWindowController.shared.viewModel.refreshFromDisk()
            NSApp.activate(ignoringOtherApps: true)
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.popover.contentViewController?.view.window?.makeKey()

            if self.globalClickMonitor == nil {
                self.globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown]
                ) { [weak self] _ in
                    self?.closePopover()
                }
            }
        }
    }

    public func closePopover() {
        DispatchQueue.main.async {
            if self.popover.isShown {
                self.popover.performClose(nil)
            }
            if let monitor = self.globalClickMonitor {
                NSEvent.removeMonitor(monitor)
                self.globalClickMonitor = nil
            }
        }
    }
}

private struct MenuBarPopupContentView: View {
    @ObservedObject var coordinator: DaemonAppCoordinator
    @ObservedObject var billViewModel: SessionBillViewModel

    var body: some View {
        ZStack {
            // Unified Google Gemini Dark Obsidian Backdrop with Ambient Aurora Orbs
            GeminiAmbientBackdropView(intensity: 1.0)

            VStack(alignment: .leading, spacing: 11) {
                // 1. Header Bar
                HStack(spacing: 8) {
                    GeminiSparkleIcon(size: 16, showHalo: true)
                    Text("ComputerUseX")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()

                    // High-contrast status pill
                    HStack(spacing: 5) {
                        Circle()
                            .fill(coordinator.ipcListening ? GeminiPalette.textMintBright : GeminiPalette.coral)
                            .frame(width: 6, height: 6)
                            .shadow(color: (coordinator.ipcListening ? GeminiPalette.textMintBright : GeminiPalette.coral).opacity(0.8), radius: 4)
                        Text(coordinator.ipcListening ? "在线" : "离线")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(coordinator.ipcListening ? GeminiPalette.textMintBright : GeminiPalette.textCoralBright)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(coordinator.ipcListening ? Color(red: 0.06, green: 0.24, blue: 0.19) : Color(red: 0.28, green: 0.10, blue: 0.12))
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        (coordinator.ipcListening ? GeminiPalette.textMintBright : GeminiPalette.coral).opacity(0.38),
                                        lineWidth: 0.8
                                    )
                            )
                    )
                }

                Rectangle()
                    .fill(GeminiPalette.subtleBorderGradient)
                    .frame(height: 1)

                // 2. Active Operator & Usage Bill Section (High-Contrast Gemini Card)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        GeminiSparkleIcon(size: 11, showHalo: false)
                        Text(billViewModel.isSessionRunning ? "当前操作者 (运行中)" : "最近操作者 & 账单")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(GeminiPalette.textSecondary)
                        Spacer()
                        if billViewModel.isSessionRunning {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(GeminiPalette.textMintBright)
                                    .frame(width: 5, height: 5)
                                Text("LIVE")
                                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                    .foregroundColor(GeminiPalette.textMintBright)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color(red: 0.06, green: 0.24, blue: 0.19)))
                        }
                    }

                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            Image(systemName: "cpu.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(GeminiPalette.textSkyBright)
                            Text(billViewModel.activeAgentName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                        }
                        Spacer()
                        Text(billViewModel.activeModelName)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(GeminiPalette.textSkyBright)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule()
                                    .fill(GeminiPalette.blue.opacity(0.24))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(GeminiPalette.textSkyBright.opacity(0.38), lineWidth: 0.8)
                                    )
                            )
                    }

                    if let lastBill = billViewModel.currentBill {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Image(systemName: "clock.fill")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundColor(GeminiPalette.textSkyBright)
                                Text(lastBill.formattedDurationCompact)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.92))
                                Spacer()
                            }

                            HStack(spacing: 12) {
                                HStack(spacing: 4) {
                                    Image(systemName: "chart.bar.fill")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(GeminiPalette.textVioletBright)
                                    Text("\(lastBill.totalTokens) tok")
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundColor(GeminiPalette.textSecondary)
                                }
                                Spacer()
                                HStack(spacing: 4) {
                                    Image(systemName: "dollarsign.circle.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(GeminiPalette.textMintBright)
                                    Text(String(format: "$%.5f USD", lastBill.costUSD))
                                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                                        .foregroundColor(GeminiPalette.textMintBright)
                                }
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.black.opacity(0.30))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.8)
                                )
                        )
                    }
                }
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(GeminiPalette.surfaceCard.opacity(0.94))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(GeminiPalette.subtleBorderGradient, lineWidth: 1)
                        )
                )

                // 3. Primary Action: Open Main Dashboard Window ("电脑操控中心") & Dismiss Popup
                Button(action: {
                    StatusBarPopoverController.shared.closePopover()
                    MainDashboardWindowController.shared.showWindow(section: .control)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.2.square.on.square")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(GeminiPalette.textSkyBright)
                        Text("打开电脑操控中心 (授权应用管理)")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(GeminiPalette.textSkyBright)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8.5)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(GeminiPalette.surfaceElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(GeminiPalette.auroraHorizontalGradient.opacity(0.75), lineWidth: 1.1)
                            )
                            .shadow(color: GeminiPalette.blue.opacity(0.28), radius: 6, y: 1)
                    )
                }
                .buttonStyle(.plain)

                Button(action: {
                    StatusBarPopoverController.shared.closePopover()
                    MainDashboardWindowController.shared.showWindow(section: .history)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(GeminiPalette.textVioletBright)
                        Text("查看调用历史与消费账单明细")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(GeminiPalette.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7.5)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(GeminiPalette.surfaceCard.opacity(0.90))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)

                    // 4. Permissions Section (Vector SF Symbols instead of emojis)
                    HStack(spacing: 10) {
                        HStack(spacing: 5) {
                            Image(systemName: coordinator.accessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(coordinator.accessibilityGranted ? GeminiPalette.textMintBright : GeminiPalette.peach)
                            Text(coordinator.accessibilityGranted ? "辅助功能已就绪" : "辅助功能未授权")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.90))
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: coordinator.screenRecordingGranted ? "record.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(coordinator.screenRecordingGranted ? GeminiPalette.textSkyBright : GeminiPalette.peach)
                            Text(coordinator.screenRecordingGranted ? "屏幕录制已就绪" : "录屏未授权")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.90))
                        }
                    }

                    if !coordinator.accessibilityGranted || !coordinator.screenRecordingGranted {
                        HStack(spacing: 8) {
                            if !coordinator.accessibilityGranted {
                                Button(action: {
                                    coordinator.resetAndPromptAccessibility()
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "wrench.and.screwdriver.fill")
                                            .font(.system(size: 10))
                                        Text("修复辅助功能")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(GeminiPalette.surfaceElevated))
                                }
                                .buttonStyle(.plain)
                            }
                            if !coordinator.screenRecordingGranted {
                                Button(action: {
                                    coordinator.resetAndPromptScreenRecording()
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "wrench.and.screwdriver.fill")
                                            .font(.system(size: 10))
                                        Text("修复录屏权限")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(GeminiPalette.surfaceElevated))
                                }
                                .buttonStyle(.plain)

                                Button(action: {
                                    coordinator.relaunchApp()
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 10))
                                        Text("重启生效")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .foregroundColor(GeminiPalette.textSkyBright)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(GeminiPalette.blue.opacity(0.20)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)

                    // 5. Bottom Control Row (Vector SF Symbols instead of emojis)
                    HStack(spacing: 8) {
                        if coordinator.killSwitchTripped {
                            Button(action: {
                                KillSwitchMonitor.shared.reset()
                                coordinator.refreshPermissions()
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "arrow.clockwise.circle.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(GeminiPalette.textMintBright)
                                    Text("重置急停 (Reset)")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(.white)
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5.5)
                                .background(
                                    Capsule()
                                        .fill(Color(red: 0.08, green: 0.26, blue: 0.20))
                                        .overlay(Capsule().strokeBorder(GeminiPalette.textMintBright.opacity(0.45), lineWidth: 1))
                                )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(action: {
                                KillSwitchMonitor.shared.trip(reason: "MenuBar manual stop")
                                coordinator.refreshPermissions()
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "stop.circle.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(GeminiPalette.textCoralBright)
                                    Text("紧急停止 (Opt+Esc)")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.95))
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5.5)
                                .background(
                                    Capsule()
                                        .fill(GeminiPalette.coral.opacity(0.18))
                                        .overlay(Capsule().strokeBorder(GeminiPalette.coral.opacity(0.45), lineWidth: 1))
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        Button(action: {
                            NSApplication.shared.terminate(nil)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "power")
                                    .font(.system(size: 10.5, weight: .bold))
                                Text("退出")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundColor(GeminiPalette.textSecondary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5.5)
                            .background(
                                Capsule()
                                    .fill(GeminiPalette.surfaceCard)
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                            )
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("q")
                    }
                }
                .padding(14)
            }
            .frame(width: 336)
            .preferredColorScheme(.dark)
            .environment(\.colorScheme, .dark)
            .onAppear {
                coordinator.refreshPermissions()
                billViewModel.refreshFromDisk()
            }
    }
}
