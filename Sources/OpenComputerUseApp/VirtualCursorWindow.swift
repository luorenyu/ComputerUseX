import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import OCUCore

/// Subclass of `NSWindow` that disables AppKit's automatic screen/menubar frame clamping,
/// matching Codex's `-[ComputerUse.ComputerUseCursor.Window constrainFrameRect:toScreen:]`.
public final class VirtualCursorNSWindow: NSWindow {
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

public final class VirtualCursorViewModel: ObservableObject, @unchecked Sendable {
    @Published public var isPressed: Bool = false
    @Published public var tiltAngleDegrees: Double = 0.0
    @Published public var stretchScale: Double = 1.0
    @Published public var isVisible: Bool = false

    public init() {}
}

/// Manages the persistent, non-intrusive virtual cursor window (`ComputerUseCursor` equivalent).
/// Never moves the user's physical hardware cursor, orders itself immediately above the target window,
/// follows target window movement automatically, and auto-fades out 2.0s after an action sequence finishes.
public final class VirtualCursorWindowController: @unchecked Sendable {
    public static let shared = VirtualCursorWindowController()

    public let viewModel = VirtualCursorViewModel()
    private var cursorWindow: VirtualCursorNSWindow?
    private var trackedWindowID: UInt32?
    private var trackedPid: Int32?
    private var lastTrackedWindowOrigin: ScreenPoint?
    private var currentScreenPoint: ScreenPoint = ScreenPoint(x: 400, y: 300)
    private var windowTrackTimer: Timer?
    private var autoHideWorkItem: DispatchWorkItem?

    // Tip anchor inside the compact 64x64 window: (18pt from left, 16pt from top => 48pt from bottom)
    private let windowWidth: Double = 64.0
    private let windowHeight: Double = 64.0
    private let tipOffsetX: Double = 18.0
    private let tipOffsetYFromBottom: Double = 48.0

    private init() {}

    public func ensureWindowCreated() {
        DispatchQueue.main.async {
            if self.cursorWindow != nil { return }
            let rect = NSRect(x: 300, y: 300, width: self.windowWidth, height: self.windowHeight)
            let win = VirtualCursorNSWindow(
                contentRect: rect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.level = .floating
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            win.contentView = NSHostingView(rootView: VirtualCursorRootView(viewModel: self.viewModel))
            self.cursorWindow = win

            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                self?.syncWithTargetWindowMoveIfNeeded()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.windowTrackTimer = timer
        }
    }

    public func moveCursor(
        to point: ScreenPoint,
        windowID: UInt32?,
        pid: Int32?,
        tiltAngle: Double = 0.0,
        label: String? = nil
    ) {
        DispatchQueue.main.async {
            self.ensureWindowCreated()
            guard let win = self.cursorWindow else { return }

            self.currentScreenPoint = point
            if let wid = windowID, wid > 0 {
                self.trackedWindowID = wid
                self.trackedPid = pid
                self.lastTrackedWindowOrigin = self.queryWindowOrigin(windowID: wid)
            }

            let origin = self.appKitWindowOrigin(forTipAt: point)
            win.setFrameOrigin(origin)

            if let wid = self.trackedWindowID, wid > 0 {
                win.level = .normal
                win.order(.above, relativeTo: Int(wid))
                if !win.isVisible {
                    win.orderFrontRegardless()
                }
            } else {
                win.level = .floating
                win.orderFrontRegardless()
            }

            self.viewModel.isVisible = true
            withAnimation(.interactiveSpring(response: 0.08, dampingFraction: 0.82)) {
                self.viewModel.tiltAngleDegrees = max(-18.0, min(18.0, tiltAngle))
                self.viewModel.stretchScale = abs(tiltAngle) > 2.5 ? 1.05 : 1.0
            }
            self.scheduleAutoHide(after: 2.0)
        }
    }

    public func setPressed(_ pressed: Bool, at point: ScreenPoint, windowID: UInt32?) {
        DispatchQueue.main.async {
            self.ensureWindowCreated()
            if let win = self.cursorWindow {
                let origin = self.appKitWindowOrigin(forTipAt: point)
                win.setFrameOrigin(origin)
                if let wid = windowID ?? self.trackedWindowID, wid > 0 {
                    win.order(.above, relativeTo: Int(wid))
                }
            }
            self.viewModel.isVisible = true
            withAnimation(.spring(response: 0.12, dampingFraction: 0.65)) {
                self.viewModel.isPressed = pressed
                self.viewModel.tiltAngleDegrees = pressed ? -4.0 : 0.0
                self.viewModel.stretchScale = pressed ? 0.84 : 1.0
            }
            self.scheduleAutoHide(after: 2.0)
        }
    }

    public func hideCursor() {
        DispatchQueue.main.async {
            self.autoHideWorkItem?.cancel()
            self.viewModel.isVisible = false
            self.cursorWindow?.orderOut(nil)
        }
    }

    private func scheduleAutoHide(after seconds: TimeInterval) {
        autoHideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                self.viewModel.isVisible = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
                if !self.viewModel.isVisible {
                    self.cursorWindow?.orderOut(nil)
                }
            }
        }
        autoHideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func appKitWindowOrigin(forTipAt point: ScreenPoint) -> NSPoint {
        let mainHeight = Double(CGDisplayBounds(CGMainDisplayID()).height)
        let nsX = point.x - tipOffsetX
        let nsY = (mainHeight - point.y) - tipOffsetYFromBottom
        return NSPoint(x: nsX, y: nsY)
    }

