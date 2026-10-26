import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import OCUCore

public final class MiniPreviewPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

public struct MiniPreviewRipple: Identifiable {
    public let id = UUID()
    public let normX: Double
    public let normY: Double
}

public final class MiniPreviewViewModel: ObservableObject, @unchecked Sendable {
    @Published public var isEnabled: Bool = true
    @Published public var isVisible: Bool = false
    @Published public var isBackgroundMode: Bool = false
    @Published public var targetPid: Int32 = 0
    @Published public var targetWindowID: UInt32 = 0
    @Published public var appName: String = "App"
    @Published public var windowTitle: String = ""
    @Published public var windowBounds: ScreenRect = ScreenRect(x: 0, y: 0, width: 800, height: 760)
    @Published public var panelWidth: Double = 280.0
    @Published public var panelHeight: Double = 266.0
    @Published public var previewImage: NSImage? = nil

    // Scaled cursor state in normalized window coordinates [0, 1]
    @Published public var showCursor: Bool = false
    @Published public var cursorNormX: Double = 0.5
    @Published public var cursorNormY: Double = 0.5
    @Published public var cursorPressed: Bool = false
    @Published public var cursorTiltDegrees: Double = 0.0
    @Published public var cursorBadge: String = "OCU"
    @Published public var statusText: String = "后台协作就绪"
    @Published public var operatorAgentName: String = "Antigravity"
    @Published public var operatorModelName: String = "Gemini 4 Argon Medium"
    @Published public var operatorStepCount: Int = 0
    @Published public var operatorCostUSD: Double = 0.0

    // Scaled highlight rect in normalized window coordinates [0, 1]
    @Published public var highlightNormRect: CGRect? = nil
    @Published public var highlightLabel: String? = nil
    @Published public var ripples: [MiniPreviewRipple] = []

    public var lastScreenPoint: ScreenPoint = ScreenPoint(x: 400, y: 300)

    public init() {}
}

/// Codex-style Mini PiP Live Preview Portal (`RemoteHostedPIPContentPublisher` / `RemoteHostedPIPContentStream` equivalent).
/// Streams the target background window (`SCContentFilter(desktopIndependentWindow:)`) and renders the scaled
/// virtual cursor, element highlights, and click ripples inside a compact floating corner window.
/// Clicking the preview summons (`kAXRaiseAction` + `activate()`) the real target window to the foreground.
public final class MiniPreviewWindowController: @unchecked Sendable {
    public static let shared = MiniPreviewWindowController()

    public let viewModel = MiniPreviewViewModel()
    private var panel: MiniPreviewPanel?
    private var captureTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?
    private var thinkingStatusWorkItem: DispatchWorkItem?
    private let captureQueue = DispatchQueue(label: "org.computerusex.pip.capture", qos: .userInteractive)
    private var isCapturingFrame = false

    private let maxPanelEdge: Double = 300.0
    private let minPanelEdge: Double = 150.0

    private init() {}

    /// Computes exact 1:1 aspect-ratio matched dimensions for the floating single-window preview.
    private func computePanelSize(for bounds: ScreenRect) -> NSSize {
        let w = max(80.0, bounds.width)
        let h = max(80.0, bounds.height)
        let aspect = max(0.38, min(2.6, w / h))
        let targetW: Double
        let targetH: Double
        if aspect >= 1.0 {
            targetW = maxPanelEdge
            targetH = max(minPanelEdge, (maxPanelEdge / aspect).rounded())
        } else {
            targetH = maxPanelEdge
            targetW = max(minPanelEdge, (maxPanelEdge * aspect).rounded())
        }
        return NSSize(width: targetW, height: targetH)
    }

    private func updatePanelAspectSize(for bounds: ScreenRect) {
        let newSize = computePanelSize(for: bounds)
        let sizeChanged = abs(viewModel.panelWidth - newSize.width) > 1.5 || abs(viewModel.panelHeight - newSize.height) > 1.5
        viewModel.panelWidth = newSize.width
        viewModel.panelHeight = newSize.height
        guard sizeChanged, let panel = self.panel else { return }
        let oldFrame = panel.frame
        // Anchor to bottom-right so resizing stays neatly tucked in the corner
        let newOriginX = oldFrame.maxX - newSize.width
        let newOriginY = oldFrame.minY
        panel.setFrame(
            NSRect(x: newOriginX, y: newOriginY, width: newSize.width, height: newSize.height),
            display: true,
            animate: false
        )
    }

