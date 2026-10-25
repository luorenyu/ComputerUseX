import XCTest
import CoreGraphics
@testable import OCUCore

final class OCUCoreTests: XCTestCase {

    func testScreenRectIoUAndOverlap() {
        let boxA = ScreenRect(x: 100, y: 100, width: 100, height: 40)
        let boxB = ScreenRect(x: 105, y: 102, width: 95, height: 38)
        let disjoint = ScreenRect(x: 400, y: 400, width: 80, height: 30)

        XCTAssertGreaterThan(boxA.intersectionOverUnion(with: boxB), 0.75)
        XCTAssertTrue(boxB.overlapsSignificantly(with: boxA))
        XCTAssertEqual(boxA.intersectionOverUnion(with: disjoint), 0.0)
        XCTAssertFalse(disjoint.overlapsSignificantly(with: boxA))
    }

    func testCubicBezierTrajectorySampling() {
        let start = ScreenPoint(x: 100, y: 150)
        let end = ScreenPoint(x: 600, y: 450)
        let points = CubicBezierTrajectory.sample(from: start, to: end, steps: 20)

        XCTAssertEqual(points.count, 20)
        XCTAssertEqual(points.last, end)

        // Verify trajectory curves smoothly and progresses monotonically toward destination
        let midPoint = points[9]
        XCTAssertGreaterThan(midPoint.x, start.x)
        XCTAssertLessThan(midPoint.x, end.x)
    }

    func testVisionOCRCoordinateConversionAndDeduplication() {
        let screen = ScreenRect(x: 0, y: 0, width: 1000, height: 800)
        // Vision box near top-left in bottom-left normalized coords: x=0.1, y=0.8, w=0.2, h=0.1
        // In top-left logical coords: x=100, y=(1 - 0.9)*800 = 80, w=200, h=80
        let normalized = CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.1)
        let converted = VisionOCRScanner.convertNormalizedVisionRect(normalized, in: screen)

        XCTAssertEqual(converted.x, 100.0, accuracy: 0.2)
        XCTAssertEqual(converted.y, 80.0, accuracy: 0.2)
        XCTAssertEqual(converted.width, 200.0, accuracy: 0.2)
        XCTAssertEqual(converted.height, 80.0, accuracy: 0.2)

        // Test deduplication between AX elements and OCR candidates
        let axBtn = UIElementRef(
            ref: "@e1",
            source: .ax,
            role: "button",
            label: "Submit",
            frame: ScreenRect(x: 100, y: 80, width: 200, height: 80),
            appName: "TestApp",
            pid: 123
        )
        let duplicateOCR = UIElementRef(
            ref: "",
            source: .ocr,
            role: "ocrText",
            label: "Submit",
            frame: ScreenRect(x: 105, y: 85, width: 180, height: 70),
            appName: "TestApp",
            pid: 123
        )
        let novelOCR = UIElementRef(
            ref: "",
            source: .ocr,
            role: "ocrText",
            label: "Canvas Badge",
            frame: ScreenRect(x: 500, y: 300, width: 120, height: 32),
            appName: "TestApp",
            pid: 123
        )

