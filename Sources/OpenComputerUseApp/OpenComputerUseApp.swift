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

    public func startServices() {
        OverlayHUDWindowController.shared.setupOverlayWindow()
        VirtualCursorWindowController.shared.ensureWindowCreated()
        MiniPreviewWindowController.shared.ensureWindowCreated()
        SessionBillWindowController.shared.ensureWindowCreated()

        KillSwitchMonitor.shared.setHUDHandler { event in
            OverlayHUDWindowController.shared.viewModel.handle(event)
        }
        KillSwitchMonitor.shared.setActionLogHandler { entry in
            OverlayHUDWindowController.shared.viewModel.appendLog(entry)
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
        }
    }

    public func resetAndPromptAccessibility() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Accessibility", "org.opencomputeruse.app"]
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
        proc.arguments = ["reset", "ScreenCapture", "org.opencomputeruse.app"]
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
            .appendingPathComponent("Contents/MacOS/ocu").path
        let fallbackPath = FileManager.default.currentDirectoryPath + "/.build/release/ocu"
        let resolvedPath = FileManager.default.fileExists(atPath: binaryPath) ? binaryPath : fallbackPath

        let config = """
        {
          "mcpServers": {
            "open-computer-use": {
              "command": "\(resolvedPath)",
              "args": ["mcp"]
            }
          }
        }
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)
        OverlayHUDWindowController.shared.viewModel.handle(
            .statusPill(title: "📋 已复制 MCP 配置 JSON", subtitle: resolvedPath)
        )
    }
}

@main
struct OpenComputerUseMenuBarApp: App {
    @StateObject private var coordinator = DaemonAppCoordinator.shared
    @StateObject private var hudViewModel = OverlayHUDWindowController.shared.viewModel
    @StateObject private var billViewModel = SessionBillWindowController.shared.viewModel

    init() {
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.accessory)
            DaemonAppCoordinator.shared.startServices()
        }
    }

    var body: some Scene {
        MenuBarExtra("OpenComputerUse", systemImage: coordinator.killSwitchTripped ? "exclamationmark.octagon.fill" : "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    GeminiSparkleIcon(size: 15, showHalo: true)
                    Text("OpenComputerUse")
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    Spacer()
                    Text(coordinator.ipcListening ? "● 在线" : "○ 离线")
                        .font(.caption)
                        .foregroundColor(coordinator.ipcListening ? GeminiPalette.mintGreen : .red)
                }

                Divider()

                // Active Operator & Usage Bill Section (Gemini Card)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        GeminiSparkleIcon(size: 11, showHalo: false)
                        Text(billViewModel.isSessionRunning ? "当前操作者 (运行中)" : "最近操作者 & 账单")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if billViewModel.isSessionRunning {
                            Text("● LIVE")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(GeminiPalette.mintGreen)
                        }
                    }

                    HStack {
                        Text("✦ \(billViewModel.activeAgentName)")
                            .font(.system(size: 12, weight: .bold))
                        Spacer()
                        Text(billViewModel.activeModelName)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(GeminiPalette.skyBlue)
                    }

                    if let lastBill = billViewModel.currentBill {
                        HStack {
                            Text("⏱️ \(lastBill.formattedDurationCompact)")
                                .font(.system(size: 10.5, design: .monospaced))
                            Spacer()
                            Text("📊 \(lastBill.totalTokens) tok")
                                .font(.system(size: 10.5, design: .monospaced))
                            Spacer()
                            Text(String(format: "💵 $%.5f", lastBill.costUSD))
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundColor(GeminiPalette.mintGreen)
                        }
                    }
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(GeminiPalette.auroraHorizontalGradient.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(GeminiPalette.auroraHorizontalGradient.opacity(0.35), lineWidth: 1)
                        )
                )

                // Primary Action: Open Main Dashboard Window ("电脑操控中心")
                Button(action: {
                    MainDashboardWindowController.shared.showWindow(section: .control)
                }) {
                    HStack {
                        Image(systemName: "macwindow.badge.plus")
                            .foregroundColor(GeminiPalette.skyBlue)
                        Text("打开电脑操控中心 (授权应用管理)")
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(GeminiPalette.auroraHorizontalGradient.opacity(0.22))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(GeminiPalette.auroraHorizontalGradient.opacity(0.55), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)

                Button(action: {
                    MainDashboardWindowController.shared.showWindow(section: .history)
                }) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundColor(GeminiPalette.violet)
                        Text("查看调用历史与消费账单明细")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)

                Divider()

                // Permissions Section
                HStack {
                    Text(coordinator.accessibilityGranted ? "✅ 辅助功能已就绪" : "⚠️ 辅助功能未授权")
                        .font(.system(size: 11.5))
                    Spacer()
                    Text(coordinator.screenRecordingGranted ? "✅ 屏幕录制已就绪" : "⚠️ 录屏未授权")
                        .font(.system(size: 11.5))
                }
                if !coordinator.accessibilityGranted || !coordinator.screenRecordingGranted {
                    HStack(spacing: 8) {
                        if !coordinator.accessibilityGranted {
                            Button("修复辅助功能") {
                                coordinator.resetAndPromptAccessibility()
                            }
                            .font(.caption)
                        }
                        if !coordinator.screenRecordingGranted {
                            Button("修复录屏权限") {
                                coordinator.resetAndPromptScreenRecording()
                            }
                            .font(.caption)
                            Button("重启生效") {
                                coordinator.relaunchApp()
                            }
                            .font(.caption)
                        }
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    if coordinator.killSwitchTripped {
                        Button("🟢 重置急停 (Reset)") {
                            KillSwitchMonitor.shared.reset()
                            coordinator.refreshPermissions()
                        }
                    } else {
                        Button("🛑 紧急停止 (Opt+Esc)") {
                            KillSwitchMonitor.shared.trip(reason: "MenuBar manual stop")
                            coordinator.refreshPermissions()
                        }
                    }

                    Spacer()

                    Button("退出") {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q")
                }
            }
            .padding(12)
            .frame(width: 310)
            .onAppear {
                coordinator.refreshPermissions()
                billViewModel.refreshFromDisk()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