    public func ensureWindowCreated() {
        DispatchQueue.main.async {
            if self.panel != nil { return }
            let screenFrame = NSScreen.screens.first?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let initialSize = self.computePanelSize(for: self.viewModel.windowBounds)
            self.viewModel.panelWidth = initialSize.width
            self.viewModel.panelHeight = initialSize.height
            let originX = screenFrame.maxX - initialSize.width - 18.0
            let originY = screenFrame.minY + 18.0
            let rect = NSRect(x: originX, y: originY, width: initialSize.width, height: initialSize.height)

            let win = MiniPreviewPanel(
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
                rootView: MiniPreviewRootView(
                    viewModel: self.viewModel,
                    onSummonWindow: { [weak self] in
                        self?.summonTargetWindow()
                    },
                    onClosePreview: { [weak self] in
                        self?.hidePreview()
                    }
                )
            )
            self.panel = win

            let timer = Timer(timeInterval: 0.24, repeats: true) { [weak self] _ in
                self?.refreshThumbnailIfNeeded()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.captureTimer = timer
        }
    }

    public func updateTargetWindow(
        pid: Int32,
        windowID: UInt32,
        appName: String,
        windowTitle: String?,
        windowBounds: ScreenRect
    ) {
        guard viewModel.isEnabled, windowID > 0 else { return }
        let lowerApp = appName.lowercased()
        if lowerApp.contains("computerusex") || lowerApp.contains("opencomputeruse") { return }
        DispatchQueue.main.async {
            self.ensureWindowCreated()
            self.viewModel.targetPid = pid
            self.viewModel.targetWindowID = windowID
            self.viewModel.appName = appName
            if let title = windowTitle, !title.isEmpty {
                self.viewModel.windowTitle = title
            }
            if windowBounds.width >= 80 && windowBounds.height >= 80 {
                self.viewModel.windowBounds = windowBounds
                self.updatePanelAspectSize(for: windowBounds)
            }
            let isFront = SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(windowID: windowID, pid: pid)
            self.viewModel.isBackgroundMode = !isFront
            // Once a session preview is open (or when the target window is in background), keep it continuously visible
            // throughout the entire Agent task session without flickering between steps!
            if !isFront || self.viewModel.isVisible {
                self.showPreviewWindow()
                self.triggerImmediateCapture()
            }
        }
    }

    public func updateCursor(
        screenPoint: ScreenPoint,
        windowID: UInt32?,
        pid: Int32?,
        tiltAngle: Double,
        label: String?
    ) {
        guard viewModel.isEnabled else { return }
        DispatchQueue.main.async {
            self.ensureWindowCreated()
            self.viewModel.lastScreenPoint = screenPoint
            if let wid = windowID, wid > 0 {
                self.viewModel.targetWindowID = wid
            }
            if let p = pid, p > 0 {
                self.viewModel.targetPid = p
            }

            let bounds = self.viewModel.windowBounds
            if bounds.width > 10 && bounds.height > 10 {
                let nx = max(0.0, min(1.0, (screenPoint.x - bounds.x) / bounds.width))
                let ny = max(0.0, min(1.0, (screenPoint.y - bounds.y) / bounds.height))
                withAnimation(.interactiveSpring(response: 0.12, dampingFraction: 0.78)) {
                    self.viewModel.cursorNormX = nx
                    self.viewModel.cursorNormY = ny
                    self.viewModel.cursorTiltDegrees = max(-20.0, min(20.0, tiltAngle))
                    self.viewModel.showCursor = true
                    if let lbl = label, !lbl.isEmpty {
                        self.viewModel.cursorBadge = lbl
                    }
                }
            }
            let isFront = SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(
                windowID: self.viewModel.targetWindowID,
                pid: self.viewModel.targetPid
            )
            self.viewModel.isBackgroundMode = !isFront
            if !isFront || self.viewModel.isVisible {
                self.showPreviewWindow()
                self.triggerImmediateCapture()
            }
        }
    }

    public func updateCursorPressed(_ pressed: Bool, screenPoint: ScreenPoint) {
        guard viewModel.isEnabled else { return }
        DispatchQueue.main.async {
            let bounds = self.viewModel.windowBounds
            if bounds.width > 10 && bounds.height > 10 {
                let nx = max(0.0, min(1.0, (screenPoint.x - bounds.x) / bounds.width))
                let ny = max(0.0, min(1.0, (screenPoint.y - bounds.y) / bounds.height))
                self.viewModel.cursorNormX = nx
                self.viewModel.cursorNormY = ny
            }
            withAnimation(.spring(response: 0.15, dampingFraction: 0.65)) {
                self.viewModel.cursorPressed = pressed
            }
            if !pressed {
                self.triggerImmediateCapture()
            }
        }
    }

    public func showHighlight(rect: ScreenRect, label: String?) {
        guard viewModel.isEnabled else { return }
        DispatchQueue.main.async {
            let b = self.viewModel.windowBounds
            guard b.width > 10, b.height > 10 else { return }
            let nx = max(0.0, min(1.0, (rect.x - b.x) / b.width))
            let ny = max(0.0, min(1.0, (rect.y - b.y) / b.height))
            let nw = max(0.02, min(1.0 - nx, rect.width / b.width))
            let nh = max(0.02, min(1.0 - ny, rect.height / b.height))
            withAnimation(.easeOut(duration: 0.15)) {
                self.viewModel.highlightNormRect = CGRect(x: nx, y: ny, width: nw, height: nh)
                self.viewModel.highlightLabel = label
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                withAnimation(.easeOut(duration: 0.2)) {
                    self?.viewModel.highlightNormRect = nil
                    self?.viewModel.highlightLabel = nil
                }
            }
        }
    }

    public func addClickRipple(at point: ScreenPoint) {
        guard viewModel.isEnabled else { return }
        DispatchQueue.main.async {
            let b = self.viewModel.windowBounds
            guard b.width > 10, b.height > 10 else { return }
            let nx = max(0.0, min(1.0, (point.x - b.x) / b.width))
            let ny = max(0.0, min(1.0, (point.y - b.y) / b.height))
            let ripple = MiniPreviewRipple(normX: nx, normY: ny)
            self.viewModel.ripples.append(ripple)
            self.triggerImmediateCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.viewModel.ripples.removeAll { $0.id == ripple.id }
            }
        }
    }

