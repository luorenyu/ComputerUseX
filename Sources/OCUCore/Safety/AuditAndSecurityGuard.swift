import Foundation
import AppKit

public struct AuditRecord: Codable, Sendable {
    public var timestamp: String
    public var command: String
    public var app: String?
    public var windowID: UInt32?
    public var target: String?
    public var point: ScreenPoint?
    public var success: Bool
    public var details: String?
    public var elapsedMs: Int

    public init(
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        command: String,
        app: String? = nil,
        windowID: UInt32? = nil,
        target: String? = nil,
        point: ScreenPoint? = nil,
        success: Bool,
        details: String? = nil,
        elapsedMs: Int
    ) {
        self.timestamp = timestamp
        self.command = command
        self.app = app
        self.windowID = windowID
        self.target = target
        self.point = point
        self.success = success
        self.details = details
        self.elapsedMs = elapsedMs
    }
}

public struct OCUSecurityConfig: Codable, Sendable {
    public var allowedApps: [String]
    public var blockedApps: [String]
    public var auditLoggingEnabled: Bool
    public var autoPostActionDiff: Bool
    public var interactiveAppConsent: Bool

    public static let defaultAllowedApps: [String] = [
        "WeChat",
        "iPhone Mirroring",
        "Google Chrome",
        "Android Studio",
        "Safari"
    ]

    public static let defaultBlockedApps: [String] = [
        "1Password",
        "Keychain Access",
        "钥匙串访问",
        "Bitwarden",
        "LastPass",
        "KeePassXC",
        "Passwords",
        "密码"
    ]

    public init(
        allowedApps: [String] = Self.defaultAllowedApps,
        blockedApps: [String] = Self.defaultBlockedApps,
        auditLoggingEnabled: Bool = true,
        autoPostActionDiff: Bool = true,
        interactiveAppConsent: Bool = false
    ) {
        self.allowedApps = allowedApps
        self.blockedApps = blockedApps
        self.auditLoggingEnabled = auditLoggingEnabled
        self.autoPostActionDiff = autoPostActionDiff
        self.interactiveAppConsent = interactiveAppConsent
    }
}

public final class AuditAndSecurityGuard: @unchecked Sendable {
    public static let shared = AuditAndSecurityGuard()

    private let lock = NSLock()
    private var cachedConfig: OCUSecurityConfig?
    private var sessionApprovedApps: Set<String> = []
    private var sessionDeniedApps: Set<String> = []