    private func queryWindowOrigin(windowID: UInt32) -> ScreenPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let first = list.first,
              let bounds = first[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"],
              let y = bounds["Y"] else {
            return nil
        }
        return ScreenPoint(x: Double(x), y: Double(y))
    }

    private func syncWithTargetWindowMoveIfNeeded() {
        guard viewModel.isVisible,
              let wid = trackedWindowID, wid > 0,
              let win = cursorWindow,
              let currentOrigin = queryWindowOrigin(windowID: wid) else {
            return
        }

        if let prevOrigin = lastTrackedWindowOrigin {
            let dx = currentOrigin.x - prevOrigin.x
            let dy = currentOrigin.y - prevOrigin.y
            if abs(dx) > 0.5 || abs(dy) > 0.5 {
                currentScreenPoint = ScreenPoint(
                    x: currentScreenPoint.x + dx,
                    y: currentScreenPoint.y + dy
                )
                win.setFrameOrigin(appKitWindowOrigin(forTipAt: currentScreenPoint))
                win.order(.above, relativeTo: Int(wid))
            }
        }
        lastTrackedWindowOrigin = currentOrigin
    }
}

/// Sleek, tailless futuristic sci-fi cyber-dart pointer shape anchored at (0, 0).
/// Features a sharp aerodynamic delta-chevron silhouette without the traditional mouse stem/tail.
struct VirtualCursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Apex at (0, 0)
        path.move(to: CGPoint(x: 0, y: 0))
        // Left aerodynamic blade edge
        path.addLine(to: CGPoint(x: 1.2, y: 21.5))
        // Inner swept-wing chevron notch (no tail!)
        path.addLine(to: CGPoint(x: 7.4, y: 14.8))
        // Right high-speed wingtip
        path.addLine(to: CGPoint(x: 17.5, y: 12.6))
        path.closeSubpath()
        return path
    }
}

/// Inner holographic core facet inside the futuristic cyber-dart pointer.
struct VirtualCursorCoreFacetShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2.2, y: 3.4))
        path.addLine(to: CGPoint(x: 2.9, y: 14.2))
        path.addLine(to: CGPoint(x: 6.8, y: 10.6))
        path.addLine(to: CGPoint(x: 11.4, y: 9.6))
        path.closeSubpath()
        return path
    }
}

struct VirtualCursorRootView: View {
    @ObservedObject var viewModel: VirtualCursorViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.isVisible {
                // 1. Futuristic Pulse Ring around the cursor tip (18, 16) on press
                if viewModel.isPressed {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.cyan, Color.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2.2
                        )
                        .background(Circle().fill(Color.cyan.opacity(0.22)))
                        .frame(width: 26, height: 26)
                        .position(x: 18, y: 16)
                        .transition(.scale.combined(with: .opacity))
                }

                // 2. Ambient Tip Energy Halo
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                (viewModel.isPressed ? Color.orange : Color.cyan).opacity(0.55),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 9
                        )
                    )
                    .frame(width: 18, height: 18)
                    .position(x: 18, y: 16)

                // 3. Sleek Tailless Sci-Fi Cyber-Dart Pointer (No @eXX badge, no tail)
                ZStack(alignment: .topLeading) {
                    // Outer holographic blade
                    VirtualCursorArrowShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.00, green: 0.96, blue: 1.00), // Electric Cyan
                                    Color(red: 0.16, green: 0.52, blue: 1.00), // Plasma Blue
                                    Color(red: 0.42, green: 0.28, blue: 0.98)  // Cyber Indigo
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            VirtualCursorArrowShape()
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            Color.white,
                                            Color(red: 0.65, green: 0.95, blue: 1.0)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                                )
                        )

                    // Inner glowing energy core facet
                    VirtualCursorCoreFacetShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.85),
                                    (viewModel.isPressed ? Color.orange : Color.cyan).opacity(0.55)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .frame(width: 20, height: 24)
                .shadow(color: Color.cyan.opacity(0.78), radius: 6, x: 0, y: 1)
                .scaleEffect(viewModel.stretchScale, anchor: .topLeading)
                .rotationEffect(.degrees(viewModel.tiltAngleDegrees), anchor: .topLeading)
                .offset(x: 18, y: 16)
            }
        }
        .frame(width: 64, height: 64, alignment: .topLeading)
    }
}
