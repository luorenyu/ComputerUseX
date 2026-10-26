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
            .appendingPathComponent(".opencomputeruse", isDirectory: true)
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
                message: "Access to sensitive application '\(name)' is blocked by OpenComputerUse security guardrail.",
                recoveryHint: "Add '\(name)' to 'allowedApps' in ~/.opencomputeruse/config.json if you explicitly want to automate it."
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
                    message: "User denied OpenComputerUse access to application '\(name)' for this session.",
                    recoveryHint: "Run 'ocu allow-app \"\(name)\"' to grant access."
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
                        recoveryHint: "Approve the prompt or run 'ocu allow-app \"\(name)\"'."
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

            是否允许该 Agent 通过 OpenComputerUse 扫描并操作「\(appName)」？
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

    /// One-line MCP configuration installer for Claude Code, Codex, Gemini CLI, and Cursor.
    public func installMCPConfiguration(target: String = "all", binaryPath: String? = nil) throws -> ActionOutcome {
        let resolvedBin: String = {
            if let custom = binaryPath, !custom.isEmpty { return custom }
            let localBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/ocu").path
            if FileManager.default.fileExists(atPath: localBin) { return localBin }
            return CommandLine.arguments.first ?? "/Users/ronny/.local/bin/ocu"
        }()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let lowerTarget = target.lowercased()
        var updatedPaths: [String] = []

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
            mcpServers["open-computer-use"] = [
                "command": resolvedBin,
                "args": ["mcp"]
            ]
            root["mcpServers"] = mcpServers
            let outData = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: fileURL, options: .atomic)
            updatedPaths.append(fileURL.path)
        }

        if lowerTarget == "all" || lowerTarget == "claude" {
            try upsertJSONMCPServer(at: home.appendingPathComponent(".claude.json"))
        }
        if lowerTarget == "all" || lowerTarget == "gemini" {
            try upsertJSONMCPServer(at: home.appendingPathComponent(".gemini/settings.json"))
        }
        if lowerTarget == "all" || lowerTarget == "cursor" {
            try upsertJSONMCPServer(at: home.appendingPathComponent(".cursor/mcp.json"))
        }
        if lowerTarget == "all" || lowerTarget == "codex" {
            let codexURL = home.appendingPathComponent(".codex/config.toml")
            try FileManager.default.createDirectory(
                at: codexURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var toml = (try? String(contentsOf: codexURL, encoding: .utf8)) ?? ""
            let sectionHeader = "[mcp_servers.open_computer_use]"
            let block = """
            \(sectionHeader)
            command = "\(resolvedBin)"
            args = ["mcp"]
            """
            if !toml.contains(sectionHeader) {
                if !toml.isEmpty && !toml.hasSuffix("\n") { toml.append("\n") }
                toml.append("\n\(block)\n")
                try toml.write(to: codexURL, atomically: true, encoding: .utf8)
            }
            updatedPaths.append(codexURL.path)
        }

        return ActionOutcome(
            action: "install_mcp",
            targetDescription: "Installed open-computer-use MCP to \(updatedPaths.count) config(s)",
            details: updatedPaths.joined(separator: ", "),
            elapsedMs: 5
        )
    }
}
