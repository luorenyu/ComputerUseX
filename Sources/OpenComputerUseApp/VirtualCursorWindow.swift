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
    @Published public var badgeText: String = "OCU"
    @Published public var isVisible: Bool = false

    public init() {}
}

/// Manages the persistent, non-intrusive virtual cursor window (`ComputerUseCursor` equivalent).
/// Never moves the user's physical hardware cursor and orders itself immediately above the target window
/// (`window.order(.above, relativeTo: Int(targetWindowID))`), following target window movement automatically.
public final class VirtualCursorWindowController: @unchecked Sendable {
    public static let shared = VirtualCursorWindowController()

    public let viewModel = VirtualCursorViewModel()
    private var cursorWindow: VirtualCursorNSWindow?
    private var trackedWindowID: UInt32?
    private var trackedPid: Int32?
    private var lastTrackedWindowOrigin: ScreenPoint?
    private var currentScreenPoint: ScreenPoint = ScreenPoint(x: 400, y: 300)
    private var windowTrackTimer: Timer?

    // Tip anchor inside the 136x68 window: (16pt from left, 14pt from top => 54pt from bottom)
    private let windowWidth: Double = 136.0
    private let windowHeight: Double = 68.0
    private let tipOffsetX: Double = 16.0
    private let tipOffsetYFromBottom: Double = 54.0

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

            // Order immediately above the target window so it never blocks unrelated foreground windows,
            // or float if no specific windowID was resolved.
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

            withAnimation(.interactiveSpring(response: 0.14, dampingFraction: 0.72)) {
                self.viewModel.isVisible = true
                self.viewModel.tiltAngleDegrees = max(-22.0, min(22.0, tiltAngle))
                self.viewModel.stretchScale = abs(tiltAngle) > 2.5 ? 1.08 : 1.0
                if let lbl = label, !lbl.isEmpty {
                    self.viewModel.badgeText = lbl
                }
            }
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
            withAnimation(.spring(response: 0.15, dampingFraction: 0.6)) {
                self.viewModel.isPressed = pressed
                self.viewModel.tiltAngleDegrees = pressed ? -6.0 : 0.0
                self.viewModel.stretchScale = pressed ? 0.85 : 1.0
            }
        }
    }

    public func hideCursor() {
        DispatchQueue.main.async {
            self.viewModel.isVisible = false
            self.cursorWindow?.orderOut(nil)
        }
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

    /// Equivalent to Codex's `-[ComputerUse.ComputerUseCursor windowDidMove:]`:
    /// When the user drags the target application window, the virtual cursor glides with it.
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

struct VirtualCursorArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Crisp macOS-style vector pointer arrow anchored at (0, 0)
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: 22))
        path.addLine(to: CGPoint(x: 5.8, y: 17.2))
        path.addLine(to: CGPoint(x: 9.8, y: 25.5))
        path.addLine(to: CGPoint(x: 13.2, y: 23.8))
        path.addLine(to: CGPoint(x: 9.2, y: 15.5))
        path.addLine(to: CGPoint(x: 16.5, y: 15.5))
        path.closeSubpath()
        return path
    }
}

struct VirtualCursorRootView: View {
    @ObservedObject var viewModel: VirtualCursorViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.isVisible {
                // Press Halo Ring around the cursor tip (16, 14)
                if viewModel.isPressed {
                    Circle()
                        .stroke(Color.cyan, lineWidth: 2.5)
                        .background(Circle().fill(Color.cyan.opacity(0.25)))
                        .frame(width: 28, height: 28)
                        .position(x: 16, y: 14)
                        .transition(.scale.combined(with: .opacity))
                }

                // Vector Cursor + Floating Agent Pill
                ZStack(alignment: .topLeading) {
                    VirtualCursorArrowShape()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.05, green: 0.82, blue: 0.98),
                                    Color(red: 0.22, green: 0.45, blue: 0.98)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            VirtualCursorArrowShape()
                                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                        )
                        .frame(width: 20, height: 28)
                        .shadow(color: Color.cyan.opacity(0.65), radius: 5, x: 0, y: 2)
                        .scaleEffect(viewModel.stretchScale, anchor: .topLeading)
                        .rotationEffect(.degrees(viewModel.tiltAngleDegrees), anchor: .topLeading)

                    // Agent Badge Pill attached near the cursor tail
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.isPressed ? Color.orange : Color.cyan)
                            .frame(width: 5, height: 5)
                        Text(viewModel.badgeText)
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.82))
                            .overlay(
                                Capsule().strokeBorder(Color.cyan.opacity(0.7), lineWidth: 1)
                            )
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: 16, y: 20)
                }
                .offset(x: 16, y: 14)
            }
        }
        .frame(width: 136, height: 68, alignment: .topLeading)
    }
}
