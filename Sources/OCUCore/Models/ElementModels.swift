import Foundation

public enum ElementSource: String, Codable, Sendable {
    case ax = "ax"
    case ocr = "ocr"
}

public struct UIElementRef: Codable, Equatable, Sendable {
    public var ref: String
    public var source: ElementSource
    public var role: String
    public var label: String
    public var value: String?
    public var frame: ScreenRect
    public var centerPoint: ScreenPoint
    public var enabled: Bool
    public var focused: Bool
    public var appName: String
    public var pid: Int32
    public var windowID: UInt32?
    public var windowTitle: String?
    public var confidence: Double?

    public init(
        ref: String,
        source: ElementSource,
        role: String,
        label: String,
        value: String? = nil,
        frame: ScreenRect,
        enabled: Bool = true,
        focused: Bool = false,
        appName: String,
        pid: Int32,
        windowID: UInt32? = nil,
        windowTitle: String? = nil,
        confidence: Double? = nil
    ) {
        self.ref = ref
        self.source = source
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.centerPoint = frame.center
        self.enabled = enabled
        self.focused = focused
        self.appName = appName
        self.pid = pid
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.confidence = confidence
    }
}

public struct WindowInfo: Codable, Equatable, Sendable {
    public var windowId: Int
    public var title: String
    public var appName: String
    public var pid: Int32
    public var frame: ScreenRect
    public var isOnScreen: Bool
    public var layer: Int

    public init(
        windowId: Int,
        title: String,
        appName: String,
        pid: Int32,
        frame: ScreenRect,
        isOnScreen: Bool,
        layer: Int
    ) {
        self.windowId = windowId
        self.title = title
        self.appName = appName
        self.pid = pid
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.layer = layer
    }
}

public struct AppInfo: Codable, Equatable, Sendable {
    public var name: String
    public var bundleId: String?
    public var pid: Int32
    public var isActive: Bool
    public var isHidden: Bool
    public var windows: [WindowInfo]

    public init(
        name: String,
        bundleId: String?,
        pid: Int32,
        isActive: Bool,
        isHidden: Bool,
        windows: [WindowInfo] = []
    ) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
        self.isActive = isActive
        self.isHidden = isHidden
        self.windows = windows
    }
}

public struct SnapshotResult: Codable, Equatable, Sendable {
    public var snapshotId: String
    public var timestamp: String
    public var activeApp: String
    public var activePid: Int32
    public var windowID: UInt32?
    public var windowTitle: String?
    public var screenBounds: ScreenRect
    public var scaleFactor: Double
    public var axCount: Int
    public var ocrCount: Int
    public var elements: [UIElementRef]
    public var screenshotPath: String?
    public var annotatedScreenshotPath: String?
    public var imageBase64: String?
    public var imageHash: String?
    public var imageDeduplicated: Bool?
    public var unchangedSinceSnapshotId: String?

    public init(
        snapshotId: String = UUID().uuidString.prefix(8).lowercased(),
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        activeApp: String,
        activePid: Int32,
        windowID: UInt32? = nil,
        windowTitle: String?,
        screenBounds: ScreenRect,
        scaleFactor: Double,
        axCount: Int,
        ocrCount: Int,
        elements: [UIElementRef],
        screenshotPath: String? = nil,
        annotatedScreenshotPath: String? = nil,
        imageBase64: String? = nil,
        imageHash: String? = nil,
        imageDeduplicated: Bool? = nil,
        unchangedSinceSnapshotId: String? = nil
    ) {
        self.snapshotId = snapshotId
        self.timestamp = timestamp
        self.activeApp = activeApp
        self.activePid = activePid
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.screenBounds = screenBounds
        self.scaleFactor = scaleFactor
        self.axCount = axCount
        self.ocrCount = ocrCount
        self.elements = elements
        self.screenshotPath = screenshotPath
        self.annotatedScreenshotPath = annotatedScreenshotPath
        self.imageBase64 = imageBase64
        self.imageHash = imageHash
        self.imageDeduplicated = imageDeduplicated
        self.unchangedSinceSnapshotId = unchangedSinceSnapshotId
    }

    /// Formats the snapshot in a token-compact tabular form (`@eX|src|role|x,y|label`), saving ~60% LLM context tokens.
    public func formatCompact() -> String {
        var lines: [String] = []
        let b = screenBounds
        let boundsDesc = "[\(Int(b.x)),\(Int(b.y)) \(Int(b.width))x\(Int(b.height))]"
        let widTag = windowID != nil ? "#\(windowID!) " : ""
        lines.append("# snap:\(snapshotId) | app:\(activeApp)(\(activePid)) | win:\(widTag)\(windowTitle ?? "-") \(boundsDesc) | total:\(elements.count)(ax:\(axCount),ocr:\(ocrCount))")
        if imageDeduplicated == true, let prevId = unchangedSinceSnapshotId {
            lines.append("# img_dedup: unchanged_since=\(prevId) (dHash=\(imageHash ?? "-"), base64 omitted to save tokens)")
        } else if let som = annotatedScreenshotPath {
            lines.append("# som:\(som)")
        } else if let raw = screenshotPath {
            lines.append("# img:\(raw)")
        }
        for el in elements {
            let cx = Int(el.centerPoint.x.rounded())
            let cy = Int(el.centerPoint.y.rounded())
            let valPart = (el.value != nil && !el.value!.isEmpty && el.value != el.label) ? "=\(el.value!)" : ""
            lines.append("\(el.ref)|\(el.source.rawValue)|\(el.role)|\(cx),\(cy)|\(el.label)\(valPart)")
        }
        return lines.joined(separator: "\n")
    }
}
