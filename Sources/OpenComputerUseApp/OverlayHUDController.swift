import Foundation
import AppKit
import SwiftUI
import OCUCore

public struct RippleItem: Identifiable {
    public let id = UUID()
    public let point: ScreenPoint
    public let button: MouseButton
    public let clickCount: Int
    public let createdAt = Date()
}

public final class HUDViewModel: ObservableObject, @unchecked Sendable {
    @Published public var isHUDEnabled: Bool = true
    @Published public var showBorderGlow: Bool = false
    @Published public var pillTitle: String? = nil
    @Published public var pillSubtitle: String? = nil
    @Published public var operatorBadgeText: String = "🤖 Antigravity · Gemini 4 Argon Medium"
    @Published public var trailPoints: [ScreenPoint] = []
    @Published public var highlightRect: ScreenRect? = nil
    @Published public var highlightLabel: String? = nil
    @Published public var ripples: [RippleItem] = []
    @Published public var recentLogs: [String] = []

    private var fadeWorkItem: DispatchWorkItem?
    private var trailClearItem: DispatchWorkItem?
    private var highlightClearItem: DispatchWorkItem?

    public init() {}

    private var isTargetInBackground: Bool {
        let pipVM = MiniPreviewWindowController.shared.viewModel
        guard pipVM.isEnabled, pipVM.targetWindowID > 0 else { return false }
        return !SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(
            windowID: pipVM.targetWindowID,
            pid: pipVM.targetPid
        )
    }

    public func handle(_ event: HUDAnimationEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isHUDEnabled else { return }

            switch event {
            case .pipTargetWindow(let pid, let windowID, let appName, let windowTitle, let windowBounds):
                MiniPreviewWindowController.shared.updateTargetWindow(
                    pid: pid,
                    windowID: windowID,
                    appName: appName,
                    windowTitle: windowTitle,
                    windowBounds: windowBounds
                )

            case .setActiveGlow(let active):
                if self.isTargetInBackground {
                    self.showBorderGlow = false
                    return
                }
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.showBorderGlow = active
                }
                if active {
                    self.scheduleAutoFade()
                }

            case .statusPill(let title, let subtitle):
                if title == "__OPEN_DASHBOARD_CONTROL__" {
                    MainDashboardWindowController.shared.showWindow(section: .control)
                    return
                }
                if title == "__OPEN_DASHBOARD_HISTORY__" {
                    MainDashboardWindowController.shared.showWindow(section: .history)
                    return
                }
                MiniPreviewWindowController.shared.updateStatus(title)
                if self.isTargetInBackground {
                    self.showBorderGlow = false
                    self.pillTitle = nil
                    self.pillSubtitle = nil
                    return
                }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    self.pillTitle = title
                    self.pillSubtitle = subtitle
                    self.showBorderGlow = true
                }
                self.scheduleAutoFade()

            case .pointerTrail:
                self.trailPoints = []

