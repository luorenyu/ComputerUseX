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
            if let clientInfo = params["clientInfo"] as? [String: Any],
               let clientName = clientInfo["name"] as? String {
                SessionBillingManager.shared.registerMCPClient(name: clientName)
            }
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
            let useCompact = req.compact ?? true
            if useCompact {
                contentBlocks.append([
                    "type": "text",
                    "text": snap.formatCompact()
                ])
            } else {
                var copyWithoutBase64 = snap
                copyWithoutBase64.imageBase64 = nil
                if let textData = try? encoder.encode(copyWithoutBase64),
                   let textStr = String(data: textData, encoding: .utf8) {
                    contentBlocks.append([
                        "type": "text",
                        "text": textStr
                    ])
                }
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
        } else if let bill = resp.bill {
            contentBlocks.append(["type": "text", "text": bill.formatReceiptText()])
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
            let winID = intVal(arguments["window_id"]).map { UInt32($0) }
            return IPCRequest(
                command: "snapshot",
                app: arguments["app"] as? String,
                windowID: winID,
                windowTitle: arguments["window_title"] as? String,
                ocr: arguments["ocr"] as? Bool ?? true,
                som: arguments["som"] as? Bool ?? false,
                focus: arguments["focus"] as? Bool ?? false,
                compact: arguments["compact"] as? Bool ?? true,
                windowOnly: arguments["window_only"] as? Bool ?? true,
                dedupImage: arguments["dedup_image"] as? Bool ?? true,
                outputPath: arguments["output"] as? String,
                agentName: arguments["agent"] as? String,
                modelName: arguments["model"] as? String
            )
        case "ocu_browser":
            return IPCRequest(
                command: "browser",
                app: arguments["browser"] as? String,
                windowTitle: arguments["tab_filter"] as? String,
                role: arguments["action"] as? String ?? "tabs",
                target: arguments["selector"] as? String,
                text: (arguments["url"] as? String) ?? (arguments["js"] as? String) ?? (arguments["selector"] as? String),
                launch: arguments["new_tab"] as? Bool ?? false
            )
        case "ocu_sandbox":
            return IPCRequest(
                command: "sandbox",
                app: arguments["app"] as? String,
                role: arguments["action"] as? String ?? "status"
            )
        case "ocu_bill":
            return IPCRequest(
                command: "bill",
                submit: arguments["finish"] as? Bool ?? false,
                focus: arguments["show_popup"] as? Bool ?? true,
                agentName: arguments["agent"] as? String,
                modelName: arguments["model"] as? String
            )
        case "ocu_query":
            let winID = intVal(arguments["window_id"]).map { UInt32($0) }
            return IPCRequest(
                command: "query",
                app: arguments["app"] as? String,
                windowID: winID,
                windowTitle: arguments["window_title"] as? String,
                role: arguments["role"] as? String,
                text: arguments["text"] as? String,
                ocr: arguments["ocr"] as? Bool ?? true,
                compact: arguments["compact"] as? Bool ?? true
            )
        case "ocu_upload_file":
            return IPCRequest(
                command: "upload_file",
                app: arguments["app"] as? String,
                text: arguments["path"] as? String ?? "",
                outputPath: arguments["path"] as? String
            )
        case "ocu_secondary_action":
            return IPCRequest(
                command: "secondary_action",
                target: arguments["target"] as? String,
                text: arguments["action"] as? String ?? "AXShowMenu"
            )
        case "ocu_click":
            let btnStr = (arguments["button"] as? String)?.lowercased() ?? "left"
            return IPCRequest(
                command: "click",
                target: arguments["target"] as? String,
                x: doubleVal(arguments["x"]),
                y: doubleVal(arguments["y"]),
                dx: doubleVal(arguments["dx"]),
                dy: doubleVal(arguments["dy"]),
                button: MouseButton(rawValue: btnStr) ?? .left,
                clickCount: intVal(arguments["count"]) ?? 1,
                axNative: arguments["ax_native"] as? Bool ?? false
            )
        case "ocu_move":
            return IPCRequest(
                command: "move",
                target: arguments["target"] as? String,
                x: doubleVal(arguments["x"]),
                y: doubleVal(arguments["y"]),
                dx: doubleVal(arguments["dx"]),
                dy: doubleVal(arguments["dy"])
            )
        case "ocu_type":
            return IPCRequest(
                command: "type",
                target: arguments["target"] as? String,
                x: doubleVal(arguments["x"]),
                y: doubleVal(arguments["y"]),
                dx: doubleVal(arguments["dx"]),
                dy: doubleVal(arguments["dy"]),
                text: arguments["text"] as? String ?? "",
                submit: arguments["submit"] as? Bool ?? false,
                clearFirst: arguments["clear"] as? Bool ?? false
            )
        case "ocu_batch":
            let rawSteps = arguments["steps"] as? [[String: Any]] ?? []
            let parsedSteps = rawSteps.map { stepDict -> IPCRequest in
                let rawCmd = (stepDict["command"] as? String) ?? (stepDict["tool"] as? String) ?? "click"
                let normalizedTool = rawCmd.hasPrefix("ocu_") ? rawCmd : "ocu_\(rawCmd)"
                return buildIPCRequest(for: normalizedTool, arguments: stepDict)
            }
            return IPCRequest(command: "batch", steps: parsedSteps)
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
                        "window_id": ["type": "integer", "description": "Optional window ID (#winID) to scope elements to a specific window"],
                        "window_title": ["type": "string", "description": "Optional window title substring to scope elements to a specific window"],
                        "focus": ["type": "boolean", "description": "Focus/activate the target app before scanning (default: false)"],
                        "window_only": ["type": "boolean", "description": "Capture and OCR only the target app's window to eliminate background desktop noise (default: true)"],
                        "compact": ["type": "boolean", "description": "Return token-compact tabular element output '@eX|src|role|x,y|label' (default: true)"],
                        "ocr": ["type": "boolean", "description": "Include Apple Vision OCR text detection for canvas/custom UI elements (default: true)"],
                        "som": ["type": "boolean", "description": "Return a Set-of-Marks (SoM) annotated screenshot with @eX badges and coordinate rulers (default: false)"],
                        "output": ["type": "string", "description": "Optional file path to save the screenshot PNG"]
                    ]
                ]
            ],
            [
                "name": "ocu_query",
                "description": "Fast, targeted query for UI elements matching a role (e.g. 'button', 'textField') and/or text substring without returning the entire window snapshot.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": ["type": "string", "description": "Optional application name to query"],
                        "window_id": ["type": "integer", "description": "Optional window ID filter"],
                        "window_title": ["type": "string", "description": "Optional window title substring filter"],
                        "role": ["type": "string", "description": "Optional role substring filter (e.g. 'button', 'textField', 'ocrText')"],
                        "text": ["type": "string", "description": "Optional label or value substring filter"],
                        "ocr": ["type": "boolean", "description": "Include Vision OCR elements if needed (default: true)"]
                    ]
                ]
            ],
            [
                "name": "ocu_upload_file",
                "description": "Select and submit a local file path inside an open macOS NSOpenPanel / File Picker dialog using Cmd+Shift+G path navigation.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute or ~/ file path to select in the open file dialog"],
                        "app": ["type": "string", "description": "Optional application name hosting the file dialog"]
                    ],
                    "required": ["path"]
                ]
            ],
            [
                "name": "ocu_secondary_action",
                "description": "Perform an Accessibility secondary action on an @eX element such as 'AXShowMenu' (context menu), 'AXIncrement', 'AXDecrement', 'AXConfirm', or 'AXCancel'.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "Element reference like '@e1'"],
                        "action": ["type": "string", "description": "AX action name (default: 'AXShowMenu')"]
                    ],
                    "required": ["target"]
                ]
            ],
            [
                "name": "ocu_click",
                "description": "Click a UI element by reference (@e1), fuzzy label text, or screen (x, y) coordinates with optional relative offset (dx, dy), smooth Bézier cursor trajectory, and visual HUD ripple.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "Element reference like '@e1' or visible text label"],
                        "x": ["type": "number", "description": "Screen X coordinate (if target is not specified)"],
                        "y": ["type": "number", "description": "Screen Y coordinate (if target is not specified)"],
                        "dx": ["type": "number", "description": "Relative X offset in points from target anchor (e.g. -150 to click left of @e37)"],
                        "dy": ["type": "number", "description": "Relative Y offset in points from target anchor (e.g. -45 to click above @e37)"],
                        "button": ["type": "string", "enum": ["left", "right", "center"], "description": "Mouse button (default: left)"],
                        "count": ["type": "integer", "description": "Click count: 1 for single click, 2 for double click (default: 1)"],
                        "ax_native": ["type": "boolean", "description": "Try triggering native kAXPressAction without moving physical mouse first (default: false)"]
                    ]
                ]
            ],
            [
                "name": "ocu_move",
                "description": "Smoothly move the mouse cursor to an element (@e1) or (x, y) coordinate (with optional dx, dy offset) along a human-like Bézier curve.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "Element reference like '@e1' or label"],
                        "x": ["type": "number", "description": "Screen X coordinate"],
                        "y": ["type": "number", "description": "Screen Y coordinate"],
                        "dx": ["type": "number", "description": "Relative X offset from target"],
                        "dy": ["type": "number", "description": "Relative Y offset from target"]
                    ]
                ]
            ],
            [
                "name": "ocu_type",
                "description": "Type text (English, Chinese, Emoji, or multi-line) into the focused field, a target element (@e1), a relative offset from @e1 (dx, dy), or (x, y) coordinates. Uses safe clipboard transaction to prevent IME garbling.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string", "description": "Text content to type"],
                        "target": ["type": "string", "description": "Optional element reference (@e1) to click before typing"],
                        "x": ["type": "number", "description": "Optional X coordinate to click before typing"],
                        "y": ["type": "number", "description": "Optional Y coordinate to click before typing"],
                        "dx": ["type": "number", "description": "Optional relative X offset from target to click before typing"],
                        "dy": ["type": "number", "description": "Optional relative Y offset from target to click before typing"],
                        "clear": ["type": "boolean", "description": "Select all (Cmd+A) and delete existing text before typing (default: false)"],
                        "submit": ["type": "boolean", "description": "Press Return/Enter after typing (default: false)"]
                    ],
                    "required": ["text"]
                ]
            ],
            [
                "name": "ocu_batch",
                "description": "Execute a sequence of UI actions (click, type, press, wait, snapshot) in a single atomic round-trip to minimize LLM turns and latency.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "steps": [
                            "type": "array",
                            "description": "Ordered list of action step objects (e.g. [{\"command\":\"click\",\"target\":\"@e22\"}, {\"command\":\"type\",\"target\":\"@e37\",\"dx\":-150,\"dy\":-45,\"text\":\"你好\",\"submit\":true}])",
                            "items": ["type": "object"]
                        ]
                    ],
                    "required": ["steps"]
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
            ],
            [
                "name": "ocu_browser",
                "description": "Zero-focus background browser DOM/JS bridge for Google Chrome, Arc, Edge, Brave, and Safari. List open tabs, navigate URLs, evaluate JavaScript, extract DOM elements, or click CSS selectors without activating the browser window.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["tabs", "navigate", "eval", "click", "dom"], "description": "Browser operation (default: tabs)"],
                        "browser": ["type": "string", "description": "Optional browser name ('Google Chrome', 'Safari', 'Arc', 'Microsoft Edge')"],
                        "url": ["type": "string", "description": "URL for 'navigate' action"],
                        "js": ["type": "string", "description": "JavaScript code for 'eval' action"],
                        "selector": ["type": "string", "description": "CSS selector or button text for 'click' action"],
                        "tab_filter": ["type": "string", "description": "Optional tab title or URL substring to target a specific background tab"],
                        "new_tab": ["type": "boolean", "description": "Open URL in a new background tab (default: false)"]
                    ]
                ]
            ],
            [
                "name": "ocu_sandbox",
                "description": "Manage the Ghost Space peripheral window sandbox ('park' moves a target app window out of the user's central workspace while keeping its GPU surface live for PiP; 'restore' returns it to its original frame; 'status' checks screen lock and parked windows).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["status", "park", "restore"], "description": "Sandbox action (default: status)"],
                        "app": ["type": "string", "description": "Application name to park or restore"]
                    ]
                ]
            ],
            [
                "name": "ocu_bill",
                "description": "View or finalize the current ComputerUse session usage bill (shows Operator Agent, Model, Duration, Input/Output/Vision/Saved Tokens, and Cost in USD) and optionally pop up the visual receipt card on screen.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "finish": ["type": "boolean", "description": "Finalize and close the current session bill immediately (default: false)"],
                        "show_popup": ["type": "boolean", "description": "Display the visual receipt card on the user's screen (default: true)"],
                        "agent": ["type": "string", "description": "Optional override for operator Agent name"],
                        "model": ["type": "string", "description": "Optional override for LLM Model name"]
                    ]
                ]
            ]
        ]
    }
}
