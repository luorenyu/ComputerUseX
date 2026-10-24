import Foundation

public final class MCPServer: @unchecked Sendable {
    public static let shared = MCPServer()
    public static let serverName = "open-computer-use"
    public static let serverVersion = "1.0.0"

    private init() {}

    public func runStdioLoop() {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let responseLine = handleJSONRPCLine(trimmed) {
                FileHandle.standardOutput.write(Data((responseLine + "\n").utf8))
            }
        }
    }

    public func handleJSONRPCLine(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encodeJSON([
                "jsonrpc": "2.0",
                "id": NSNull(),
                "error": [
                    "code": -32700,
                    "message": "Parse error"
                ]
            ])
        }

        let method = json["method"] as? String ?? ""
        let id = json["id"]
        let params = json["params"] as? [String: Any] ?? [:]

        // Notifications (no id) do not require a response
        if id == nil || method.hasPrefix("notifications/") {
            return nil
        }

        switch method {
        case "initialize":
            let clientProtocol = params["protocolVersion"] as? String ?? "2024-11-05"
            return makeResultResponse(id: id, result: [
                "protocolVersion": clientProtocol,
                "capabilities": [
                    "tools": [
                        "listChanged": false
                    ]
                ],
                "serverInfo": [
                    "name": Self.serverName,
                    "version": Self.serverVersion
                ]
            ])

        case "ping":
            return makeResultResponse(id: id, result: [:])

        case "tools/list":
            return makeResultResponse(id: id, result: [
                "tools": Self.toolDefinitions()
            ])

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return makeErrorResponse(id: id, code: -32602, message: "Missing tool name")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            let toolResult = dispatchToolCall(name: toolName, arguments: args)
            return makeResultResponse(id: id, result: toolResult)

        default:
            return makeErrorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func dispatchToolCall(name: String, arguments: [String: Any]) -> [String: Any] {
        let req = buildIPCRequest(for: name, arguments: arguments)
        let resp = UnixSocketIPC.executeRoutingThroughDaemonIfAvailable(req)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if !resp.ok {
            let errText = (try? String(data: encoder.encode(resp.error), encoding: .utf8)) ?? "Unknown error"
            return [
                "isError": true,
                "content": [
                    [
                        "type": "text",
                        "text": errText
                    ]
                ]
            ]
        }

        var contentBlocks: [[String: Any]] = []

        if let snap = resp.snapshot {
            var copyWithoutBase64 = snap
            copyWithoutBase64.imageBase64 = nil
            if let textData = try? encoder.encode(copyWithoutBase64),
               let textStr = String(data: textData, encoding: .utf8) {
                contentBlocks.append([
                    "type": "text",
                    "text": textStr
                ])
            }
            if let b64 = snap.imageBase64, !b64.isEmpty {
                contentBlocks.append([
                    "type": "image",
                    "data": b64,
                    "mimeType": "image/png"
                ])
            }
        } else if let status = resp.status,
                  let data = try? encoder.encode(status),
                  let str = String(data: data, encoding: .utf8) {
            contentBlocks.append(["type": "text", "text": str])
        } else if let apps = resp.apps,
                  let data = try? encoder.encode(apps),
                  let str = String(data: data, encoding: .utf8) {
            contentBlocks.append(["type": "text", "text": str])
        } else if let outcome = resp.outcome,
                  let data = try? encoder.encode(outcome),
                  let str = String(data: data, encoding: .utf8) {
            contentBlocks.append(["type": "text", "text": str])
        } else {
            contentBlocks.append(["type": "text", "text": "{\"ok\": true}"])
        }

        return [
            "isError": false,
            "content": contentBlocks
        ]
    }

    private func buildIPCRequest(for toolName: String, arguments: [String: Any]) -> IPCRequest {
        switch toolName {
        case "ocu_status":
            return IPCRequest(command: "status")
        case "ocu_apps":
            return IPCRequest(
                command: "apps",
                app: arguments["app"] as? String,
                x: doubleVal(arguments["x"]),
                y: doubleVal(arguments["y"]),
                width: doubleVal(arguments["width"]),
                height: doubleVal(arguments["height"]),
                launch: arguments["launch"] as? Bool ?? true
            )
        case "ocu_snapshot":
            return IPCRequest(
                command: "snapshot",
                app: arguments["app"] as? String,
                ocr: arguments["ocr"] as? Bool ?? true,
                som: arguments["som"] as? Bool ?? false,
                outputPath: arguments["output"] as? String
            )
        case "ocu_click":
            let btnStr = (arguments["button"] as? String)?.lowercased() ?? "left"
            return IPCRequest(
                command: "click",
                target: arguments["target"] as? String,
                x: doubleVal(arguments["x"]),
                y: doubleVal(arguments["y"]),
                button: MouseButton(rawValue: btnStr) ?? .left,
                clickCount: intVal(arguments["count"]) ?? 1,
                axNative: arguments["ax_native"] as? Bool ?? false
            )
        case "ocu_move":
            return IPCRequest(
                command: "move",
                target: arguments["target"] as? String,
                x: doubleVal(arguments["x"]),
                y: doubleVal(arguments["y"])
            )
        case "ocu_type":
            return IPCRequest(
                command: "type",
                target: arguments["target"] as? String,
                text: arguments["text"] as? String ?? "",
                submit: arguments["submit"] as? Bool ?? false,
                clearFirst: arguments["clear"] as? Bool ?? false
            )
        case "ocu_press":
            return IPCRequest(
                command: "press",
                keys: arguments["keys"] as? String ?? ""
            )
        case "ocu_scroll":
            return IPCRequest(
                command: "scroll",
                target: arguments["target"] as? String,
                x: doubleVal(arguments["x"]),
                y: doubleVal(arguments["y"]),
                dx: doubleVal(arguments["dx"]) ?? 0,
                dy: doubleVal(arguments["dy"]) ?? -240
            )
        case "ocu_drag":
            return IPCRequest(
                command: "drag",
                target: arguments["from"] as? String,
                toTarget: arguments["to"] as? String,
                x: doubleVal(arguments["from_x"]),
                y: doubleVal(arguments["from_y"]),
                toX: doubleVal(arguments["to_x"]),
                toY: doubleVal(arguments["to_y"]),
                timeout: doubleVal(arguments["duration"])
            )
        case "ocu_wait":
            return IPCRequest(
                command: "wait",
                text: arguments["text"] as? String,
                timeout: doubleVal(arguments["timeout"]) ?? 3.0
            )
        default:
            return IPCRequest(command: toolName)
        }
    }

    private func doubleVal(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private func intVal(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private func makeResultResponse(id: Any?, result: [String: Any]) -> String? {
        encodeJSON([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result
        ])
    }

    private func makeErrorResponse(id: Any?, code: Int, message: String) -> String? {
        encodeJSON([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message
            ]
        ])
    }

    private func encodeJSON(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "ocu_status",
                "description": "Check macOS Accessibility & Screen Recording permissions, daemon HUD connection status, screen bounds, and active app.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any]
                ]
            ],
            [
                "name": "ocu_apps",
                "description": "List running macOS GUI apps and their windows, or focus/launch/resize a specific app.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string", "description": "Optional app name or bundle ID to focus or launch"],
                        "launch": ["type": "boolean", "description": "Launch the app if not currently running (default: true)"],
                        "x": ["type": "number", "description": "Optional window X coordinate to move/resize"],
                        "y": ["type": "number", "description": "Optional window Y coordinate to move/resize"],
                        "width": ["type": "number", "description": "Optional window width"],
                        "height": ["type": "number", "description": "Optional window height"]
                    ]
                ]
            ],
            [
                "name": "ocu_snapshot",
                "description": "Inspect the active macOS application using Tri-Modal Grounding (AXUIElement tree + Apple Vision OCR + Set-of-Marks annotated screenshot). Returns interactive elements with @e1, @e2 references and exact screen coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string", "description": "Optional application name to target (defaults to frontmost app)"],
                        "ocr": ["type": "boolean", "description": "Include Apple Vision OCR text detection for canvas/custom UI elements (default: true)"],
                        "som": ["type": "boolean", "description": "Return a Set-of-Marks (SoM) annotated screenshot with @eX badges and coordinate rulers (default: false)"],
                        "output": ["type": "string", "description": "Optional file path to save the screenshot PNG"]
                    ]
                ]
            ],
            [
                "name": "ocu_click",
                "description": "Click a UI element by reference (@e1), fuzzy label text, or screen (x, y) coordinates with smooth Bézier cursor trajectory and visual HUD ripple.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "Element reference like '@e1' or visible text label"],
                        "x": ["type": "number", "description": "Screen X coordinate (if target is not specified)"],
                        "y": ["type": "number", "description": "Screen Y coordinate (if target is not specified)"],
                        "button": ["type": "string", "enum": ["left", "right", "center"], "description": "Mouse button (default: left)"],
                        "count": ["type": "integer", "description": "Click count: 1 for single click, 2 for double click (default: 1)"],
                        "ax_native": ["type": "boolean", "description": "Try triggering native kAXPressAction without moving physical mouse first (default: false)"]
                    ]
                ]
            ],
            [
                "name": "ocu_move",
                "description": "Smoothly move the mouse cursor to an element (@e1) or (x, y) coordinate along a human-like Bézier curve.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "Element reference like '@e1' or label"],
                        "x": ["type": "number", "description": "Screen X coordinate"],
                        "y": ["type": "number", "description": "Screen Y coordinate"]
                    ]
                ]
            ],
            [
                "name": "ocu_type",
                "description": "Type text (English, Chinese, Emoji, or multi-line) into the focused field or a target element (@e1). Uses safe clipboard transaction to prevent IME garbling.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Text content to type"],
                        "target": ["type": "string", "description": "Optional element reference (@e1) to click before typing"],
                        "clear": ["type": "boolean", "description": "Select all (Cmd+A) and delete existing text before typing (default: false)"],
                        "submit": ["type": "boolean", "description": "Press Return/Enter after typing (default: false)"]
                    ],
                    "required": ["text"]
                ]
            ],
            [
                "name": "ocu_press",
                "description": "Press a keyboard key or shortcut combination such as 'enter', 'escape', 'tab', 'cmd+c', 'cmd+shift+p', 'opt+space'.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "keys": ["type": "string", "description": "Key or shortcut combination (e.g. 'cmd+k', 'enter')"]
                    ],
                    "required": ["keys"]
                ]
            ],
            [
                "name": "ocu_scroll",
                "description": "Scroll smoothly by pixel delta (dx, dy) at current mouse position or over a target element (@e1).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "dy": ["type": "number", "description": "Vertical scroll delta in pixels (negative scrolls down, positive scrolls up)"],
                        "dx": ["type": "number", "description": "Horizontal scroll delta in pixels (default: 0)"],
                        "target": ["type": "string", "description": "Optional element reference (@e1) to hover before scrolling"],
                        "x": ["type": "number", "description": "Optional X coordinate to hover before scrolling"],
                        "y": ["type": "number", "description": "Optional Y coordinate to hover before scrolling"]
                    ]
                ]
            ],
            [
                "name": "ocu_drag",
                "description": "Smoothly drag from one element/coordinate to another element/coordinate.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "from": ["type": "string", "description": "Start element reference (@e1)"],
                        "to": ["type": "string", "description": "Destination element reference (@e2)"],
                        "from_x": ["type": "number", "description": "Start X coordinate"],
                        "from_y": ["type": "number", "description": "Start Y coordinate"],
                        "to_x": ["type": "number", "description": "Destination X coordinate"],
                        "to_y": ["type": "number", "description": "Destination Y coordinate"],
                        "duration": ["type": "number", "description": "Drag duration in seconds (default: 0.3)"]
                    ]
                ]
            ],
            [
                "name": "ocu_wait",
                "description": "Wait for specified text/element to appear on screen (via AX + OCR polling) or wait for a fixed duration.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Optional text to wait for on screen"],
                        "timeout": ["type": "number", "description": "Timeout or delay in seconds (default: 3.0)"]
                    ]
                ]
            ]
        ]
    }
}
