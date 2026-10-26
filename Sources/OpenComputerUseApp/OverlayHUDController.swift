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
                // 1. Screen Edge Gemini Live Aurora Halo Border (Multi-Layered Diffused Glow)
                if viewModel.showBorderGlow {
                    ZStack {
                        // Outer Soft Diffused Aurora Bloom
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        GeminiPalette.skyBlue.opacity(0.65),
                                        GeminiPalette.blue.opacity(0.70),
                                        GeminiPalette.violet.opacity(0.75),
                                        GeminiPalette.coral.opacity(0.65),
                                        GeminiPalette.skyBlue.opacity(0.65)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 12.0
                            )
                            .blur(radius: 14)

                        // Crisp Inner Gemini Aurora Edge
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        GeminiPalette.skyBlue.opacity(0.90),
                                        GeminiPalette.blue.opacity(0.88),
                                        GeminiPalette.violet.opacity(0.90),
                                        GeminiPalette.coral.opacity(0.85),
                                        GeminiPalette.skyBlue.opacity(0.90)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 3.5
                            )
                            .shadow(color: GeminiPalette.blue.opacity(0.65), radius: 10)
                            .shadow(color: GeminiPalette.violet.opacity(0.55), radius: 18)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }

                // 2. Target Element Highlight Frame (Gemini Aurora Frame with Soft Glow)
                if let rect = viewModel.highlightRect {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(GeminiPalette.auroraGradient, lineWidth: 2.2)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(GeminiPalette.blue.opacity(0.10))
                        )
                        .shadow(color: GeminiPalette.blue.opacity(0.65), radius: 8)
                        .shadow(color: GeminiPalette.violet.opacity(0.45), radius: 14)
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

                // 5. Floating Bottom Gemini Live Status Capsule
                if let title = viewModel.pillTitle {
                    VStack {
                        Spacer()
                        ZStack {
                            // Ambient Aurora Halo behind the Pill
                            Capsule()
                                .fill(GeminiPalette.auroraHorizontalGradient)
                                .frame(width: 380, height: 54)
                                .blur(radius: 18)
                                .opacity(0.42)

                            HStack(spacing: 14) {
                                GeminiSparkleIcon(size: 20, showHalo: true)

                                VStack(alignment: .leading, spacing: 2.5) {
                                    Text(viewModel.operatorBadgeText)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(GeminiPalette.auroraHorizontalGradient)
                                    Text(title)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundColor(.white)
                                    if let sub = viewModel.pillSubtitle, !sub.isEmpty {
                                        Text(sub)
                                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                                            .foregroundColor(Color.white.opacity(0.75))
                                    }
                                }

                                Text("Opt+Esc 急停")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.92))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(GeminiPalette.surfaceElevated)
                                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
                                    )
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 11)
                            .background(
                                Capsule()
                                    .fill(GeminiPalette.canvasDeep.opacity(0.90))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(GeminiPalette.auroraGradient, lineWidth: 1.4)
                                    )
                                    .shadow(color: GeminiPalette.blue.opacity(0.35), radius: 12, y: 2)
                                    .shadow(color: Color.black.opacity(0.45), radius: 14, y: 6)
                            )
                        }
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

    private var strokeGradient: LinearGradient {
        switch ripple.button {
        case .left:
            return GeminiPalette.auroraGradient
        case .right:
            return LinearGradient(colors: [GeminiPalette.peach, GeminiPalette.coral], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .center:
            return LinearGradient(colors: [GeminiPalette.violet, GeminiPalette.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(strokeGradient, lineWidth: 2.8)
                .frame(width: animate ? 62 : 10, height: animate ? 62 : 10)
                .shadow(color: GeminiPalette.blue.opacity(0.7), radius: 6)
                .opacity(animate ? 0.0 : 0.95)

            if ripple.clickCount >= 2 {
                Circle()
                    .stroke(strokeGradient, lineWidth: 2.0)
                    .frame(width: animate ? 86 : 16, height: animate ? 86 : 16)
                    .opacity(animate ? 0.0 : 0.85)
            }

            Circle()
                .fill(GeminiPalette.skyBlue)
                .frame(width: 8, height: 8)
                .shadow(color: GeminiPalette.blue, radius: 4)
                .opacity(animate ? 0.0 : 0.9)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.55)) {
                animate = true
            }
        }
    }
}