    public var baseDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".computerusex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var configFileURL: URL {
        baseDirectory.appendingPathComponent("config.json")
    }

    public var auditFileURL: URL {
        baseDirectory.appendingPathComponent("audit.jsonl")
    }

    private init() {}

    public func loadConfig() -> OCUSecurityConfig {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedConfig {
            return cached
        }
        if let data = try? Data(contentsOf: configFileURL),
           let decoded = try? JSONDecoder().decode(OCUSecurityConfig.self, from: data) {
            cachedConfig = decoded
            return decoded
        }
        let defaultCfg = OCUSecurityConfig()
        cachedConfig = defaultCfg
        if let encoded = try? JSONEncoder().encode(defaultCfg) {
            try? encoded.write(to: configFileURL, options: .atomic)
        }
        return defaultCfg
    }

    /// Verifies that the target application is not on the sensitive credential/password manager blocklist
    /// unless explicitly added to `allowedApps` in `~/.opencomputeruse/config.json`.
    public func verifyAppAllowed(appName: String?, bundleId: String? = nil) throws {
        guard let name = appName, !name.isEmpty else { return }
        let config = loadConfig()
        let lowerName = name.lowercased()
        let lowerBundle = bundleId?.lowercased() ?? ""

        // Explicit allowlist overrides default blocklist
        if config.allowedApps.contains(where: {
            let pat = $0.lowercased()
            return lowerName.contains(pat) || (!lowerBundle.isEmpty && lowerBundle.contains(pat))
        }) {
            return
        }

        if config.blockedApps.contains(where: {
            let pat = $0.lowercased()
            return lowerName == pat || lowerName.contains(pat) || (!lowerBundle.isEmpty && lowerBundle.contains(pat))
        }) {
            throw OCUError(
                code: .blockedApp,
                message: "Access to sensitive application '\(name)' is blocked by ComputerUseX security guardrail.",
                recoveryHint: "Add '\(name)' to 'allowedApps' in ~/.computerusex/config.json if you explicitly want to automate it."
            )
        }

        // Per-App First-Time Interactive Consent Modal (when interactiveAppConsent is enabled)
        if config.interactiveAppConsent {
            lock.lock()
            let alreadyApproved = sessionApprovedApps.contains(lowerName)
            let alreadyDenied = sessionDeniedApps.contains(lowerName)
            lock.unlock()

            if alreadyDenied {
                throw OCUError(
                    code: .blockedApp,
                    message: "User denied ComputerUseX access to application '\(name)' for this session.",
                    recoveryHint: "Run 'cux allow-app \"\(name)\"' to grant access."
                )
            }

            if !alreadyApproved {
                let operatorIdentity = SessionBillingManager.shared.detectCurrentOperator()
                let granted = promptInteractiveAppConsent(
                    appName: name,
                    agentName: operatorIdentity.agentName,
                    modelName: operatorIdentity.modelName
                )
                if !granted {
                    throw OCUError(
                        code: .blockedApp,
                        message: "User declined interactive permission to operate '\(name)'.",
                        recoveryHint: "Approve the prompt or run 'cux allow-app \"\(name)\"'."
                    )
                }
            }
        }
    }

    public func setInteractiveConsentEnabled(_ enabled: Bool) {
        var cfg = loadConfig()
        cfg.interactiveAppConsent = enabled
        saveConfig(cfg)
    }

    public func saveConfig(_ config: OCUSecurityConfig) {
        lock.lock()
        cachedConfig = config
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
            try? data.write(to: configFileURL, options: .atomic)
        }
    }

    public func updateAppPermission(appName: String, allow: Bool) -> ActionOutcome {
        var cfg = loadConfig()
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        lock.lock()
        if allow {
            sessionApprovedApps.insert(lower)
            sessionDeniedApps.remove(lower)
        } else {
            sessionDeniedApps.insert(lower)
            sessionApprovedApps.remove(lower)
        }
        lock.unlock()

        if allow {
            if !cfg.allowedApps.contains(where: { $0.lowercased() == lower }) {
                cfg.allowedApps.append(trimmed)
            }
            cfg.blockedApps.removeAll(where: { $0.lowercased() == lower })
        } else {
            if !cfg.blockedApps.contains(where: { $0.lowercased() == lower }) {
                cfg.blockedApps.append(trimmed)
            }
            cfg.allowedApps.removeAll(where: { $0.lowercased() == lower })
        }
        saveConfig(cfg)
        return ActionOutcome(
            action: allow ? "allow_app" : "block_app",
            targetDescription: "\(allow ? "Allowed" : "Blocked") app '\(trimmed)' in security policy",
            details: "Saved to \(configFileURL.path)",
            elapsedMs: 2
        )
    }

    public func removeAllowedApp(_ appName: String) {
        var cfg = loadConfig()
        let lower = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cfg.allowedApps.removeAll { $0.lowercased() == lower }
        lock.lock()
        sessionApprovedApps.remove(lower)
        lock.unlock()
        saveConfig(cfg)
    }

    public func removeBlockedApp(_ appName: String) {
        var cfg = loadConfig()
        let lower = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cfg.blockedApps.removeAll { $0.lowercased() == lower }
        lock.lock()
        sessionDeniedApps.remove(lower)
        lock.unlock()
        saveConfig(cfg)
    }

    /// Displays a native macOS modal authorization dialog on first access to an unapproved application.
    public func promptInteractiveAppConsent(appName: String, agentName: String, modelName: String) -> Bool {
        final class ConsentBox: @unchecked Sendable {
            var responseCode: NSApplication.ModalResponse = .alertThirdButtonReturn
        }
        let box = ConsentBox()
        let runModalBlock = {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "🤖 \(agentName) 请求操控「\(appName)」"
            alert.informativeText = """
            当前操作者: \(agentName)
            使用模型: \(modelName)
            目标应用: \(appName)

            是否允许该 Agent 通过 ComputerUseX 扫描并操作「\(appName)」？
            """
            alert.addButton(withTitle: "允许并加入白名单 (Always Allow)")
            alert.addButton(withTitle: "仅本次会话允许 (Allow Once)")
            alert.addButton(withTitle: "拒绝拦截 (Deny)")
            NSApp?.activate(ignoringOtherApps: true)
            box.responseCode = alert.runModal()
        }

        if Thread.isMainThread {
            runModalBlock()
        } else {
            DispatchQueue.main.sync(execute: runModalBlock)
        }

        let lower = appName.lowercased()
        switch box.responseCode {
        case .alertFirstButtonReturn:
            _ = updateAppPermission(appName: appName, allow: true)
            return true
        case .alertSecondButtonReturn:
            lock.lock()
            sessionApprovedApps.insert(lower)
            lock.unlock()
            return true
        default:
            lock.lock()
            sessionDeniedApps.insert(lower)
            lock.unlock()
            return false
        }
    }

    public func recordAudit(_ record: AuditRecord) {
        let config = loadConfig()
        guard config.auditLoggingEnabled else { return }
        lock.lock()
        defer { lock.unlock() }

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(record),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: auditFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: auditFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: lineData)
            }
        } else {
            try? lineData.write(to: auditFileURL, options: .atomic)
        }
    }

    public func recentAuditRecords(limit: Int = 25) -> [AuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let content = try? String(contentsOf: auditFileURL, encoding: .utf8) else {
            return []
        }
        let lines = content.split(separator: "\n").suffix(max(1, limit))
        let decoder = JSONDecoder()
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(AuditRecord.self, from: data)
        }
    }

    /// One-line MCP & Skill configuration installer for Claude Code/Desktop, Codex, Gemini/Antigravity, Cursor, Windsurf, OpenClaw, OpenCode, Pi, MiniMaxCode, and Harness.
    public func installMCPConfiguration(target: String = "all", binaryPath: String? = nil) throws -> ActionOutcome {
        let resolvedBin: String = {
            if let custom = binaryPath, !custom.isEmpty { return custom }
            let appBin = "/Applications/ComputerUseX.app/Contents/MacOS/cux"
            if FileManager.default.fileExists(atPath: appBin) { return appBin }
            let localBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cux").path
            if FileManager.default.fileExists(atPath: localBin) { return localBin }
            return CommandLine.arguments.first ?? localBin
        }()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let lowerTarget = target.lowercased()
        var updatedPaths: [String] = []

        func buildSkillMarkdown(forAgent agentLabel: String) -> String {
            return """
            ---
            name: computer-use-x
            description: "Controls macOS GUI applications and desktop interfaces in the background without stealing mouse focus using ComputerUseX (`cux`) hybrid perception (AXUIElement + Apple Vision OCR + SoM), persistent Live PiP preview window, and session billing."
            disable-model-invocation: false
            ---

            # ComputerUseX (`cux`) — Zero-Focus Desktop Computer Use Skill

            Use `cux_*` MCP tools (`cux_snapshot`, `cux_click`, `cux_type`, `cux_batch`, `cux_browser`, `cux_bill`) or the `cux` CLI (`\(resolvedBin)`) with `--agent "\(agentLabel)"` to inspect and operate macOS apps in the background without hijacking the user's physical mouse cursor.

            ## Core CLI Workflow
            ```bash
            # 1. Inspect target app UI (assigns @e1..@eN references)
            \(resolvedBin) snapshot --app "WeChat" --compact --agent "\(agentLabel)"

            # 2. Click or type in the background without stealing foreground focus
            \(resolvedBin) click @e3 --agent "\(agentLabel)"
            \(resolvedBin) type @e5 "Hello from \(agentLabel)" --clear --submit --agent "\(agentLabel)"

            # 3. Complete task session and close Live PiP preview
            \(resolvedBin) bill --finish --agent "\(agentLabel)"
            ```
            """
        }

        func installSkillFile(at skillDir: URL, agentLabel: String) throws {
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            let skillFileURL = skillDir.appendingPathComponent("SKILL.md")
            try buildSkillMarkdown(forAgent: agentLabel).write(to: skillFileURL, atomically: true, encoding: .utf8)
            updatedPaths.append(skillFileURL.path)
        }

        func upsertJSONMCPServer(at fileURL: URL) throws {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var root: [String: Any] = [:]
            if let existingData = try? Data(contentsOf: fileURL),
               let obj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                root = obj
            }
            var mcpServers = (root["mcpServers"] as? [String: Any]) ?? [:]
            mcpServers["computer-use-x"] = [
                "command": resolvedBin,
                "args": ["mcp"]
            ]
            root["mcpServers"] = mcpServers
            let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: fileURL, options: .atomic)
            updatedPaths.append(fileURL.path)
        }

        // Universal Agent Skills Hub (~/.agents/skills/computer-use-x/SKILL.md)
        if lowerTarget == "all" {
            try? installSkillFile(
                at: home.appendingPathComponent(".agents/skills/computer-use-x", isDirectory: true),
                agentLabel: "Agent"
            )
        }

        if lowerTarget == "all" || lowerTarget == "claude" {
            try upsertJSONMCPServer(at: home.appendingPathComponent(".claude.json"))
            try? installSkillFile(
                at: home.appendingPathComponent(".claude/skills/computer-use-x", isDirectory: true),
                agentLabel: "Claude Code"
            )
            let claudeDesktopDir = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
            if FileManager.default.fileExists(atPath: claudeDesktopDir.path) {
                try? upsertJSONMCPServer(at: claudeDesktopDir.appendingPathComponent("claude_desktop_config.json"))
            }
        }
        if lowerTarget == "all" || lowerTarget == "gemini" || lowerTarget == "antigravity" {
            try upsertJSONMCPServer(at: home.appendingPathComponent(".gemini/settings.json"))
            let agyDir = home.appendingPathComponent(".gemini/antigravity", isDirectory: true)
            if FileManager.default.fileExists(atPath: agyDir.path) {
                try? upsertJSONMCPServer(at: agyDir.appendingPathComponent("mcp_config.json"))
            }
        }
        if lowerTarget == "all" || lowerTarget == "cursor" {
            try upsertJSONMCPServer(at: home.appendingPathComponent(".cursor/mcp.json"))
        }
        if lowerTarget == "all" || lowerTarget == "windsurf" {
            let wsDir = home.appendingPathComponent(".codeium/windsurf", isDirectory: true)
            if lowerTarget == "windsurf" || FileManager.default.fileExists(atPath: wsDir.path) {
                try upsertJSONMCPServer(at: wsDir.appendingPathComponent("mcp_config.json"))
            }
        }
        if lowerTarget == "all" || lowerTarget == "openclaw" {
            let openclawDir = home.appendingPathComponent(".openclaw", isDirectory: true)
            if lowerTarget == "openclaw" || FileManager.default.fileExists(atPath: openclawDir.path) {
                try installSkillFile(
                    at: openclawDir.appendingPathComponent("skills/computer-use-x", isDirectory: true),
                    agentLabel: "OpenClaw"
                )
                let openclawJSON = openclawDir.appendingPathComponent("openclaw.json")
                var root: [String: Any] = [:]
                if let existingData = try? Data(contentsOf: openclawJSON),
                   let obj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                    root = obj
                }
                var mcpDict = (root["mcp"] as? [String: Any]) ?? [:]
                var serversDict = (mcpDict["servers"] as? [String: Any]) ?? [:]
                serversDict["computer-use-x"] = [
                    "command": resolvedBin,
                    "args": ["mcp"]
                ]
                mcpDict["servers"] = serversDict
                root["mcp"] = mcpDict
                if let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                    try? outData.write(to: openclawJSON, options: .atomic)
                    updatedPaths.append(openclawJSON.path)
                }
            }
        }
        if lowerTarget == "all" || lowerTarget == "opencode" {
            let opencodeConfigDir = home.appendingPathComponent(".config/opencode", isDirectory: true)
            if lowerTarget == "opencode" || FileManager.default.fileExists(atPath: opencodeConfigDir.path) || FileManager.default.fileExists(atPath: home.appendingPathComponent(".opencode").path) {
                try installSkillFile(
                    at: opencodeConfigDir.appendingPathComponent("skills/computer-use-x", isDirectory: true),
                    agentLabel: "OpenCode"
                )
                let opencodeJSON = opencodeConfigDir.appendingPathComponent("opencode.json")
                var root: [String: Any] = [:]
                if let existingData = try? Data(contentsOf: opencodeJSON),
                   let obj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                    root = obj
                }
                var mcpDict = (root["mcp"] as? [String: Any]) ?? [:]
                mcpDict["computer-use-x"] = [
                    "type": "local",
                    "command": [resolvedBin, "mcp"],
                    "enabled": true
                ]
                root["mcp"] = mcpDict
                if let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                    try? outData.write(to: opencodeJSON, options: .atomic)
                    updatedPaths.append(opencodeJSON.path)
                }
            }
        }
        if lowerTarget == "all" || lowerTarget == "pi" {
            let piDir = home.appendingPathComponent(".pi/agent", isDirectory: true)
            if lowerTarget == "pi" || FileManager.default.fileExists(atPath: home.appendingPathComponent(".pi").path) {
                try installSkillFile(
                    at: piDir.appendingPathComponent("skills/computer-use-x", isDirectory: true),
                    agentLabel: "Pi"
                )
                try upsertJSONMCPServer(at: piDir.appendingPathComponent("mcp.json"))
            }
        }
        if lowerTarget == "all" || lowerTarget == "minimax" || lowerTarget == "minimaxcode" || lowerTarget == "mmx" {
            let minimaxDir = home.appendingPathComponent(".minimax-code", isDirectory: true)
            if lowerTarget != "all" || FileManager.default.fileExists(atPath: minimaxDir.path) {
                try installSkillFile(
                    at: minimaxDir.appendingPathComponent("skills/computer-use-x", isDirectory: true),
                    agentLabel: "MiniMaxCode"
                )
                try upsertJSONMCPServer(at: minimaxDir.appendingPathComponent("mcp.json"))
            }
        }
        if lowerTarget == "all" || lowerTarget == "harness" || lowerTarget == "hermes" {
            let harnessDir = home.appendingPathComponent(".harness", isDirectory: true)
            if lowerTarget == "harness" || FileManager.default.fileExists(atPath: harnessDir.path) {
                try installSkillFile(
                    at: harnessDir.appendingPathComponent("skills/computer-use-x", isDirectory: true),
                    agentLabel: "Harness"
                )
                try upsertJSONMCPServer(at: harnessDir.appendingPathComponent("mcp.json"))
            }
            let hermesDir = home.appendingPathComponent(".hermes", isDirectory: true)
            if lowerTarget == "hermes" || FileManager.default.fileExists(atPath: hermesDir.path) {
                try installSkillFile(
                    at: hermesDir.appendingPathComponent("skills/computer-use-x", isDirectory: true),
                    agentLabel: "Harness"
                )
                let hermesYAML = hermesDir.appendingPathComponent("config.yaml")
                var yamlText = (try? String(contentsOf: hermesYAML, encoding: .utf8)) ?? ""
                if !yamlText.contains("computer-use-x:") {
                    if !yamlText.contains("mcp_servers:") {
                        yamlText.append("\nmcp_servers:\n")
                    }
                    yamlText.append("""
                      computer-use-x:
                        command: "\(resolvedBin)"
                        args: ["mcp"]
                        enabled: true
                    """)
                    try? yamlText.write(to: hermesYAML, atomically: true, encoding: .utf8)
                    updatedPaths.append(hermesYAML.path)
                }
            }
        }
        if lowerTarget == "all" || lowerTarget == "codex" {
            let codexDir = home.appendingPathComponent(".codex", isDirectory: true)
            let codexURL = codexDir.appendingPathComponent("config.toml")
            try FileManager.default.createDirectory(
                at: codexDir,
                withIntermediateDirectories: true
            )

            // 1. Install Codex Skill (~/.codex/skills/computer-use-x/SKILL.md)
            let skillDir = codexDir.appendingPathComponent("skills/computer-use-x", isDirectory: true)
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            let skillMDContent = buildSkillMarkdown(forAgent: "Codex")
            let skillFileURL = skillDir.appendingPathComponent("SKILL.md")
            try skillMDContent.write(to: skillFileURL, atomically: true, encoding: .utf8)
            updatedPaths.append(skillFileURL.path)

            // 2. Install Codex Native Plugin Bundle (~/.computerusex/codex-marketplace & ~/.codex/plugins/cache/computer-use-x)
            let marketplaceRoot = self.baseDirectory.appendingPathComponent("codex-marketplace", isDirectory: true)
            let marketplaceMetaDir = marketplaceRoot.appendingPathComponent(".agents/plugins", isDirectory: true)
            let pluginBundleDir = marketplaceRoot.appendingPathComponent("plugins/computer-use-x", isDirectory: true)
            let codexPluginCacheDir = codexDir.appendingPathComponent("plugins/cache/computer-use-x/computer-use-x/1.0.0", isDirectory: true)

            for targetPluginDir in [pluginBundleDir, codexPluginCacheDir] {
                let metaDir = targetPluginDir.appendingPathComponent(".codex-plugin", isDirectory: true)
                let pSkillDir = targetPluginDir.appendingPathComponent("skills/computer-use-x", isDirectory: true)
                let assetsDir = targetPluginDir.appendingPathComponent("assets", isDirectory: true)
                try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: pSkillDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

                let mcpJSON = """
                {
                  "mcpServers": {
                    "computer-use-x": {
                      "command": "\(resolvedBin)",
                      "args": ["mcp"],
                      "enabled": true
                    }
                  }
                }
                """
                try mcpJSON.write(to: targetPluginDir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
                try skillMDContent.write(to: pSkillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

                let pluginJSON = """
                {
                  "name": "computer-use-x",
                  "version": "1.0.0",
                  "description": "Zero-focus native macOS Computer Use engine (AXUIElement + Apple Vision OCR + Live PiP Preview + Gemini Aurora HUD + Session Billing).",
                  "author": {
                    "name": "ComputerUseX",
                    "url": "https://github.com/luorenyu/ComputerUseX"
                  },
                  "homepage": "https://github.com/luorenyu/ComputerUseX",
                  "repository": "https://github.com/luorenyu/ComputerUseX",
                  "license": "MIT",
                  "keywords": ["computer-use", "computer-use-x", "cux", "macos", "automation", "accessibility", "mcp"],
                  "skills": "./skills/",
                  "mcpServers": "./.mcp.json",
                  "interface": {
                    "displayName": "ComputerUseX",
                    "shortDescription": "Zero-focus background Computer Use engine with Live PiP & Gemini HUD",
                    "longDescription": "ComputerUseX (cux) lets Codex operate macOS desktop apps in the background without hijacking your physical mouse or stealing window focus, featuring Tri-Modal Grounding (AX + Vision OCR + SoM), a persistent bottom-right Live PiP preview window, and full task session billing.",
                    "developerName": "ComputerUseX",
                    "category": "Productivity",
                    "capabilities": ["Interactive", "Read", "Write"],
                    "websiteURL": "https://github.com/luorenyu/ComputerUseX",
                    "logo": "./assets/app-icon.png",
                    "logoDark": "./assets/app-icon.png",
                    "composerIcon": "./assets/app-icon.png",
                    "defaultPrompt": [
                      "Use ComputerUseX to inspect WeChat in the background and send a message",
                      "Open ComputerUseX Control Center and run the visual HUD demo",
                      "Check current ComputerUseX session billing receipt"
                    ],
                    "brandColor": "#4285F4",
                    "screenshots": []
                  }
                }
                """
                try pluginJSON.write(to: metaDir.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)

                let bundledIcon = "/Applications/ComputerUseX.app/Contents/Resources/app-icon.png"
                if FileManager.default.fileExists(atPath: bundledIcon) {
                    let dstIcon = assetsDir.appendingPathComponent("app-icon.png")
                    try? FileManager.default.removeItem(at: dstIcon)
                    try? FileManager.default.copyItem(atPath: bundledIcon, toPath: dstIcon.path)
                }
            }

            try FileManager.default.createDirectory(at: marketplaceMetaDir, withIntermediateDirectories: true)
            let marketplaceJSON = """
            {
              "name": "computer-use-x",
              "plugins": [
                {
                  "name": "computer-use-x",
                  "source": {
                    "source": "local",
                    "path": "./plugins/computer-use-x"
                  },
                  "policy": {
                    "installation": "AVAILABLE",
                    "authentication": "ON_USE"
                  },
                  "category": "Productivity"
                }
              ]
            }
            """
            try marketplaceJSON.write(to: marketplaceMetaDir.appendingPathComponent("marketplace.json"), atomically: true, encoding: .utf8)

            // 3. Register Marketplace, Plugin, and MCP Server in ~/.codex/config.toml
            var toml = (try? String(contentsOf: codexURL, encoding: .utf8)) ?? ""
            var appendedBlocks: [String] = []

            let marketplaceHeader = "[marketplaces.computer-use-x]"
            if !toml.contains(marketplaceHeader) {
                appendedBlocks.append("""
                \(marketplaceHeader)
                source_type = "local"
                source = "\(marketplaceRoot.path)"
                """)
            }

            let pluginHeader = "[plugins.\"computer-use-x@computer-use-x\"]"
            if !toml.contains(pluginHeader) {
                appendedBlocks.append("""
                \(pluginHeader)
                enabled = true
                """)
            }

            let sectionHeader = "[mcp_servers.computer_use_x]"
            if !toml.contains(sectionHeader) {
                appendedBlocks.append("""
                \(sectionHeader)
                type = "stdio"
                command = "\(resolvedBin)"
                args = ["mcp"]
                """)
            }

            if !appendedBlocks.isEmpty {
                if !toml.isEmpty && !toml.hasSuffix("\n") { toml.append("\n") }
                toml.append("\n" + appendedBlocks.joined(separator: "\n\n") + "\n")
                try toml.write(to: codexURL, atomically: true, encoding: .utf8)
            }
            updatedPaths.append(codexURL.path)
        }

        return ActionOutcome(
            action: "install_mcp",
            targetDescription: "Installed computer-use-x MCP to \(updatedPaths.count) config(s)",
            details: updatedPaths.joined(separator: ", "),
            elapsedMs: 5
        )
    }
}
