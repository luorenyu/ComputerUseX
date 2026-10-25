import Foundation
import AppKit
import SwiftUI
import OCUCore

public final class SessionBillPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

public final class SessionBillViewModel: ObservableObject, @unchecked Sendable {
    @Published public var isVisible: Bool = false
    @Published public var currentBill: UsageSessionBill? = nil
    @Published public var recentBills: [UsageSessionBill] = []

    // Live operator state while session is active
    @Published public var activeAgentName: String = "Antigravity Agent"
    @Published public var activeModelName: String = "Gemini 2.5 Pro"
    @Published public var activeActionText: String = "待命就绪"
    @Published public var activeStepCount: Int = 0
    @Published public var activeTotalTokens: Int = 0
    @Published public var activeCostUSD: Double = 0.0
    @Published public var isSessionRunning: Bool = false

    public init() {
        refreshFromDisk()
    }

    public func refreshFromDisk() {
        let bills = SessionBillingManager.shared.recentBills(limit: 8)
        let detected = SessionBillingManager.shared.detectCurrentOperator()
        DispatchQueue.main.async {
            self.recentBills = bills.reversed()
            if self.currentBill == nil {
                self.currentBill = bills.last
            }
            if !self.isSessionRunning {
                self.activeAgentName = detected.agentName
                self.activeModelName = detected.modelName
            }
        }
    }
}

/// Manages the floating glassmorphic ComputerUse Usage Bill Receipt card ("🧾 ComputerUse 使用账单").
public final class SessionBillWindowController: @unchecked Sendable {
    public static let shared = SessionBillWindowController()

    public let viewModel = SessionBillViewModel()
    private var panel: SessionBillPanel?
    private var autoDismissItem: DispatchWorkItem?

    private let panelWidth: Double = 356.0
    private let panelHeight: Double = 286.0

    private init() {}

    public func ensureWindowCreated() {
        DispatchQueue.main.async {
            if self.panel != nil { return }
            let screenFrame = NSScreen.screens.first?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let originX = screenFrame.maxX - self.panelWidth - 18.0
            let originY = screenFrame.minY + 18.0
            let rect = NSRect(x: originX, y: originY, width: self.panelWidth, height: self.panelHeight)

            let win = SessionBillPanel(
                contentRect: rect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = true
            win.ignoresMouseEvents = false
            win.isMovableByWindowBackground = true
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            win.contentView = NSHostingView(
                rootView: SessionBillReceiptView(
                    viewModel: self.viewModel,
                    onClose: { [weak self] in
                        self?.hideBillWindow()
                    }
                )
            )
            self.panel = win
        }
    }

    public func updateLiveOperator(
        agentName: String,
        modelName: String,
        currentAction: String,
        actionCount: Int,
        totalTokens: Int,
        costUSD: Double
    ) {
        DispatchQueue.main.async {
            self.viewModel.activeAgentName = agentName
            self.viewModel.activeModelName = modelName
            self.viewModel.activeActionText = currentAction
            self.viewModel.activeStepCount = actionCount
            self.viewModel.activeTotalTokens = totalTokens
            self.viewModel.activeCostUSD = costUSD
            self.viewModel.isSessionRunning = true
        }
    }

    public func presentCompletedBill(_ bill: UsageSessionBill, autoHideSeconds: TimeInterval = 9.0) {
        DispatchQueue.main.async {
            self.ensureWindowCreated()
            self.viewModel.isSessionRunning = false
            self.viewModel.activeAgentName = bill.agentName
            self.viewModel.activeModelName = bill.modelName
            self.viewModel.activeActionText = "已完成 (\(bill.actionCount) 步)"
            self.viewModel.currentBill = bill
            self.viewModel.refreshFromDisk()

            if let panel = self.panel {
                // Position neatly above Mini PiP if Mini PiP is visible, or at bottom-right corner
                let screenFrame = NSScreen.screens.first?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                let originX = screenFrame.maxX - self.panelWidth - 18.0
                let pipOffset = MiniPreviewWindowController.shared.viewModel.isVisible ? (MiniPreviewWindowController.shared.viewModel.panelHeight + 14.0) : 0.0
                let originY = screenFrame.minY + 18.0 + pipOffset
                panel.setFrameOrigin(NSPoint(x: originX, y: originY))
                panel.orderFrontRegardless()
            }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                self.viewModel.isVisible = true
            }

            self.autoDismissItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.hideBillWindow()
            }
            self.autoDismissItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHideSeconds, execute: item)
        }
    }

    public func hideBillWindow() {
        DispatchQueue.main.async {
            self.autoDismissItem?.cancel()
            withAnimation(.easeOut(duration: 0.22)) {
                self.viewModel.isVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                if !self.viewModel.isVisible {
                    self.panel?.orderOut(nil)
                }
            }
        }
    }
}