    public func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.viewModel.statusText = GeminiPalette.cleanStatusText(text)
            if self.viewModel.targetWindowID > 0 {
                self.scheduleAutoHide()
            }
        }
    }

    public func updateOperatorTelemetry(
        agentName: String,
        modelName: String,
        stepCount: Int,
        costUSD: Double
    ) {
        DispatchQueue.main.async {
            self.viewModel.operatorAgentName = agentName
            self.viewModel.operatorModelName = modelName
            self.viewModel.operatorStepCount = stepCount
            self.viewModel.operatorCostUSD = costUSD
        }
    }

    /// Invoked when the user clicks the Mini PiP preview window:
    /// Unminimizes, raises (`kAXRaiseAction`), and activates the real target window to the foreground,
    /// and seamlessly transfers the virtual cursor to the real desktop window!
    public func summonTargetWindow() {
        let pid = viewModel.targetPid
        let wid = viewModel.targetWindowID
        let pt = viewModel.lastScreenPoint
        let badge = viewModel.cursorBadge
        guard pid > 0, wid > 0 else { return }

        AXScanner.shared.raiseWindow(pid: pid, windowID: wid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.viewModel.isBackgroundMode = false
            self.viewModel.statusText = "已唤起真实窗口至前台"
            VirtualCursorWindowController.shared.moveCursor(
                to: pt,
                windowID: wid,
                pid: pid,
                tiltAngle: 0.0,
                label: badge
            )
            self.hidePreview()
        }
    }

    public func hidePreview() {
        DispatchQueue.main.async {
            self.autoHideWorkItem?.cancel()
            self.thinkingStatusWorkItem?.cancel()
            self.viewModel.isVisible = false
            self.panel?.orderOut(nil)
        }
    }

    /// Smoothly transitions the preview status to "task finished" and hides the window once the Agent completes its session.
    public func completeAndHidePreview() {
        DispatchQueue.main.async {
            self.autoHideWorkItem?.cancel()
            self.thinkingStatusWorkItem?.cancel()
            guard self.viewModel.isVisible else { return }
            self.viewModel.statusText = "本次操作任务已完成"
            let item = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.viewModel.isVisible = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                    if !self.viewModel.isVisible {
                        self.panel?.orderOut(nil)
                    }
                }
            }
            self.autoHideWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
        }
    }

    private func showPreviewWindow() {
        guard viewModel.isEnabled, viewModel.targetWindowID > 0 else { return }
        ensureWindowCreated()
        if let panel = self.panel {
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            self.viewModel.isVisible = true
        }
        scheduleAutoHide()
    }

    private func scheduleAutoHide() {
        autoHideWorkItem?.cancel()
        thinkingStatusWorkItem?.cancel()

        // Between Agent tool calls (while LLM is analyzing the snapshot and planning the next step),
        // keep the preview window open and show a clear "Agent thinking" indicator after 2.0s!
        let thinkingItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.viewModel.isVisible else { return }
            self.viewModel.statusText = "Agent 正在分析与规划下一步..."
        }
        thinkingStatusWorkItem = thinkingItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: thinkingItem)

        // Only auto-hide if no further Agent activity occurs for 45 seconds (matching session timeout)
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                self.viewModel.isVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                if !self.viewModel.isVisible {
                    self.panel?.orderOut(nil)
                }
            }
        }
        autoHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 45.0, execute: item)
    }

    private func triggerImmediateCapture() {
        refreshThumbnailIfNeeded()
    }

    private func refreshThumbnailIfNeeded() {
        guard viewModel.isEnabled,
              viewModel.isVisible,
              let panel = panel,
              panel.isVisible else {
            return
        }
        let wid = viewModel.targetWindowID
        let pid = viewModel.targetPid
        guard wid > 0 else { return }
        if isCapturingFrame { return }
        isCapturingFrame = true

        captureQueue.async { [weak self] in
            defer { self?.isCapturingFrame = false }
            guard let self = self else { return }
            guard let captured = ScreenCaptureService.shared.captureWindowThumbnail(windowID: wid, maxDimension: 680) else {
                return
            }
            let nsImage = NSImage(
                cgImage: captured.image,
                size: NSSize(width: captured.image.width, height: captured.image.height)
            )
            let isFront = SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(windowID: wid, pid: pid)
            DispatchQueue.main.async {
                self.viewModel.previewImage = nsImage
                if captured.bounds.width >= 80 && captured.bounds.height >= 80 {
                    self.viewModel.windowBounds = captured.bounds
                    self.updatePanelAspectSize(for: captured.bounds)
                }
                if self.viewModel.isBackgroundMode != !isFront {
                    self.viewModel.isBackgroundMode = !isFront
                    if !isFront {
                        // Target window went to background -> hide desktop cursor and keep cursor in Mini PiP!
                        VirtualCursorWindowController.shared.hideCursor()
                    } else {
                        self.hidePreview()
                    }
                }
            }
        }
    }
}

