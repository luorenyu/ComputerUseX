import Foundation
import OCUCore

struct OCUCLI {
    static let version = "1.0.0"

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first else {
            printHelp()
            return
        }

        switch first {
        case "-h", "--help", "help":
            printHelp()
            return
        case "-v", "--version", "version":
            print("ocu (OpenComputerUse) v\(version)")
            return
        case "mcp":
            MCPServer.shared.runStdioLoop()
            return
        case "doctor":
            runDoctor(jsonOutput: args.contains("--json"))
            return
        default:
            break
        }

        let subArgs = Array(args.dropFirst())
        let jsonOutput = subArgs.contains("--json")
        let req = parseSubcommand(command: first, args: subArgs)
        let resp = UnixSocketIPC.executeRoutingThroughDaemonIfAvailable(req)

        if jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(resp),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            if !resp.ok {
                Foundation.exit(1)
            }
            return
        }

        renderHumanReadable(resp)
        if !resp.ok {
            Foundation.exit(1)
        }
    }

    static func parseSubcommand(command: String, args: [String]) -> IPCRequest {
        var positional: [String] = []
        var flags: [String: String] = [:]
        var boolFlags: Set<String> = []

        var i = 0
        while i < args.count {
            let token = args[i]
            if token.hasPrefix("--") {
                let key = String(token.dropFirst(2))
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    flags[key] = args[i + 1]
                    i += 2
                } else {
                    boolFlags.insert(key)
                    i += 1
                }
            } else if token.hasPrefix("-") && token.count > 1 && Double(token) == nil {
                // Short flag vs negative number (e.g. -240)
                let key = String(token.dropFirst(1))
                boolFlags.insert(key)
                i += 1
            } else {
                positional.append(token)
                i += 1
            }
        }

        switch command {
        case "status":
            return IPCRequest(command: "status")

        case "reset":
            return IPCRequest(command: "reset_safety")

        case "hud-demo", "demo":
            return IPCRequest(command: "hud_demo")

        case "apps":
            let appName = flags["focus"] ?? flags["launch"] ?? flags["app"] ?? positional.first
            var rx: Double? = nil
            var ry: Double? = nil
            var rw: Double? = nil
            var rh: Double? = nil
            if let resizeStr = flags["resize"] {
                let nums = resizeStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if nums.count == 4 {
                    rx = nums[0]; ry = nums[1]; rw = nums[2]; rh = nums[3]
                }
            }
            return IPCRequest(
                command: "apps",
                app: appName,
                x: rx,
                y: ry,
                width: rw,
                height: rh,
                launch: flags["launch"] != nil || !boolFlags.contains("no-launch"),
                focus: flags["focus"] != nil
            )

        case "snapshot", "snap":
            let enableOCR = !boolFlags.contains("no-ocr")
            let enableSoM = boolFlags.contains("som") || (flags["som"] == "true")
            return IPCRequest(
                command: "snapshot",
                app: flags["app"] ?? positional.first,
                ocr: enableOCR,
                som: enableSoM,
                outputPath: flags["output"] ?? flags["out"]
            )

        case "click":
            let btn: MouseButton
            if boolFlags.contains("right") || flags["button"] == "right" {
                btn = .right
            } else if boolFlags.contains("middle") || flags["button"] == "center" {
                btn = .center
            } else {
                btn = .left
            }
            let count = Int(flags["count"] ?? "") ?? (boolFlags.contains("double") ? 2 : 1)
            return IPCRequest(
                command: "click",
                target: flags["target"] ?? positional.first,
                x: Double(flags["x"] ?? ""),
                y: Double(flags["y"] ?? ""),
                button: btn,
                clickCount: count,
                axNative: boolFlags.contains("ax-native")
            )

        case "move":
            return IPCRequest(
                command: "move",
                target: flags["target"] ?? positional.first,
                x: Double(flags["x"] ?? ""),
                y: Double(flags["y"] ?? "")
            )

        case "type":
            let targetRef: String?
            let textVal: String
            if let explicitTarget = flags["target"] {
                targetRef = explicitTarget
                textVal = flags["text"] ?? positional.joined(separator: " ")
            } else if positional.count >= 2 && positional[0].hasPrefix("@") {
                targetRef = positional[0]
                textVal = positional.dropFirst().joined(separator: " ")
            } else {
                targetRef = nil
                textVal = flags["text"] ?? positional.joined(separator: " ")
            }
            return IPCRequest(
                command: "type",
                target: targetRef,
                text: textVal,
                submit: boolFlags.contains("submit") || boolFlags.contains("enter"),
                clearFirst: boolFlags.contains("clear")
            )

        case "press", "key":
            return IPCRequest(
                command: "press",
                keys: flags["keys"] ?? positional.first ?? ""
            )

        case "scroll":
            return IPCRequest(
                command: "scroll",
                target: flags["target"] ?? positional.first,
                x: Double(flags["x"] ?? ""),
                y: Double(flags["y"] ?? ""),
                dx: Double(flags["dx"] ?? "0"),
                dy: Double(flags["dy"] ?? "-240")
            )

        case "drag":
            var fromRef: String? = flags["from"]
            var toRef: String? = flags["to"]
            var fx = Double(flags["from-x"] ?? "")
            var fy = Double(flags["from-y"] ?? "")
            var tx = Double(flags["to-x"] ?? "")
            var ty = Double(flags["to-y"] ?? "")

            if let f = fromRef, f.contains(",") {
                let parts = f.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { fx = parts[0]; fy = parts[1]; fromRef = nil }
            }
            if let t = toRef, t.contains(",") {
                let parts = t.split(separator: ",").compactMap { Double($0) }
                if parts.count == 2 { tx = parts[0]; ty = parts[1]; toRef = nil }
            }
            return IPCRequest(
                command: "drag",
                target: fromRef,
                toTarget: toRef,
                x: fx,
                y: fy,
                toX: tx,
                toY: ty,
                timeout: Double(flags["duration"] ?? "0.3")
            )

        case "wait":
            return IPCRequest(
                command: "wait",
                text: flags["text"] ?? positional.first,
                timeout: Double(flags["timeout"] ?? flags["seconds"] ?? "3.0")
            )

        default:
            return IPCRequest(command: command)
        }
    }

    static func renderHumanReadable(_ resp: IPCResponse) {
        if !resp.ok {
            if let err = resp.error {
                print("❌ [\(err.code.rawValue)] \(err.message)")
                print("💡 Recovery Hint: \(err.recoveryHint)")
            } else {
                print("❌ Operation failed.")
            }
            return
        }

        if let st = resp.status {
            print("╔══════════════════════════════════════════════════════════════╗")
            print("║                OpenComputerUse (ocu) Status                  ║")
            print("╠══════════════════════════════════════════════════════════════╣")
            print("║ Accessibility Permission : \(st.accessibilityGranted ? "✅ Granted" : "⚠️  Not Granted (Required for AX/Click)")")
            print("║ Screen Record Permission : \(st.screenRecordingGranted ? "✅ Granted" : "⚠️  Not Granted (Required for OCR/SoM)")")
            print("║ MenuBar HUD Daemon       : \(st.daemonConnected ? "🟢 Connected (\(st.socketPath))" : "⚪ Standalone Mode (App not running)")")
            print("║ Active Application       : \(st.activeApp ?? "None")")
            print("║ Screen Logical Bounds    : \(Int(st.screenBounds.width))×\(Int(st.screenBounds.height)) @\(Int(st.scaleFactor))x")
            print("║ Current Mouse Position   : (\(Int(st.mouseLocation.x)), \(Int(st.mouseLocation.y)))")
            print("║ Kill Switch (Opt+Esc)    : \(st.killSwitchTripped ? "🛑 Tripped (Run 'ocu reset')" : "🟢 Armed & Safe")")
            print("╚══════════════════════════════════════════════════════════════╝")
        }

        if let apps = resp.apps {
            print("Running GUI Applications (\(apps.count)):")
            for app in apps {
                let marker = app.isActive ? "★" : " "
                print(" \(marker) [PID \(app.pid)] \(app.name) (\(app.bundleId ?? "-")) — \(app.windows.count) window(s)")
                for win in app.windows.prefix(3) {
                    let title = win.title.isEmpty ? "(Untitled)" : win.title
                    print("      └─ #\(win.windowId) \"\(title)\" [\(Int(win.frame.x)),\(Int(win.frame.y)) \(Int(win.frame.width))×\(Int(win.frame.height))]")
                }
            }
        }

        if let snap = resp.snapshot {
            print("📸 Snapshot [\(snap.snapshotId)] — App: \(snap.activeApp) (PID \(snap.activePid)) | Window: \(snap.windowTitle ?? "-")")
            print("   Elements: \(snap.elements.count) total (AX: \(snap.axCount), Vision OCR: \(snap.ocrCount))")
            if let somPath = snap.annotatedScreenshotPath {
                print("   SoM Annotated Image: \(somPath)")
            } else if let rawPath = snap.screenshotPath {
                print("   Screenshot Image: \(rawPath)")
            }
            print("────────────────────────────────────────────────────────────────────────")
            for el in snap.elements {
                let tag = el.ref.padding(toLength: 5, withPad: " ", startingAt: 0)
                let src = el.source.rawValue.uppercased().padding(toLength: 3, withPad: " ", startingAt: 0)
                let role = el.role.padding(toLength: 12, withPad: " ", startingAt: 0)
                let coords = "(\(Int(el.centerPoint.x)),\(Int(el.centerPoint.y)))".padding(toLength: 11, withPad: " ", startingAt: 0)
                let valSuffix = (el.value != nil && !el.value!.isEmpty && el.value != el.label) ? " = \"\(el.value!)\"" : ""
                print(" \(tag) [\(src)] \(role) \(coords) \"\(el.label)\"\(valSuffix)")
            }
        }

        if let outcome = resp.outcome {
            let ptStr = outcome.point.map { " @ (\($0.x), \($0.y))" } ?? ""
            print("✅ [\(outcome.action)] \(outcome.targetDescription)\(ptStr) (\(outcome.elapsedMs)ms)")
            if let details = outcome.details {
                print("   Details: \(details)")
            }
        }
    }

    static func runDoctor(jsonOutput: Bool) {
        let st = PermissionManager.shared.currentStatus(
            daemonConnected: UnixSocketIPC.isDaemonReachable(),
            socketPath: UnixSocketIPC.defaultSocketPath
        )
        let toolsCount = MCPServer.toolDefinitions().count
        let appsCount = AppWorkspaceController.shared.listRunningApps().count

        if jsonOutput {
            let dict: [String: Any] = [
                "version": version,
                "accessibilityGranted": st.accessibilityGranted,
                "screenRecordingGranted": st.screenRecordingGranted,
                "daemonConnected": st.daemonConnected,
                "runningAppsCount": appsCount,
                "mcpToolsRegistered": toolsCount,
                "screenBounds": [
                    "width": st.screenBounds.width,
                    "height": st.screenBounds.height,
                    "scaleFactor": st.scaleFactor
                ]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
            return
        }

        print("🩺 OpenComputerUse (ocu) v\(version) System Diagnostics")
        print("────────────────────────────────────────────────────────")
        print("1. [Permissions]")
        print("   • Accessibility (AXUIElement & CGEvent): \(st.accessibilityGranted ? "✅ Ready" : "⚠️  Not Granted (Open System Settings > Privacy > Accessibility)")")
        print("   • Screen Recording (OCR & SoM Capture) : \(st.screenRecordingGranted ? "✅ Ready" : "⚠️  Not Granted (Open System Settings > Privacy > Screen Recording)")")
        print("2. [Visual HUD Daemon]")
        print("   • OpenComputerUse.app IPC Socket       : \(st.daemonConnected ? "✅ Connected (\(st.socketPath))" : "ℹ️  Not running (CLI/MCP will execute directly in standalone mode)")")
        print("3. [Display & Workspace]")
        print("   • Main Display                         : \(Int(st.screenBounds.width))×\(Int(st.screenBounds.height)) logical pts (@\(Int(st.scaleFactor))x Retina)")
        print("   • Active GUI Applications              : \(appsCount) apps detected (frontmost: \(st.activeApp ?? "None"))")
        print("4. [MCP Server Readiness]")
        print("   • Registered MCP Tools                 : ✅ \(toolsCount) tools ready (`ocu mcp`)")
        print("────────────────────────────────────────────────────────")
    }

    static func printHelp() {
        print("""
        OpenComputerUse (ocu) v\(version) — Product-Grade macOS Computer Use CLI & MCP Server

        USAGE:
          ocu <command> [options]

        CORE COMMANDS:
          status                              Show permissions, HUD daemon status, screen & cursor info
          doctor                              Run full diagnostic check on permissions, OCR, and MCP readiness
          apps [--focus <app>] [--launch <app>] [--resize x,y,w,h]
                                              List running GUI apps & windows, or focus/launch/resize an app
          snapshot [--app <name>] [--no-ocr] [--som] [--output <path>]
                                              Scan UI via AX Tree + Apple Vision OCR and assign @e1..@eN refs
          click <@eX|label> [--right] [--double] [--ax-native]
          click --x <num> --y <num>           Smoothly move cursor with HUD ripple and click target
          move <@eX> | --x <num> --y <num>    Glide cursor along a cubic Bézier curve to target
          type [<@eX>] <text> [--clear] [--submit]
                                              Focus optional @eX and type Chinese/English/Emoji safely
          press <shortcut>                    Press key or combo (e.g. 'enter', 'cmd+c', 'cmd+shift+p')
          scroll --dy <pixels> [--dx <pixels>] [--target <@eX>]
                                              Smooth pixel scrolling
          drag --from <@e1|x,y> --to <@e2|x,y>
                                              Smoothly drag between two elements or points
          wait [--text <query>] [--timeout <sec>]
                                              Wait for text to appear on screen or pause for N seconds
          hud-demo                            Run interactive visual HUD trajectory & ripple showcase
          reset                               Reset Option+Escape emergency Kill Switch
          mcp                                 Start standard Model Context Protocol (MCP) stdio server

        GLOBAL FLAGS:
          --json                              Output structured JSON response
          -h, --help                          Show this help message
          -v, --version                       Show version
        """)
    }
}

OCUCLI.main()