struct SessionBillReceiptView: View {
    @ObservedObject var viewModel: SessionBillViewModel
    let onClose: () -> Void

    var body: some View {
        if let bill = viewModel.currentBill {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.cyan, Color.blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 26, height: 26)
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("ComputerUse 使用账单")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        Text("会话 #\(bill.billId) · \(bill.endTime)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.62))
                    }

                    Spacer()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }

                Divider().background(Color.white.opacity(0.15))

                // Agent & Model Row
                HStack(spacing: 10) {
                    BillMetricBox(
                        icon: "cpu.fill",
                        label: "操作 Agent",
                        value: bill.agentName,
                        accent: .cyan
                    )
                    BillMetricBox(
                        icon: "sparkles",
                        label: "使用模型",
                        value: bill.modelName,
                        accent: .purple
                    )
                }

                // Time & Tokens Row
                HStack(spacing: 10) {
                    BillMetricBox(
                        icon: "clock.fill",
                        label: "消耗时间 (\(bill.actionCount) 步)",
                        value: String(format: "%.2f 秒", bill.totalDurationSeconds),
                        accent: .green
                    )
                    BillMetricBox(
                        icon: "chart.bar.fill",
                        label: "消耗 Token",
                        value: "\(bill.totalTokens) tok",
                        subvalue: "入:\(bill.inputTokens) 出:\(bill.outputTokens)",
                        accent: .orange
                    )
                }

                // Total Cost Highlight Banner
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本次折算费用 (USD / CNY)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.70))
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "$%.5f", bill.costUSD))
                                .font(.system(size: 18, weight: .heavy, design: .monospaced))
                                .foregroundColor(Color(red: 0.25, green: 0.98, blue: 0.72))
                            Text(String(format: "≈ ¥%.4f", bill.costUSD * 7.20))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.75))
                        }
                    }

                    Spacer()

                    if bill.savedTokens > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("引擎为您省下")
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.cyan.opacity(0.9))
                            Text("-\(bill.savedTokens) tok")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.cyan)
                            Text(String(format: "省 $%.4f", bill.savedCostUSD))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundColor(.white.opacity(0.65))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.cyan.opacity(0.14))
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.cyan.opacity(0.32), lineWidth: 1)
                        )
                )

                // Target Apps Footer
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                    Text("操控目标: \(bill.targetApps.isEmpty ? "桌面窗口" : bill.targetApps.joined(separator: "、"))")
                        .font(.system(size: 10.5))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer()
                }
            }
            .padding(14)
            .frame(width: 356, height: 286)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.07, green: 0.09, blue: 0.14).opacity(0.95),
                                Color(red: 0.04, green: 0.05, blue: 0.09).opacity(0.97)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.75), Color.blue.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.4
                    )
            )
            .shadow(color: Color.black.opacity(0.5), radius: 16, x: 0, y: 8)
        }
    }
}

struct BillMetricBox: View {
    let icon: String
    let label: String
    let value: String
    var subvalue: String? = nil
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(accent.opacity(0.16)))

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.62))
                Text(value)
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let sub = subvalue {
                    Text(sub)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }
}
