import Foundation

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
        allowedApps: [String] = [],
        blockedApps: [String] = Self.defaultBlockedApps,
        auditLoggingEnabled: Bool = true,
        autoPostActionDiff: Bool = true
    ) {
        self.allowedApps = allowedApps
        self.blockedApps = blockedApps
        self.auditLoggingEnabled = auditLoggingEnabled
        self.autoPostActionDiff = autoPostActionDiff
    }
}

public final class AuditAndSecurityGuard: @unchecked Sendable {
    public static let shared = AuditAndSecurityGuard()

    private let lock = NSLock()
    private var cachedConfig: OCUSecurityConfig?

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
