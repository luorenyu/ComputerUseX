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
    private let captureQueue = DispatchQueue(label: "org.opencomputeruse.pip.capture", qos: .userInteractive)
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
            if isFront {
                self.hidePreview()
            } else {
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
            if isFront {
                self.hidePreview()
            } else {
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
            self.viewModel.statusText = text
            if self.viewModel.targetWindowID > 0 {
                self.scheduleAutoHide()
            }
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
            self.viewModel.isVisible = false
            self.panel?.orderOut(nil)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: item)
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

    var body: some View {
        GeometryReader { geo in
            let w = max(1.0, geo.size.width)
            let h = max(1.0, geo.size.height)

            ZStack(alignment: .topLeading) {
                // 1. Edge-to-Edge 1:1 Single Application Window Surface (Zero desktop background / zero black bars)
                if let img = viewModel.previewImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: w, height: h)
                } else {
                    Color(red: 0.08, green: 0.09, blue: 0.12)
                    VStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(viewModel.appName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 2. Scaled Element Highlight inside Single Window
                if let normRect = viewModel.highlightNormRect {
                    let hx = normRect.origin.x * w
                    let hy = normRect.origin.y * h
                    let hw = max(10.0, normRect.size.width * w)
                    let hh = max(8.0, normRect.size.height * h)

                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.cyan, lineWidth: 1.8)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.cyan.opacity(0.14)))
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

                // 4. Scaled Futuristic Tailless Virtual Cursor inside Single Window
                if viewModel.showCursor {
                    let cx = viewModel.cursorNormX * w
                    let cy = viewModel.cursorNormY * h

                    ZStack(alignment: .topLeading) {
                        if viewModel.cursorPressed {
                            Circle()
                                .stroke(Color.cyan, lineWidth: 2)
                                .background(Circle().fill(Color.cyan.opacity(0.28)))
                                .frame(width: 20, height: 20)
                                .offset(x: -10, y: -10)
                        }

                        ZStack(alignment: .topLeading) {
                            VirtualCursorArrowShape()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.00, green: 0.96, blue: 1.00),
                                            Color(red: 0.14, green: 0.56, blue: 1.00),
                                            Color(red: 0.42, green: 0.24, blue: 0.98)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            VirtualCursorCoreFacetShape()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.90),
                                            Color(red: 0.45, green: 0.95, blue: 1.00).opacity(0.65)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            VirtualCursorArrowShape()
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                        }
                        .frame(width: 15, height: 19)
                        .scaleEffect(viewModel.cursorPressed ? 0.80 : 0.92, anchor: .topLeading)
                        .rotationEffect(.degrees(viewModel.cursorTiltDegrees), anchor: .topLeading)
                        .shadow(color: Color.cyan.opacity(0.85), radius: 4, x: 0, y: 1)
                    }
                    .position(x: cx, y: cy)
                }

                // 5. Minimalist Hover Control Overlay (Only appears when user hovers over the mini window)
                if isHovering {
                    HStack(spacing: 6) {
                        Spacer()
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
                            .background(Capsule().fill(Color.black.opacity(0.72)))
                        }
                        .buttonStyle(.plain)

                        Button(action: onClosePreview) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(.white.opacity(0.88))
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.black.opacity(0.72)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .transition(.opacity)
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
        .frame(width: viewModel.panelWidth, height: viewModel.panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(0.65),
                            Color.white.opacity(0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.2
                )
        )
        .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 6)
    }
}

struct MiniPreviewRippleView: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.cyan, lineWidth: 2)
                .frame(width: animate ? 34 : 6, height: animate ? 34 : 6)
                .opacity(animate ? 0.0 : 0.95)
            Circle()
                .fill(Color.cyan)
                .frame(width: 5, height: 5)
                .opacity(animate ? 0.0 : 0.9)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                animate = true
            }
        }
    }
}
