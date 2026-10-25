import Foundation

public enum OCUErrorCode: String, Codable, Sendable {
    case permissionDenied = "ERR_PERMISSION_DENIED"
    case elementNotFound = "ERR_ELEMENT_NOT_FOUND"
    case elementStale = "ERR_ELEMENT_STALE"
    case appNotFound = "ERR_APP_NOT_FOUND"
    case userAborted = "ERR_USER_ABORTED"
    case humanTakeover = "ERR_HUMAN_TAKEOVER"
    case blockedApp = "ERR_BLOCKED_SENSITIVE_APP"
    case invalidArguments = "ERR_INVALID_ARGUMENTS"
    case captureFailed = "ERR_SCREEN_CAPTURE_FAILED"
    case actionFailed = "ERR_ACTION_FAILED"
    case timeout = "ERR_TIMEOUT"
    case ipcError = "ERR_IPC_ERROR"
}

public struct OCUError: Error, LocalizedError, Codable, Equatable, Sendable {
    public var code: OCUErrorCode
    public var message: String
    public var recoveryHint: String

    public init(code: OCUErrorCode, message: String, recoveryHint: String) {
        self.code = code
        self.message = message
        self.recoveryHint = recoveryHint
    }

    public var errorDescription: String? {
        "[\(code.rawValue)] \(message) (Hint: \(recoveryHint))"
    }
}

public enum MouseButton: String, Codable, Sendable {
    case left = "left"
    case right = "right"
    case center = "center"
}

public struct PermissionStatus: Codable, Equatable, Sendable {
    public var accessibilityGranted: Bool
    public var screenRecordingGranted: Bool
    public var daemonConnected: Bool
    public var socketPath: String
    public var activeApp: String?
    public var mouseLocation: ScreenPoint
    public var screenBounds: ScreenRect
    public var scaleFactor: Double
    public var killSwitchTripped: Bool

    public init(
        accessibilityGranted: Bool,
        screenRecordingGranted: Bool,
        daemonConnected: Bool,
        socketPath: String,
        activeApp: String?,
        mouseLocation: ScreenPoint,
        screenBounds: ScreenRect,
        scaleFactor: Double,
        killSwitchTripped: Bool
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.daemonConnected = daemonConnected
        self.socketPath = socketPath
        self.activeApp = activeApp
        self.mouseLocation = mouseLocation
        self.screenBounds = screenBounds
        self.scaleFactor = scaleFactor
        self.killSwitchTripped = killSwitchTripped
    }
}

public enum HUDAnimationEvent: Codable, Equatable, Sendable {
    case setActiveGlow(Bool)
    case statusPill(title: String, subtitle: String?)
    case pointerTrail(points: [ScreenPoint])
    case highlightElement(rect: ScreenRect, label: String?)
    case clickRipple(point: ScreenPoint, button: MouseButton, clickCount: Int)
    case virtualCursorMove(point: ScreenPoint, windowID: UInt32?, pid: Int32?, tiltAngle: Double, label: String?)
    case virtualCursorPress(point: ScreenPoint, windowID: UInt32?, isPressed: Bool)
    case virtualCursorHide
    case pipTargetWindow(pid: Int32, windowID: UInt32, appName: String, windowTitle: String?, windowBounds: ScreenRect)
    case clear
}

public struct ActionOutcome: Codable, Equatable, Sendable {
    public var success: Bool
    public var action: String
    public var targetDescription: String
    public var point: ScreenPoint?
    public var details: String?
    public var elapsedMs: Int

    public init(
        success: Bool = true,
        action: String,
        targetDescription: String,
        point: ScreenPoint? = nil,
        details: String? = nil,
        elapsedMs: Int = 0
    ) {
        self.success = success
        self.action = action
        self.targetDescription = targetDescription
        self.point = point
        self.details = details
        self.elapsedMs = elapsedMs
    }
}

public struct IPCRequest: Codable, Sendable {
    public var id: String
    public var command: String
    public var app: String?
    public var windowID: UInt32?
    public var target: String?
    public var toTarget: String?
    public var x: Double?
    public var y: Double?
    public var toX: Double?
    public var toY: Double?
    public var dx: Double?
    public var dy: Double?
    public var width: Double?
    public var height: Double?
    public var text: String?
    public var keys: String?
    public var button: MouseButton?
    public var clickCount: Int?
    public var ocr: Bool?
    public var som: Bool?
    public var axNative: Bool?
    public var submit: Bool?
    public var clearFirst: Bool?
    public var launch: Bool?
    public var focus: Bool?
    public var compact: Bool?
    public var windowOnly: Bool?
    public var virtualCursor: Bool?
    public var timeout: Double?
    public var outputPath: String?
    public var hudEvent: HUDAnimationEvent?
    public var steps: [IPCRequest]?

    public init(
        id: String = UUID().uuidString,
        command: String,
        app: String? = nil,
        windowID: UInt32? = nil,
        target: String? = nil,
        toTarget: String? = nil,
        x: Double? = nil,
        y: Double? = nil,
        toX: Double? = nil,
        toY: Double? = nil,
        dx: Double? = nil,
        dy: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        text: String? = nil,
        keys: String? = nil,
        button: MouseButton? = nil,
        clickCount: Int? = nil,
        ocr: Bool? = nil,
        som: Bool? = nil,
        axNative: Bool? = nil,
        submit: Bool? = nil,
        clearFirst: Bool? = nil,
        launch: Bool? = nil,
        focus: Bool? = nil,
        compact: Bool? = nil,
        windowOnly: Bool? = nil,
        virtualCursor: Bool? = nil,
        timeout: Double? = nil,
        outputPath: String? = nil,
        hudEvent: HUDAnimationEvent? = nil,
        steps: [IPCRequest]? = nil
    ) {
        self.id = id
        self.command = command
        self.app = app
        self.windowID = windowID
        self.target = target
        self.toTarget = toTarget
        self.x = x
        self.y = y
        self.toX = toX
        self.toY = toY
        self.dx = dx
        self.dy = dy
        self.width = width
        self.height = height
        self.text = text
        self.keys = keys
        self.button = button
        self.clickCount = clickCount
        self.ocr = ocr
        self.som = som
        self.axNative = axNative
        self.submit = submit
        self.clearFirst = clearFirst
        self.launch = launch
        self.focus = focus
        self.compact = compact
        self.windowOnly = windowOnly
        self.virtualCursor = virtualCursor
        self.timeout = timeout
        self.outputPath = outputPath
        self.hudEvent = hudEvent
        self.steps = steps
    }
}

public struct IPCResponse: Codable, Sendable {
    public var id: String
    public var ok: Bool
    public var status: PermissionStatus?
    public var apps: [AppInfo]?
    public var snapshot: SnapshotResult?
    public var outcome: ActionOutcome?
    public var batchOutcomes: [ActionOutcome]?
    public var error: OCUError?

    public init(
        id: String,
        ok: Bool,
        status: PermissionStatus? = nil,
        apps: [AppInfo]? = nil,
        snapshot: SnapshotResult? = nil,
        outcome: ActionOutcome? = nil,
        batchOutcomes: [ActionOutcome]? = nil,
        error: OCUError? = nil
    ) {
        self.id = id
        self.ok = ok
        self.status = status
        self.apps = apps
        self.snapshot = snapshot
        self.outcome = outcome
        self.batchOutcomes = batchOutcomes
        self.error = error
    }
}