            case .highlightElement(let rect, let label):
                MiniPreviewWindowController.shared.showHighlight(rect: rect, label: label)
                if self.isTargetInBackground {
                    self.highlightRect = nil
                    self.highlightLabel = nil
                    return
                }
                withAnimation(.easeOut(duration: 0.15)) {
                    self.highlightRect = rect
                    self.highlightLabel = nil
                }
                self.highlightClearItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    withAnimation(.easeOut(duration: 0.25)) {
                        self?.highlightRect = nil
                        self?.highlightLabel = nil
                    }
                }
                self.highlightClearItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: item)

            case .clickRipple(let point, let button, let clickCount):
                MiniPreviewWindowController.shared.addClickRipple(at: point)
                if self.isTargetInBackground {
                    return
                }
                let ripple = RippleItem(point: point, button: button, clickCount: clickCount)
                self.ripples.append(ripple)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                    self?.ripples.removeAll { $0.id == ripple.id }
                }
                self.scheduleAutoFade()

            case .virtualCursorMove(let point, let windowID, let pid, let tiltAngle, let label):
                MiniPreviewWindowController.shared.updateCursor(
                    screenPoint: point,
                    windowID: windowID,
                    pid: pid,
                    tiltAngle: tiltAngle,
                    label: label
                )
                let effWid = windowID ?? MiniPreviewWindowController.shared.viewModel.targetWindowID
                let effPid = pid ?? MiniPreviewWindowController.shared.viewModel.targetPid
                let isFront = (effWid == 0) || SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(windowID: effWid, pid: effPid)
                if !isFront && MiniPreviewWindowController.shared.viewModel.isEnabled {
                    VirtualCursorWindowController.shared.hideCursor()
                } else {
                    VirtualCursorWindowController.shared.moveCursor(
                        to: point,
                        windowID: windowID,
                        pid: pid,
                        tiltAngle: tiltAngle,
                        label: label
                    )
                }

            case .virtualCursorPress(let point, let windowID, let isPressed):
                MiniPreviewWindowController.shared.updateCursorPressed(isPressed, screenPoint: point)
                let effWid = windowID ?? MiniPreviewWindowController.shared.viewModel.targetWindowID
                let effPid = MiniPreviewWindowController.shared.viewModel.targetPid
                let isFront = (effWid == 0) || SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(windowID: effWid, pid: effPid)
                if !isFront && MiniPreviewWindowController.shared.viewModel.isEnabled {
                    VirtualCursorWindowController.shared.hideCursor()
                } else {
                    VirtualCursorWindowController.shared.setPressed(
                        isPressed,
                        at: point,
                        windowID: windowID
                    )
                }

            case .virtualCursorHide:
                VirtualCursorWindowController.shared.hideCursor()

            case .operatorStatus(let agentName, let modelName, let currentAction, let actionCount, let totalTokens, let costUSD):
                self.operatorBadgeText = "🤖 \(agentName) · \(modelName)"
                MiniPreviewWindowController.shared.updateOperatorTelemetry(
                    agentName: agentName,
                    modelName: modelName,
                    stepCount: actionCount,
                    costUSD: costUSD
                )
                SessionBillWindowController.shared.updateLiveOperator(
                    agentName: agentName,
                    modelName: modelName,
                    currentAction: currentAction,
                    actionCount: actionCount,
                    totalTokens: totalTokens,
                    costUSD: costUSD
                )
                MainDashboardWindowController.shared.refreshData()

            case .sessionBillCompleted(let bill):
                // Silently record the completed bill without popping up the bottom-right floating bill receipt,
                // and close the Mini PiP preview window now that the task session is truly complete.
                SessionBillWindowController.shared.recordCompletedBillSilently(bill)
                MiniPreviewWindowController.shared.completeAndHidePreview()
                VirtualCursorWindowController.shared.hideCursor()
                MainDashboardWindowController.shared.refreshData()

            case .clear:
                withAnimation(.easeOut(duration: 0.2)) {
                    self.showBorderGlow = false
                    self.pillTitle = nil
                    self.pillSubtitle = nil
                    self.trailPoints = []
                    self.highlightRect = nil
                    self.ripples = []
                }
            }
        }
    }

    public func appendLog(_ entry: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            let stamped = "[\(formatter.string(from: Date()))] \(entry)"
            self.recentLogs.insert(stamped, at: 0)
            if self.recentLogs.count > 25 {
                self.recentLogs.removeLast()
            }
        }
    }

    private func scheduleAutoFade() {
        fadeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            withAnimation(.easeInOut(duration: 0.45)) {
                self?.showBorderGlow = false
                self?.pillTitle = nil
                self?.pillSubtitle = nil
            }
        }
        fadeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8, execute: item)
    }
}

public final class OverlayHUDWindowController: @unchecked Sendable {
    public static let shared = OverlayHUDWindowController()
    public let viewModel = HUDViewModel()
    private var panels: [NSPanel] = []

