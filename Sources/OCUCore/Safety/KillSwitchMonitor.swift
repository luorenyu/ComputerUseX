import Foundation
import AppKit
import CoreGraphics

public final class KillSwitchMonitor: @unchecked Sendable {
    public static let shared = KillSwitchMonitor()

    private let lock = NSLock()
    private var _isTripped: Bool = false
    private var _lastAgentPoint: ScreenPoint?
    private var _lastAgentMoveTime: Date?
    private var _humanTakeoverEnabled: Bool = true
    private var _hudHandler: ((HUDAnimationEvent) -> Void)?
    private var _actionLogHandler: ((String) -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Sensitive system security processes that should not be blindly clicked unless explicitly allowed
    public var blockedAppNames: Set<String> = [
        "Keychain Access",
        "钥匙串访问",
        "SecurityAgent"
    ]

    private init() {}

    public var isTripped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isTripped
    }

    public var humanTakeoverEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _humanTakeoverEnabled
        }
        set {
            lock.lock()
            _humanTakeoverEnabled = newValue
            lock.unlock()
        }
    }

    public func setHUDHandler(_ handler: @escaping (HUDAnimationEvent) -> Void) {
        lock.lock()
        _hudHandler = handler
        lock.unlock()
    }

    public func setActionLogHandler(_ handler: @escaping (String) -> Void) {
        lock.lock()
        _actionLogHandler = handler
        lock.unlock()
    }

    public func emitHUDEvent(_ event: HUDAnimationEvent) {
        lock.lock()
        let handler = _hudHandler
        lock.unlock()
        handler?(event)
    }

    public func logAction(_ message: String) {
        lock.lock()
        let handler = _actionLogHandler
        lock.unlock()
        handler?(message)
    }

    public func startMonitoringHotkey() {
        guard globalMonitor == nil else { return }
        // Option + Escape (keyCode 53) triggers emergency stop
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 && event.modifierFlags.contains(.option) {
                self?.trip(reason: "User pressed Option+Escape kill switch")
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 && event.modifierFlags.contains(.option) {
                self?.trip(reason: "User pressed Option+Escape kill switch")
                return nil
            }
            return event
        }
    }

    public func trip(reason: String = "Emergency stop triggered") {
        lock.lock()
        _isTripped = true
        lock.unlock()
        emitHUDEvent(.statusPill(title: "🛑 已紧急中止 (Kill Switch)", subtitle: reason))
        emitHUDEvent(.setActiveGlow(false))
        logAction("🛑 \(reason)")
    }

    public func reset() {
        lock.lock()
        _isTripped = false
        _lastAgentPoint = nil
        _lastAgentMoveTime = nil
        lock.unlock()
    }

    public func recordAgentMousePosition(_ point: ScreenPoint) {
        lock.lock()
        _lastAgentPoint = point
        _lastAgentMoveTime = Date()
        lock.unlock()
    }

    public func clearAgentMouseTracking() {
        lock.lock()
        _lastAgentPoint = nil
        _lastAgentMoveTime = nil
        lock.unlock()
    }

    /// Validates that kill switch has not been tripped and user has not forcefully hijacked the physical cursor
    public func verifySafeToProceed(currentMouse: ScreenPoint? = nil) throws {
        lock.lock()
        let tripped = _isTripped
        let takeoverEnabled = _humanTakeoverEnabled
        let expectedPoint = _lastAgentPoint
        let lastTime = _lastAgentMoveTime
        lock.unlock()

        if tripped {
            throw OCUError(
                code: .userAborted,
                message: "Action aborted by Kill Switch (Option+Escape).",
                recoveryHint: "Reset the kill switch or wait for user confirmation before retrying."
            )
        }

        if takeoverEnabled,
           let expected = expectedPoint,
           let lastMove = lastTime,
           Date().timeIntervalSince(lastMove) < 0.8 {
            let actual = currentMouse ?? PermissionManager.shared.currentMouseLocation()
            let drift = actual.distance(to: expected)
            if drift > 75.0 {
                emitHUDEvent(.statusPill(title: "✋ 检测到人工接管鼠标", subtitle: "偏离 \(Int(drift))px，自动让出控制权"))
                emitHUDEvent(.setActiveGlow(false))
                clearAgentMouseTracking()
                throw OCUError(
                    code: .humanTakeover,
                    message: "Physical mouse moved \(Int(drift))px away from agent trajectory; yielding control to user.",
                    recoveryHint: "Wait for user to finish moving the mouse, then take a fresh ocu_snapshot."
                )
            }
        }
    }

    public func verifyAppAllowed(_ appName: String?) throws {
        guard let name = appName, !name.isEmpty else { return }
        if blockedAppNames.contains(name) {
            throw OCUError(
                code: .blockedApp,
                message: "Target application '\(name)' is in the sensitive security blocklist.",
                recoveryHint: "Ask the human user to perform actions inside '\(name)' manually."
            )
        }
    }
}