        let merged = VisionOCRScanner.mergeElements(
            axElements: [axBtn],
            ocrCandidates: [duplicateOCR, novelOCR]
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].ref, "@e1")
        XCTAssertEqual(merged[0].source, .ax)
        XCTAssertEqual(merged[1].ref, "@e2")
        XCTAssertEqual(merged[1].source, .ocr)
        XCTAssertEqual(merged[1].label, "Canvas Badge")
    }

    func testKeyboardShortcutParser() throws {
        let combo1 = try KeyboardController.parseShortcut("cmd+shift+p")
        XCTAssertTrue(combo1.flags.contains(.maskCommand))
        XCTAssertTrue(combo1.flags.contains(.maskShift))
        XCTAssertEqual(combo1.keyCode, 35) // 'p'

        let combo2 = try KeyboardController.parseShortcut("enter")
        XCTAssertEqual(combo2.keyCode, 36)

        XCTAssertThrowsError(try KeyboardController.parseShortcut("cmd+unknownkey"))
    }

    func testSoMAnnotatorRendersImage() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: 800,
            height: 600,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let baseImage = ctx.makeImage() else {
            XCTFail("Failed to create synthetic test CGImage")
            return
        }

        let elements = [
            UIElementRef(
                ref: "@e1",
                source: .ax,
                role: "button",
                label: "Confirm",
                frame: ScreenRect(x: 50, y: 60, width: 120, height: 36),
                appName: "Demo",
                pid: 1
            ),
            UIElementRef(
                ref: "@e2",
                source: .ocr,
                role: "ocrText",
                label: "Canvas Action",
                frame: ScreenRect(x: 220, y: 140, width: 150, height: 32),
                appName: "Demo",
                pid: 1
            )
        ]

        let annotated = SoMAnnotator.shared.annotateImage(baseImage, elements: elements, scaleFactor: 2.0)
        XCTAssertNotNil(annotated)
        XCTAssertEqual(annotated?.width, 800)
        XCTAssertEqual(annotated?.height, 600)
    }

    func testUnixSocketIPCRoundTrip() throws {
        let socketPath = "/tmp/ocu-test-\(UUID().uuidString.prefix(8)).sock"
        let server = UnixSocketIPC()
        try server.startServer(socketPath: socketPath)
        defer {
            server.stopServer(socketPath: socketPath)
        }

        XCTAssertTrue(UnixSocketIPC.isDaemonReachable(socketPath: socketPath))

        let response = try UnixSocketIPC.sendRequest(
            IPCRequest(command: "status"),
            socketPath: socketPath
        )
        XCTAssertTrue(response.ok)
        XCTAssertNotNil(response.status)
    }

    func testMCPServerProtocolHandshakeAndToolList() throws {
        let initReq = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
        """
        guard let initRespStr = MCPServer.shared.handleJSONRPCLine(initReq),
              let initData = initRespStr.data(using: .utf8),
              let initJSON = try JSONSerialization.jsonObject(with: initData) as? [String: Any],
              let result = initJSON["result"] as? [String: Any],
              let serverInfo = result["serverInfo"] as? [String: Any] else {
            XCTFail("Invalid MCP initialize response")
            return
        }
        XCTAssertEqual(serverInfo["name"] as? String, "open-computer-use")

        let listReq = """
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        """
        guard let listRespStr = MCPServer.shared.handleJSONRPCLine(listReq),
              let listData = listRespStr.data(using: .utf8),
              let listJSON = try JSONSerialization.jsonObject(with: listData) as? [String: Any],
              let listResult = listJSON["result"] as? [String: Any],
              let tools = listResult["tools"] as? [[String: Any]] else {
            XCTFail("Invalid MCP tools/list response")
            return
        }
        XCTAssertEqual(tools.count, 14)
        XCTAssertTrue(tools.contains(where: { ($0["name"] as? String) == "ocu_snapshot" }))
        XCTAssertTrue(tools.contains(where: { ($0["name"] as? String) == "ocu_query" }))
        XCTAssertTrue(tools.contains(where: { ($0["name"] as? String) == "ocu_upload_file" }))
        XCTAssertTrue(tools.contains(where: { ($0["name"] as? String) == "ocu_secondary_action" }))
        XCTAssertTrue(tools.contains(where: { ($0["name"] as? String) == "ocu_click" }))
        XCTAssertTrue(tools.contains(where: { ($0["name"] as? String) == "ocu_batch" }))
    }

    func testSecurityGuardBlocksSensitiveAppsAndRecordsAudit() {
        XCTAssertThrowsError(try AuditAndSecurityGuard.shared.verifyAppAllowed(appName: "1Password 8"))
        XCTAssertThrowsError(try AuditAndSecurityGuard.shared.verifyAppAllowed(appName: "钥匙串访问"))
        XCTAssertNoThrow(try AuditAndSecurityGuard.shared.verifyAppAllowed(appName: "微信"))

        AuditAndSecurityGuard.shared.recordAudit(AuditRecord(
            command: "test_click",
            app: "微信",
            target: "@e1",
            success: true,
            details: "unit test audit entry",
            elapsedMs: 12
        ))
        let recent = AuditAndSecurityGuard.shared.recentAuditRecords(limit: 5)
        XCTAssertFalse(recent.isEmpty)
        XCTAssertEqual(recent.last?.command, "test_click")
    }

    func testSnapshotFormatCompactAndWindowOriginMapping() {
        // Test window-cropped Vision OCR coordinate conversion with non-zero origin (e.g. secondary display window)
        let windowBounds = ScreenRect(x: 1787, y: 97, width: 791, height: 840)
        let normalized = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.05)
        let mapped = VisionOCRScanner.convertNormalizedVisionRect(normalized, in: windowBounds)
        XCTAssertEqual(mapped.x, 1787 + 791 * 0.5, accuracy: 0.5)
        XCTAssertEqual(mapped.y, 97 + 840 * 0.45, accuracy: 0.5)

        let el = UIElementRef(
            ref: "@e22",
            source: .ocr,
            role: "ocrText",
            label: "黑骑士",
            frame: ScreenRect(x: 1772, y: 472, width: 41, height: 14),
            appName: "微信",
            pid: 42553
        )
        let snap = SnapshotResult(
            snapshotId: "ab12cd34",
            activeApp: "微信",
            activePid: 42553,
            windowTitle: "微信",
            screenBounds: windowBounds,
            scaleFactor: 1.0,
            axCount: 0,
            ocrCount: 1,
            elements: [el]
        )
        let compactText = snap.formatCompact()
        XCTAssertTrue(compactText.contains("# snap:ab12cd34 | app:微信(42553)"))
        XCTAssertTrue(compactText.contains("@e22|ocr|ocrText|1793,479|黑骑士"))
    }
}
