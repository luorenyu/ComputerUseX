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
    @Published public var windowBounds: ScreenRect = ScreenRect(x: 0, y: 0, width: 1280, height: 800)
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

    private let panelWidth: Double = 344.0
    private let panelHeight: Double = 242.0

    private init() {}

    public func ensureWindowCreated() {
        DispatchQueue.main.async {
            if self.panel != nil { return }
            let screenFrame = NSScreen.screens.first?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let originX = screenFrame.maxX - self.panelWidth - 18.0
            let originY = screenFrame.minY + 18.0
            let rect = NSRect(x: originX, y: originY, width: self.panelWidth, height: self.panelHeight)

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
            }
            let isFront = SyntheticFocusEnforcer.shared.isWindowFrontmostOnScreen(windowID: windowID, pid: pid)
            self.viewModel.isBackgroundMode = !isFront
            self.showPreviewWindow()
            self.triggerImmediateCapture()
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
            self.showPreviewWindow()
            self.triggerImmediateCapture()
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
            self.triggerImmediateCapture()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 14.0, execute: item)
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
                }
                if self.viewModel.isBackgroundMode != !isFront {
                    self.viewModel.isBackgroundMode = !isFront
                    if !isFront {
                        // Target window went to background -> hide desktop cursor and keep cursor in Mini PiP!
                        VirtualCursorWindowController.shared.hideCursor()
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

    var body: some View {
        VStack(spacing: 0) {
            // 1. Top Header Bar
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.isBackgroundMode ? Color.cyan : Color.green)
                    .frame(width: 7, height: 7)
                    .shadow(color: viewModel.isBackgroundMode ? .cyan : .green, radius: 3)

                Text("\(viewModel.appName) #\(viewModel.targetWindowID)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(viewModel.isBackgroundMode ? "后台静默协作" : "前台同步")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(viewModel.isBackgroundMode ? Color.cyan : Color.green)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Capsule()
                            .fill((viewModel.isBackgroundMode ? Color.cyan : Color.green).opacity(0.18))
                    )

                Spacer()

                Button(action: onSummonWindow) {
                    HStack(spacing: 3) {
                        Image(systemName: "macwindow.on.rectangle")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("唤起")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.85))
                    )
                }
                .buttonStyle(.plain)
                .help("点击将正在后台操作的真实窗口唤起到最前面")

                Button(action: onClosePreview) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.65))

            // 2. Live Window Stream Canvas + Scaled Virtual Cursor & Ripples
            GeometryReader { geo in
                let canvasSize = geo.size
                let fitted = aspectFitRect(
                    sourceSize: CGSize(
                        width: max(1, viewModel.windowBounds.width),
                        height: max(1, viewModel.windowBounds.height)
                    ),
                    in: canvasSize
                )

                ZStack(alignment: .topLeading) {
                    Color(red: 0.06, green: 0.07, blue: 0.10)

                    if let img = viewModel.previewImage {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: fitted.width, height: fitted.height)
                            .cornerRadius(5)
                            .position(x: fitted.midX, y: fitted.midY)
                    } else {
                        VStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("正在连接窗口画面...")
                                .font(.system(size: 10.5))
                                .foregroundColor(.white.opacity(0.65))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Scaled Element Highlight inside Mini Preview
                    if let normRect = viewModel.highlightNormRect {
                        let hx = fitted.minX + normRect.origin.x * fitted.width
                        let hy = fitted.minY + normRect.origin.y * fitted.height
                        let hw = max(10.0, normRect.size.width * fitted.width)
                        let hh = max(8.0, normRect.size.height * fitted.height)

                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.cyan, lineWidth: 1.8)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.cyan.opacity(0.16)))
                            .frame(width: hw, height: hh)
                            .position(x: hx + hw / 2.0, y: hy + hh / 2.0)
                    }

                    // Scaled Click Ripples inside Mini Preview
                    ForEach(viewModel.ripples) { ripple in
                        let rx = fitted.minX + ripple.normX * fitted.width
                        let ry = fitted.minY + ripple.normY * fitted.height
                        MiniPreviewRippleView()
                            .position(x: rx, y: ry)
                    }

                    // Scaled Virtual Cursor + Badge inside Mini Preview
                    if viewModel.showCursor {
                        let cx = fitted.minX + viewModel.cursorNormX * fitted.width
                        let cy = fitted.minY + viewModel.cursorNormY * fitted.height

                        ZStack(alignment: .topLeading) {
                            if viewModel.cursorPressed {
                                Circle()
                                    .stroke(Color.cyan, lineWidth: 2)
                                    .background(Circle().fill(Color.cyan.opacity(0.28)))
                                    .frame(width: 20, height: 20)
                                    .offset(x: -10, y: -10)
                            }

                            VirtualCursorArrowShape()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.05, green: 0.85, blue: 1.0),
                                            Color(red: 0.20, green: 0.48, blue: 0.98)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .overlay(
                                    VirtualCursorArrowShape()
                                        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
                                )
                                .frame(width: 14, height: 20)
                                .scaleEffect(viewModel.cursorPressed ? 0.84 : 0.76, anchor: .topLeading)
                                .rotationEffect(.degrees(viewModel.cursorTiltDegrees), anchor: .topLeading)
                                .shadow(color: Color.cyan.opacity(0.8), radius: 4, x: 0, y: 1)

                            Text(viewModel.cursorBadge)
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4.5)
                                .padding(.vertical, 1.5)
                                .background(
                                    Capsule()
                                        .fill(Color.black.opacity(0.85))
                                        .overlay(Capsule().strokeBorder(Color.cyan.opacity(0.8), lineWidth: 0.8))
                                )
                                .offset(x: 11, y: 13)
                        }
                        .position(x: cx, y: cy)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onSummonWindow()
                }
            }
            .frame(height: 174)

            // 3. Bottom Action Status Footer
            HStack(spacing: 6) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 10))
                    .foregroundColor(.cyan)
                Text(viewModel.statusText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                Spacer()
                Text("点击小窗唤起真实界面")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.75))
        }
        .frame(width: 344, height: 242)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(viewModel.isBackgroundMode ? 0.75 : 0.4),
                            Color.blue.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.4
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 14, x: 0, y: 6)
    }

    private func aspectFitRect(sourceSize: CGSize, in containerSize: CGSize) -> CGRect {
        let pad: CGFloat = 6.0
        let availW = max(10.0, containerSize.width - pad * 2)
        let availH = max(10.0, containerSize.height - pad * 2)
        let scale = min(availW / max(1.0, sourceSize.width), availH / max(1.0, sourceSize.height))
        let w = sourceSize.width * scale
        let h = sourceSize.height * scale
        let x = (containerSize.width - w) / 2.0
        let y = (containerSize.height - h) / 2.0
        return CGRect(x: x, y: y, width: w, height: h)
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
