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
        preferredWindowID: UInt32? = nil,
        windowTitleFilter: String? = nil,
        focusFirst: Bool = false,
        windowOnly: Bool = true,
        enableOCR: Bool = true,
        enableSoM: Bool = false,
        outputPath: String? = nil,
        includeBase64: Bool = false
    ) throws -> SnapshotResult {
        try AuditAndSecurityGuard.shared.verifyAppAllowed(appName: appName)

        if focusFirst, let targetApp = appName, !targetApp.isEmpty {
            _ = try? AppWorkspaceController.shared.focusOrLaunchApp(
                identifierOrName: targetApp,
                launchIfNeeded: true
            )
        }

        KillSwitchMonitor.shared.emitHUDEvent(
            .statusPill(title: "🔍 正在扫描界面元素 (Snapshot)...", subtitle: appName ?? "当前窗口")
        )

        // 1. Scan Accessibility Tree
        let axScan = AXScanner.shared.scanApplication(
            appNameFilter: appName,
            preferredWindowID: preferredWindowID,
            windowTitleFilter: windowTitleFilter
        )
        try AuditAndSecurityGuard.shared.verifyAppAllowed(appName: axScan.appName)
        var axElements = axScan.elements
        if windowOnly, let winRect = axScan.windowFrame {
            let inWinAX = axElements.filter { $0.frame.intersectionArea(with: winRect) > 0 }
            if !inWinAX.isEmpty {
                axElements = inWinAX
            }
        }
        // Keep exact 1:1 pairing between each AX UIElementRef and its live AXUIElement before any re-indexing
        let pairedRawAX: [AXUIElement?] = axElements.map { axScan.rawAXMap[$0.ref] }
        var reindexedAX: [UIElementRef] = []
        var updatedAXMap: [String: AXUIElement] = [:]
        for (idx, var el) in axElements.enumerated() {
            let newRef = "@e\(idx + 1)"
            el.ref = newRef
            reindexedAX.append(el)
            if let raw = pairedRawAX[idx] {
                updatedAXMap[newRef] = raw
            }
        }
        axElements = reindexedAX
        AXScanner.shared.updateLiveElementMap(updatedAXMap)
        var ocrElements: [UIElementRef] = []
        var capturedImage: CGImage? = nil
        var displayBounds = axScan.windowFrame ?? PermissionManager.shared.displayContaining(
            point: PermissionManager.shared.mainScreenBounds().center
        ).bounds
        var scaleFactor = PermissionManager.shared.mainScreenScaleFactor()

        if let wid = axScan.windowID, wid > 0, axScan.pid > 0 {
            KillSwitchMonitor.shared.emitHUDEvent(
                .pipTargetWindow(
                    pid: axScan.pid,
                    windowID: wid,
                    appName: axScan.appName,
                    windowTitle: axScan.windowTitle,
                    windowBounds: displayBounds
                )
            )
        }

        // 2. Capture the target window (or display if !windowOnly) if OCR, SoM, or outputPath is requested
        let needsScreenImage = enableOCR || enableSoM || (outputPath != nil) || includeBase64 || (axElements.count < 12)
        if needsScreenImage {
            if let capture = try? ScreenCaptureService.shared.captureDisplayImage(
                for: axScan.windowFrame,
                pid: axScan.pid,
                preferredWindowID: axScan.windowID,
                windowOnly: windowOnly
            ) {
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
            // Strictly filter out background desktop noise when windowOnly is active and windowFrame is valid
            if windowOnly, let winRect = axScan.windowFrame {
                let inWindow = candidates.filter { $0.frame.intersectionArea(with: winRect) > 0 }
                if !inWindow.isEmpty {
                    candidates = inWindow
                }
            }

            let merged = VisionOCRScanner.mergeElements(axElements: axElements, ocrCandidates: candidates)
            ocrElements = merged.filter { $0.source == .ocr }
            axElements = merged.filter { $0.source == .ax }
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
            windowID: axScan.windowID,
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

    /// Instant targeted element lookup (`ocu query`) without full screenshot encoding overhead.
    /// Updates the live snapshot in memory so returned `@eXX` references can be clicked immediately.
    public func queryElements(
        appName: String? = nil,
        preferredWindowID: UInt32? = nil,
        windowTitleFilter: String? = nil,
        textQuery: String? = nil,
        roleFilter: String? = nil,
        enableOCR: Bool = false
    ) throws -> SnapshotResult {
        let effectiveApp = appName ?? currentSnapshot()?.activeApp
        let snap = try captureSnapshot(
            appName: effectiveApp,
            preferredWindowID: preferredWindowID,
            windowTitleFilter: windowTitleFilter,
            focusFirst: false,
            windowOnly: true,
            enableOCR: enableOCR,
            enableSoM: false,
            outputPath: nil,
            includeBase64: false
        )
        let filtered = snap.elements.filter { el in
            var matches = true
            if let q = textQuery, !q.isEmpty {
                let lq = q.lowercased()
                let labelHit = el.label.lowercased().contains(lq)
                let valHit = el.value?.lowercased().contains(lq) ?? false
                matches = matches && (labelHit || valHit)
            }
            if let r = roleFilter, !r.isEmpty {
                matches = matches && el.role.lowercased().contains(r.lowercased())
            }
            return matches
        }
        return SnapshotResult(
            snapshotId: snap.snapshotId,
            timestamp: snap.timestamp,
            activeApp: snap.activeApp,
            activePid: snap.activePid,
            windowID: snap.windowID,
            windowTitle: snap.windowTitle,
            screenBounds: snap.screenBounds,
            scaleFactor: snap.scaleFactor,
            axCount: filtered.filter { $0.source == .ax }.count,
            ocrCount: filtered.filter { $0.source == .ocr }.count,
            elements: filtered
        )
    }

    /// Computes a compact, bounded post-action AX diff so the LLM immediately sees what changed
    /// after a click/type/press/scroll without needing a separate full `snapshot` round-trip.
    public func computePostActionDiff(preferredPid: Int32? = nil) -> String? {
        guard AuditAndSecurityGuard.shared.loadConfig().autoPostActionDiff else {
            return nil
        }
        let prevSnap = currentSnapshot()
        let targetAppName: String? = {
            if let pid = preferredPid, pid > 0,
               let running = AppWorkspaceController.shared.listRunningApps().first(where: { $0.pid == pid }) {
                return running.name
            }
            return prevSnap?.activeApp
        }()
        let axScan = AXScanner.shared.scanApplication(
            appNameFilter: targetAppName,
            preferredWindowID: prevSnap?.windowID,
            maxDepth: 12,
            maxElements: 120
        )
        guard axScan.pid > 0 else { return nil }

        var parts: [String] = []
        if let foc = axScan.elements.first(where: { $0.focused }) {
            let valDesc = (foc.value != nil && !foc.value!.isEmpty) ? "='\(foc.value!.prefix(30))'" : ""
            parts.append("focus:\(foc.ref)[\(foc.role):\(foc.label.prefix(24))\(valDesc)]")
        }

        if let prev = prevSnap, prev.activePid == axScan.pid {
            let prevByLabelRole = Dictionary(
                 prev.elements.map { ("\($0.role)|\($0.label)", $0.value ?? "") },
                uniquingKeysWith: { first, _ in first }
            )
            var changed: [String] = []
            var added: [String] = []
            for el in axScan.elements {
                let key = "\(el.role)|\(el.label)"
                if let oldVal = prevByLabelRole[key] {
                    let newVal = el.value ?? ""
                    if oldVal != newVal && !newVal.isEmpty {
                        changed.append("~\(el.ref)[\(el.label.prefix(18))]='\(newVal.prefix(24))'")
                    }
                } else {
                    let cx = Int(el.centerPoint.x.rounded())
                    let cy = Int(el.centerPoint.y.rounded())
                    added.append("+\(el.ref)|\(el.role)|\(cx),\(cy)|\(el.label.prefix(24))")
                }
            }
            if !changed.isEmpty {
                parts.append("changed: " + changed.prefix(4).joined(separator: ", "))
            }
            if !added.isEmpty {
                parts.append("added(\(added.count)): " + added.prefix(5).joined(separator: "; "))
            }
        }

        // Preserve existing OCR elements if they belong to the same window so @e refs stay usable
        let preservedOCR = (prevSnap?.activePid == axScan.pid) ? (prevSnap?.elements.filter { $0.source == .ocr } ?? []) : []
        let merged = VisionOCRScanner.mergeElements(axElements: axScan.elements, ocrCandidates: preservedOCR)
        let updatedSnap = SnapshotResult(
            activeApp: axScan.appName,
            activePid: axScan.pid,
            windowID: axScan.windowID,
            windowTitle: axScan.windowTitle,
            screenBounds: axScan.windowFrame ?? prevSnap?.screenBounds ?? PermissionManager.shared.mainScreenBounds(),
            scaleFactor: prevSnap?.scaleFactor ?? 2.0,
            axCount: axScan.elements.count,
            ocrCount: preservedOCR.count,
            elements: merged
        )
        saveSnapshot(updatedSnap)

        return parts.isEmpty ? nil : parts.joined(separator: " | ")
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
