import Foundation
import CoreGraphics
import ApplicationServices

public final class ElementSnapshotStore: @unchecked Sendable {
    public static let shared = ElementSnapshotStore()

    private let lock = NSLock()
    private var latestSnapshot: SnapshotResult?

    public var cacheDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".opencomputeruse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var snapshotFileURL: URL {
        cacheDirectory.appendingPathComponent("last_snapshot.json")
    }

    private init() {
        loadFromDiskIfNeeded()
    }

    public func captureSnapshot(
        appName: String? = nil,
        enableOCR: Bool = true,
        enableSoM: Bool = false,
        outputPath: String? = nil,
        includeBase64: Bool = false
    ) throws -> SnapshotResult {
        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "🔍 正在扫描界面元素 (Snapshot)...", subtitle: appName ?? "当前窗口")
        )

        // 1. Scan Accessibility Tree
        let axScan = AXScanner.shared.scanApplication(appNameFilter: appName)
        var axElements = axScan.elements
        var ocrElements: [UIElementRef] = []
        var capturedImage: CGImage? = nil
        var displayBounds = PermissionManager.shared.displayContaining(
            point: axScan.windowFrame?.center ?? PermissionManager.shared.mainScreenBounds().center
        ).bounds
        var scaleFactor = PermissionManager.shared.mainScreenScaleFactor()

        // 2. Capture the display containing the target window if OCR, SoM, or outputPath is requested
        let needsScreenImage = enableOCR || enableSoM || (outputPath != nil) || includeBase64 || (axElements.count < 12)
        if needsScreenImage {
            if let capture = try? ScreenCaptureService.shared.captureDisplayImage(for: axScan.windowFrame) {
                capturedImage = capture.image
                displayBounds = capture.logicalBounds
                scaleFactor = capture.scaleFactor
            }
        }

        // 3. Run Apple Vision OCR supplemental detection if requested or AX elements are sparse
        if (enableOCR || axElements.count < 12), let img = capturedImage {
            var candidates = VisionOCRScanner.shared.recognizeTextElements(
                in: img,
                screenBounds: displayBounds,
                appName: axScan.appName,
                pid: axScan.pid,
                windowTitle: axScan.windowTitle
            )
            // If we know the target window's bounding box, prioritize OCR candidates inside that window
            if let winRect = axScan.windowFrame {
                let inWindow = candidates.filter { $0.frame.intersectionArea(with: winRect) > 0 }
                if !inWindow.isEmpty {
                    candidates = inWindow
                }
            }

            let merged = VisionOCRScanner.mergeElements(axElements: axElements, ocrCandidates: candidates)
            ocrElements = merged.filter { $0.source == .ocr }
            axElements = merged.filter { $0.source == .ax }

            var updatedAXMap: [String: AXUIElement] = [:]
            for el in axElements {
                if let raw = axScan.rawAXMap[el.ref] {
                    updatedAXMap[el.ref] = raw
                }
            }
            AXScanner.shared.updateLiveElementMap(updatedAXMap)
        }

        let allElements = axElements + ocrElements

        // 4. Generate Set-of-Marks (SoM) annotated screenshot if requested
        var rawPath: String? = nil
        var annotatedPath: String? = nil
        var base64String: String? = nil

        if let img = capturedImage {
            if enableSoM {
                if let annotated = SoMAnnotator.shared.annotateImage(
                    img,
                    elements: allElements,
                    scaleFactor: scaleFactor,
                    displayBounds: displayBounds
                ) {
                    let targetOut = outputPath ?? cacheDirectory.appendingPathComponent("latest_som.png").path
                    try? ScreenCaptureService.shared.savePNG(annotated, to: targetOut)
                    annotatedPath = targetOut
                    if includeBase64, let pngData = ScreenCaptureService.shared.encodePNGData(annotated) {
                        base64String = pngData.base64EncodedString()
                    }
                }
            } else if let customOut = outputPath {
                try? ScreenCaptureService.shared.savePNG(img, to: customOut)
                rawPath = customOut
                if includeBase64, let pngData = ScreenCaptureService.shared.encodePNGData(img) {
                    base64String = pngData.base64EncodedString()
                }
            } else if includeBase64, let pngData = ScreenCaptureService.shared.encodePNGData(img) {
                base64String = pngData.base64EncodedString()
            }
        }

        let snapshot = SnapshotResult(
            activeApp: axScan.appName,
            activePid: axScan.pid,
            windowTitle: axScan.windowTitle,
            screenBounds: displayBounds,
            scaleFactor: scaleFactor,
            axCount: axElements.count,
            ocrCount: ocrElements.count,
            elements: allElements,
            screenshotPath: rawPath,
            annotatedScreenshotPath: annotatedPath,
            imageBase64: base64String
        )

        saveSnapshot(snapshot)
        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(
                title: "✅ 快照完成 (\(allElements.count) 个元素)",
                subtitle: "AX: \(axElements.count) | OCR: \(ocrElements.count)"
            )
        )
        return snapshot
    }

    public func saveSnapshot(_ snapshot: SnapshotResult) {
        lock.lock()
        latestSnapshot = snapshot
        lock.unlock()

        var diskCopy = snapshot
        diskCopy.imageBase64 = nil
        if let data = try? JSONEncoder().encode(diskCopy) {
            try? data.write(to: snapshotFileURL, options: .atomic)
        }
    }

    public func currentSnapshot() -> SnapshotResult? {
        lock.lock()
        if let snap = latestSnapshot {
            lock.unlock()
            return snap
        }
        lock.unlock()
        loadFromDiskIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return latestSnapshot
    }

    public func resolveTarget(_ target: String) throws -> UIElementRef {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OCUError(
                code: .invalidArguments,
                message: "Empty target reference.",
                recoveryHint: "Provide a valid element reference like '@e1' or coordinates."
            )
        }

        if let snapshot = currentSnapshot() {
            let normalizedRef = trimmed.hasPrefix("@") ? trimmed.lowercased() : "@\(trimmed.lowercased())"
            if let exactRef = snapshot.elements.first(where: { $0.ref.lowercased() == normalizedRef }) {
                return exactRef
            }

            let lowerQuery = trimmed.lowercased()
            if let exactLabel = snapshot.elements.first(where: { $0.label.lowercased() == lowerQuery }) {
                return exactLabel
            }
            if let partialLabel = snapshot.elements.first(where: { $0.label.lowercased().contains(lowerQuery) }) {
                return partialLabel
            }
        }

        let freshSnapshot = try captureSnapshot(enableOCR: true, enableSoM: false)
        let normalizedRef = trimmed.hasPrefix("@") ? trimmed.lowercased() : "@\(trimmed.lowercased())"
        if let exactRef = freshSnapshot.elements.first(where: { $0.ref.lowercased() == normalizedRef }) {
            return exactRef
        }
        let lowerQuery = trimmed.lowercased()
        if let match = freshSnapshot.elements.first(where: { $0.label.lowercased().contains(lowerQuery) }) {
            return match
        }

        throw OCUError(
            code: .elementNotFound,
            message: "Could not find UI element matching '\(target)' in active window '\(freshSnapshot.activeApp)'.",
            recoveryHint: "Call ocu_snapshot (with --ocr or --som) to inspect available @e1..@eN references."
        )
    }

    private func loadFromDiskIfNeeded() {
        guard FileManager.default.fileExists(atPath: snapshotFileURL.path),
              let data = try? Data(contentsOf: snapshotFileURL),
              let decoded = try? JSONDecoder().decode(SnapshotResult.self, from: data) else {
            return
        }
        lock.lock()
        latestSnapshot = decoded
        lock.unlock()
    }
}