struct MiniPreviewRootView: View {
    @ObservedObject var viewModel: MiniPreviewViewModel
    let onSummonWindow: () -> Void
    let onClosePreview: () -> Void
    @State private var isHovering: Bool = false

    private let haloInset: CGFloat = 10.0

    var body: some View {
        let cardW = max(80.0, viewModel.panelWidth - Double(haloInset * 2))
        let cardH = max(80.0, viewModel.panelHeight - Double(haloInset * 2))

        ZStack {
            // Outer Diffused Google Gemini Aurora Halo behind the preview window
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(GeminiPalette.auroraGradient, lineWidth: 3.5)
                .frame(width: cardW, height: cardH)
                .blur(radius: 6.5)
                .opacity(0.85)

            GeometryReader { geo in
                let w = max(1.0, geo.size.width)
                let h = max(1.0, geo.size.height)

                ZStack(alignment: .topLeading) {
                    // 1. Edge-to-Edge 1:1 Single Application Window Surface
                    if let img = viewModel.previewImage {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: w, height: h)
                    } else {
                        GeminiPalette.canvasDeep
                        VStack(spacing: 7) {
                            GeminiSparkleIcon(size: 20, showHalo: true)
                            Text(viewModel.appName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(.white.opacity(0.82))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Bottom Ambient Gemini Live Aurora Light Leak
                    VStack {
                        Spacer()
                        LinearGradient(
                            colors: [
                                Color.clear,
                                GeminiPalette.blue.opacity(0.20),
                                GeminiPalette.violet.opacity(0.32)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 44)
                    }
                    .allowsHitTesting(false)

                    // 2. Scaled Element Highlight inside Single Window (Gemini Aurora Frame)
                    if let normRect = viewModel.highlightNormRect {
                        let hx = normRect.origin.x * w
                        let hy = normRect.origin.y * h
                        let hw = max(10.0, normRect.size.width * w)
                        let hh = max(8.0, normRect.size.height * h)

                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(GeminiPalette.auroraGradient, lineWidth: 2.0)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(GeminiPalette.blue.opacity(0.16))
                            )
                            .shadow(color: GeminiPalette.blue.opacity(0.65), radius: 5)
                            .frame(width: hw, height: hh)
                            .position(x: hx + hw / 2.0, y: hy + hh / 2.0)
                    }

                    // 3. Scaled Click Ripples inside Single Window
                    ForEach(viewModel.ripples) { ripple in
                        let rx = ripple.normX * w
                        let ry = ripple.normY * h
                        MiniPreviewRippleView()
                            .position(x: rx, y: ry)
                    }

                    // 4. Unified Google Gemini Pointer (Identical style to Desktop Virtual Cursor!)
                    if viewModel.showCursor {
                        let cx = viewModel.cursorNormX * w
                        let cy = viewModel.cursorNormY * h

                        UnifiedGeminiCursorView(
                            isPressed: viewModel.cursorPressed,
                            tiltDegrees: viewModel.cursorTiltDegrees,
                            scale: 0.88
                        )
                        .offset(x: cx, y: cy)
                    }

                    // 5. Top Bar: Gemini Sparkle Operator Pill + Hover Controls
                    VStack {
                        HStack(spacing: 6) {
                            HStack(spacing: 5) {
                                GeminiSparkleIcon(size: 11, showHalo: true)
                                Text("\(viewModel.operatorAgentName) · \(viewModel.operatorModelName)")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                if viewModel.operatorCostUSD > 0 {
                                    Text(String(format: "$%.4f", viewModel.operatorCostUSD))
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundColor(GeminiPalette.mint)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(GeminiPalette.canvasDeep.opacity(0.82))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(GeminiPalette.subtleBorderGradient, lineWidth: 1.0)
                                    )
                                    .shadow(color: GeminiPalette.blue.opacity(0.35), radius: 6)
                            )

                            Spacer()

                            if isHovering {
                                Button(action: onSummonWindow) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "macwindow.on.rectangle")
                                            .font(.system(size: 9.5, weight: .bold))
                                        Text("唤起 \(viewModel.appName)")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(GeminiPalette.canvasDeep.opacity(0.85))
                                            .overlay(Capsule().strokeBorder(GeminiPalette.auroraGradient, lineWidth: 0.9))
                                    )
                                }
                                .buttonStyle(.plain)

                                Button(action: onClosePreview) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundColor(.white.opacity(0.9))
                                        .frame(width: 20, height: 20)
                                        .background(Circle().fill(GeminiPalette.canvasDeep.opacity(0.85)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)

                        Spacer()

                        // 6. Bottom Gemini Mobile Live Status Bar
                        HStack(spacing: 6) {
                            GeminiSparkleIcon(size: 10, showHalo: false)
                            Text(viewModel.statusText)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background(
                            Capsule()
                                .fill(GeminiPalette.canvasDeep.opacity(0.82))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(GeminiPalette.subtleBorderGradient, lineWidth: 0.9)
                                )
                                .shadow(color: GeminiPalette.violet.opacity(0.40), radius: 6)
                        )
                        .padding(.horizontal, 8)
                        .padding(.bottom, 7)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSummonWindow()
                }
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovering = hovering
                    }
                }
            }
            .frame(width: cardW, height: cardH)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(GeminiPalette.auroraGradient, lineWidth: 1.6)
            )
            .shadow(color: GeminiPalette.violet.opacity(0.35), radius: 10, x: 0, y: 2)
            .shadow(color: Color.black.opacity(0.48), radius: 12, x: 0, y: 6)
        }
        .frame(width: viewModel.panelWidth, height: viewModel.panelHeight)
    }
}

struct MiniPreviewRippleView: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(GeminiPalette.auroraGradient, lineWidth: 2.2)
                .frame(width: animate ? 36 : 6, height: animate ? 36 : 6)
                .opacity(animate ? 0.0 : 0.95)
            Circle()
                .fill(GeminiPalette.skyBlue)
                .frame(width: 6, height: 6)
                .shadow(color: GeminiPalette.blue, radius: 4)
                .opacity(animate ? 0.0 : 0.9)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                animate = true
            }
        }
    }
}
