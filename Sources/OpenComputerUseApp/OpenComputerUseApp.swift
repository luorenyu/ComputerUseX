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
        MenuBarExtra("OpenComputerUse", systemImage: coordinator.killSwitchTripped ? "exclamationmark.octagon.fill" : "cursorarrow.motionlines") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "cursorarrow.motionlines")
                        .foregroundColor(.cyan)
                    Text("OpenComputerUse (ocu)")
                        .font(.headline)
                    Spacer()
                    Text(coordinator.ipcListening ? "● 在线" : "○ 离线")
                        .font(.caption)
                        .foregroundColor(coordinator.ipcListening ? .green : .red)
                }

                Divider()

                // Active Operator & Usage Bill Section
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Image(systemName: "person.badge.key.fill")
                            .foregroundColor(.cyan)
                            .font(.system(size: 11))
                        Text(billViewModel.isSessionRunning ? "当前操作者 (运行中)" : "最近操作者 & 账单")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        if billViewModel.isSessionRunning {
                            Text("● LIVE")
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }

                    HStack {
                        Text("🤖 \(billViewModel.activeAgentName)")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(billViewModel.activeModelName)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    if let lastBill = billViewModel.currentBill {
                        HStack {
                            Text("⏱️ \(String(format: "%.1fs", lastBill.totalDurationSeconds)) (\(lastBill.actionCount)步)")
                                .font(.system(size: 11, design: .monospaced))
                            Spacer()
                            Text("📊 \(lastBill.totalTokens) tok")
                                .font(.system(size: 11, design: .monospaced))
                            Spacer()
                            Text(String(format: "💵 $%.5f", lastBill.costUSD))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.green)
                        }
                        Button("🧾 弹出完整使用账单卡片 (#\(lastBill.billId))") {
                            SessionBillWindowController.shared.presentCompletedBill(lastBill, autoHideSeconds: 12.0)
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))

                Divider()

                // Permissions Section
                Text("系统权限状态 (macOS TCC)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text(coordinator.accessibilityGranted ? "✅ 辅助功能 (Accessibility)" : "⚠️ 辅助功能未授权")
                        .font(.system(size: 12))
                    Spacer()
                    if !coordinator.accessibilityGranted {
                        Button("重置重授") {
                            coordinator.resetAndPromptAccessibility()
                        }
                        .font(.caption)
                        .help("当重新编译导致 macOS TCC 签名缓存失效时，一键清除旧签名记录并重新弹窗授权")

                        Button("去授权") {
                            _ = PermissionManager.shared.isAccessibilityGranted(prompt: true)
                            PermissionManager.shared.openAccessibilitySettings()
                        }
                        .font(.caption)
                    }
                }

                HStack {
                    Text(coordinator.screenRecordingGranted ? "✅ 屏幕录制 (Vision OCR/SoM)" : "⚠️ 屏幕录制未授权")
                        .font(.system(size: 12))
                    Spacer()
                    if !coordinator.screenRecordingGranted {
                        Button("重置重授") {
                            coordinator.resetAndPromptScreenRecording()
                        }
                        .font(.caption)
                        .help("清除旧签名录屏权限记录并重新弹窗授权")

                        Button("去授权") {
                            _ = PermissionManager.shared.isScreenRecordingGranted(prompt: true)
                            PermissionManager.shared.openScreenRecordingSettings()
                        }
                        .font(.caption)

                        Button("重启生效") {
                            coordinator.relaunchApp()
                        }
                        .font(.caption)
                        .help("macOS 录屏权限开启后需重启进程刷新状态")
                    }
                }

                Divider()

                // Controls & Safety
                Toggle("开启独立虚拟鼠标 (Codex 后台模式)", isOn: Binding(
                    get: { coordinator.virtualCursorMode },
                    set: { val in
                        coordinator.virtualCursorMode = val
                        MouseController.shared.useVirtualCursorByDefault = val
                        if !val {
                            VirtualCursorWindowController.shared.hideCursor()
                        }
                    }
                ))
                .font(.system(size: 12))

                Toggle("开启后台小窗实时预览 (Codex PiP 模式)", isOn: Binding(
                    get: { coordinator.miniPiPPreviewMode },
                    set: { val in
                        coordinator.miniPiPPreviewMode = val
                        MiniPreviewWindowController.shared.viewModel.isEnabled = val
                        if !val {
                            MiniPreviewWindowController.shared.hidePreview()
                        }
                    }
                ))
                .font(.system(size: 12))

                Toggle("开启全屏流光与鼠标轨迹 HUD", isOn: $hudViewModel.isHUDEnabled)
                    .font(.system(size: 12))

                Toggle("人工晃动鼠标自动接管保护", isOn: Binding(
                    get: { coordinator.humanTakeoverGuard },
                    set: { val in
                        coordinator.humanTakeoverGuard = val
                        KillSwitchMonitor.shared.humanTakeoverEnabled = val
                    }
                ))
                .font(.system(size: 12))

                Toggle("首次操作未知 App 弹窗授权确认", isOn: Binding(
                    get: { coordinator.interactiveAppConsent },
                    set: { val in
                        coordinator.interactiveAppConsent = val
                        AuditAndSecurityGuard.shared.setInteractiveConsentEnabled(val)
                    }
                ))
                .font(.system(size: 12))

                HStack(spacing: 8) {
                    Button("✨ 播放 HUD 视觉演示") {
                        coordinator.runVisualHUDDemo()
                    }
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
                }

                Button("📋 一键复制 MCP Server 配置 JSON") {
                    coordinator.copyMCPConfigToClipboard()
                }

                if !hudViewModel.recentLogs.isEmpty {
                    Divider()
                    Text("最近 Agent 动作记录")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(hudViewModel.recentLogs.prefix(6), id: \.self) { log in
                        Text(log)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                    }
                }

                Divider()

                Button("退出 OpenComputerUse") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(12)
            .frame(width: 320)
            .onAppear {
                coordinator.refreshPermissions()
            }
        }
        .menuBarExtraStyle(.window)
    }
}
