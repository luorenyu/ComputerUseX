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

struct VirtualCursorRootView: View {
    @ObservedObject var viewModel: VirtualCursorViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            if viewModel.isVisible {
                UnifiedGeminiCursorView(
                    isPressed: viewModel.isPressed,
                    tiltDegrees: viewModel.tiltAngleDegrees,
                    scale: CGFloat(viewModel.stretchScale)
                )
                .offset(x: 18, y: 16)
            }
        }
        .frame(width: 64, height: 64, alignment: .topLeading)
    }
}