    private init() {}

    public func setupOverlayWindow() {
        DispatchQueue.main.async {
            guard self.panels.isEmpty else { return }
            for screen in NSScreen.screens {
                let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
                let cgBounds = CGDisplayBounds(screenNumber)
                let originOffset = ScreenPoint(x: Double(cgBounds.origin.x), y: Double(cgBounds.origin.y))

                let overlayPanel = NSPanel(
                    contentRect: screen.frame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                overlayPanel.isOpaque = false
                overlayPanel.backgroundColor = .clear
                overlayPanel.hasShadow = false
                overlayPanel.ignoresMouseEvents = true
                overlayPanel.level = .screenSaver
                overlayPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                overlayPanel.contentView = NSHostingView(
                    rootView: OverlayHUDRootView(viewModel: self.viewModel, screenOrigin: originOffset)
                )
                overlayPanel.orderFrontRegardless()
                self.panels.append(overlayPanel)
            }
        }
    }
}

struct OverlayHUDRootView: View {
    @ObservedObject var viewModel: HUDViewModel
    let screenOrigin: ScreenPoint

    init(viewModel: HUDViewModel, screenOrigin: ScreenPoint = ScreenPoint(x: 0, y: 0)) {
        self.viewModel = viewModel
        self.screenOrigin = screenOrigin
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // 1. Screen Edge Active Glow Border
                if viewModel.showBorderGlow {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.cyan.opacity(0.85),
                                    Color.blue.opacity(0.75),
                                    Color.indigo.opacity(0.85),
                                    Color.cyan.opacity(0.85)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 4.5
                        )
                        .shadow(color: Color.cyan.opacity(0.65), radius: 12)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }

                // 2. Target Element Highlight Frame (Clean futuristic frame, no internal @eXX badge)
                if let rect = viewModel.highlightRect {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.cyan, lineWidth: 2.0)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.cyan.opacity(0.08)))
                        .frame(width: max(12, rect.width), height: max(12, rect.height))
                        .position(
                            x: (rect.x - screenOrigin.x) + rect.width / 2.0,
                            y: (rect.y - screenOrigin.y) + rect.height / 2.0
                        )
                }

                // 4. Click Ripples
                ForEach(viewModel.ripples) { ripple in
                    ClickRippleView(ripple: ripple)
                        .position(
                            x: ripple.point.x - screenOrigin.x,
                            y: ripple.point.y - screenOrigin.y
                        )
                }

                // 5. Floating Bottom Status Pill
                if let title = viewModel.pillTitle {
                    VStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.cyan)
                                .frame(width: 9, height: 9)
                                .shadow(color: .cyan, radius: 4)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(viewModel.operatorBadgeText)
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(.cyan)
                                Text(title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                if let sub = viewModel.pillSubtitle, !sub.isEmpty {
                                    Text(sub)
                                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                                        .foregroundColor(Color.white.opacity(0.78))
                                }
                            }

                            Text("Opt+Esc 急停")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.16)))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.78))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.cyan.opacity(0.55), lineWidth: 1.2)
                                )
                                .shadow(color: Color.black.opacity(0.35), radius: 10, y: 4)
                        )
                        .padding(.bottom, 54)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct ClickRippleView: View {
    let ripple: RippleItem
    @State private var animate = false

    private var color: Color {
        switch ripple.button {
        case .left: return .cyan
        case .right: return .orange
        case .center: return .purple
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 3)
                .frame(width: animate ? 58 : 10, height: animate ? 58 : 10)
                .opacity(animate ? 0.0 : 0.95)

            if ripple.clickCount >= 2 {
                Circle()
                    .stroke(color.opacity(0.85), lineWidth: 2)
                    .frame(width: animate ? 82 : 16, height: animate ? 82 : 16)
                    .opacity(animate ? 0.0 : 0.85)
            }

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .opacity(animate ? 0.0 : 0.9)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) {
                animate = true
            }
        }
    }
}
