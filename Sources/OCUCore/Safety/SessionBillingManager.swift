import Foundation
import Darwin

/// Represents the identified AI Agent and LLM Model currently operating OpenComputerUse.
public struct AgentOperatorIdentity: Codable, Equatable, Sendable {
    public var agentName: String
    public var modelName: String
    public var clientPid: Int32
    public var sourceDescription: String

    public init(
        agentName: String,
        modelName: String,
        clientPid: Int32 = getpid(),
        sourceDescription: String = "auto"
    ) {
        self.agentName = agentName
        self.modelName = modelName
        self.clientPid = clientPid
        self.sourceDescription = sourceDescription
    }
}

/// Per-1M token pricing entry in USD.
public struct ModelPriceRate: Codable, Equatable, Sendable {
    public var modelFamily: String
    public var inputPerMillionUSD: Double
    public var outputPerMillionUSD: Double

    public init(modelFamily: String, inputPerMillionUSD: Double, outputPerMillionUSD: Double) {
        self.modelFamily = modelFamily
        self.inputPerMillionUSD = inputPerMillionUSD
        self.outputPerMillionUSD = outputPerMillionUSD
    }
}

/// Individual step recorded inside a ComputerUse session bill.
public struct UsageStepRecord: Codable, Equatable, Sendable {
    public var timestamp: String
    public var command: String
    public var targetApp: String?
    public var targetDescription: String
    public var elapsedMs: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var visionTokens: Int
    public var savedTokens: Int

    public init(
        timestamp: String = ISO8601DateFormatter().string(from: Date()),
        command: String,
        targetApp: String? = nil,
        targetDescription: String,
        elapsedMs: Int,
        inputTokens: Int,
        outputTokens: Int,
        visionTokens: Int,
        savedTokens: Int = 0
    ) {
        self.timestamp = timestamp
        self.command = command
        self.targetApp = targetApp
        self.targetDescription = targetDescription
        self.elapsedMs = elapsedMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.visionTokens = visionTokens
        self.savedTokens = savedTokens
    }
}

/// Complete receipt / bill for a ComputerUse session ("一次完整使用 ComputerUse 的账单").
public struct UsageSessionBill: Codable, Equatable, Sendable, Identifiable {
    public var id: String { billId }
    public var billId: String
    public var startTime: String
    public var endTime: String
    public var agentName: String
    public var modelName: String
    public var targetApps: [String]
    public var actionCount: Int
    public var totalDurationSeconds: Double
    public var activeExecutionMs: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var visionTokens: Int
    public var totalTokens: Int
    public var savedTokens: Int
    public var costUSD: Double
    public var savedCostUSD: Double
    public var steps: [UsageStepRecord]

    public init(
        billId: String = UUID().uuidString.prefix(8).lowercased(),
        startTime: String,
        endTime: String,
        agentName: String,
        modelName: String,
        targetApps: [String],
        actionCount: Int,
        totalDurationSeconds: Double,
        activeExecutionMs: Int,
        inputTokens: Int,
        outputTokens: Int,
        visionTokens: Int,
        totalTokens: Int,
        savedTokens: Int,
        costUSD: Double,
        savedCostUSD: Double,
        steps: [UsageStepRecord]
    ) {
        self.billId = billId
        self.startTime = startTime
        self.endTime = endTime
        self.agentName = agentName
        self.modelName = modelName
        self.targetApps = targetApps
        self.actionCount = actionCount
        self.totalDurationSeconds = totalDurationSeconds
        self.activeExecutionMs = activeExecutionMs
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.visionTokens = visionTokens
        self.totalTokens = totalTokens
        self.savedTokens = savedTokens
        self.costUSD = costUSD
        self.savedCostUSD = savedCostUSD
        self.steps = steps
    }

    public var toolExecutionSeconds: Double {
        Double(activeExecutionMs) / 1000.0
    }

    public var formattedDurationSummary: String {
        let totalSec = max(totalDurationSeconds, toolExecutionSeconds)
        return String(
            format: "总耗时 %.2fs + ComputerUse工具调用耗时 %.2fs (%dms, 共 %d 步)",
            totalSec,
            toolExecutionSeconds,
            activeExecutionMs,
            actionCount
        )
    }

    public var formattedDurationCompact: String {
        let totalSec = max(totalDurationSeconds, toolExecutionSeconds)
        return String(
            format: "总耗时 %.1fs + 工具耗时 %.1fs (%d步)",
            totalSec,
            toolExecutionSeconds,
            actionCount
        )
    }

    public func formatReceiptText() -> String {
        let appsStr = targetApps.isEmpty ? "系统桌面" : targetApps.joined(separator: ", ")
        let cnyEstimate = costUSD * 7.20
        var lines: [String] = []
        lines.append("╔══════════════════════════════════════════════════════════════════╗")
        lines.append("║                   🧾 ComputerUseX 使用账单明细                    ║")
        lines.append("╠══════════════════════════════════════════════════════════════════╣")
        lines.append("║ 账单编号 (Bill ID)   : #\(billId) (\(endTime))")
        lines.append("║ 操作主体 (Agent)     : 🤖 \(agentName)")
        lines.append("║ 驱动模型 (Model)     : 🧠 \(modelName)")
        lines.append("║ 操控应用 (Apps)      : 🖥️ \(appsStr)")
        lines.append("║ 耗时统计 (Duration)  : ⏱️ \(formattedDurationSummary)")
        lines.append("║ Token 消耗明细       : 📊 共 \(totalTokens) Tokens")
        lines.append("║   ├─ 输入 (Prompt)   : \(inputTokens) Tokens")
        lines.append("║   └─ 输出 (Snapshot) : \(outputTokens) Tokens (含视觉 Token: \(visionTokens))")
        lines.append("║ 折算费用 (Cost USD)  : 💵 $\(String(format: "%.5f", costUSD)) USD (约 ¥\(String(format: "%.4f", cnyEstimate)) CNY)")
        lines.append("╚══════════════════════════════════════════════════════════════════╝")
        return lines.joined(separator: "\n")
    }
}

/// Automatically detects which AI Agent and LLM Model is invoking `ocu` and tracks real-time session usage bills.
public final class SessionBillingManager: @unchecked Sendable {
    public static let shared = SessionBillingManager()

    private let lock = NSLock()
    private var mcpClientName: String?
    private var mcpModelHint: String?
    private var lastExplicitAgent: String?
    private var lastExplicitModel: String?

    // Active session state
    private var activeSessionId: String?
    private var sessionStartDate: Date?
    private var lastActivityDate: Date?
    private var currentOperator: AgentOperatorIdentity = AgentOperatorIdentity(
        agentName: "Antigravity",
        modelName: "Gemini 4 Argon Medium"
    )
    private var activeTargetApps: [String] = []
    private var activeSteps: [UsageStepRecord] = []
    private var cumulativeInputTokens: Int = 0
    private var cumulativeOutputTokens: Int = 0
    private var cumulativeVisionTokens: Int = 0
    private var cumulativeSavedTokens: Int = 0
    private var cumulativeExecutionMs: Int = 0
    private var idleFinalizeWorkItem: DispatchWorkItem?

    /// Idle window (seconds) after which an active sequence of ComputerUse commands is finalized into a complete bill.
    /// Set to 300s (5 minutes) so multi-turn Agent workflows (where the LLM reasons, renders flowcharts, or runs tools
    /// for 30–180s between GUI steps) stay in one continuous task session bill instead of fragmenting.
    public var sessionIdleTimeoutSeconds: TimeInterval = 300.0

    public var billsFileURL: URL {
        AuditAndSecurityGuard.shared.baseDirectory.appendingPathComponent("bills.jsonl")
    }

    public var operatorStateFileURL: URL {
        AuditAndSecurityGuard.shared.baseDirectory.appendingPathComponent("operator_context.json")
    }

    private init() {
        loadPersistedOperatorContext()
    }

    private func loadPersistedOperatorContext() {
        guard let data = try? Data(contentsOf: operatorStateFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        if let a = dict["agentName"], !a.isEmpty {
            lastExplicitAgent = a
        }
        if let m = dict["modelName"], !m.isEmpty {
            lastExplicitModel = m
        }
        if let a = lastExplicitAgent, let m = lastExplicitModel {
            currentOperator = AgentOperatorIdentity(agentName: a, modelName: m)
        }
    }

    private func savePersistedOperatorContext(agent: String?, model: String?) {
        var dict: [String: String] = [:]
        if let data = try? Data(contentsOf: operatorStateFileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            dict = existing
        }
        if let a = agent, !a.isEmpty {
            dict["agentName"] = a
        }
        if let m = model, !m.isEmpty {
            dict["modelName"] = m
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: operatorStateFileURL, options: .atomic)
        }
    }

    // MARK: - Pricing Table

    public static func priceRate(for modelName: String) -> ModelPriceRate {
        let lower = modelName.lowercased()
        if lower.contains("argon") || lower.contains("gemini 4") || lower.contains("gemini-4") {
            return ModelPriceRate(modelFamily: "Gemini 4 Argon Medium", inputPerMillionUSD: 1.50, outputPerMillionUSD: 10.0)
        } else if lower.contains("opus") {
            return ModelPriceRate(modelFamily: "Claude Opus 4", inputPerMillionUSD: 15.0, outputPerMillionUSD: 75.0)
        } else if lower.contains("haiku") {
            return ModelPriceRate(modelFamily: "Claude 3.5 Haiku", inputPerMillionUSD: 0.80, outputPerMillionUSD: 4.0)
        } else if lower.contains("sonnet") || lower.contains("claude") {
            return ModelPriceRate(modelFamily: "Claude Sonnet 4", inputPerMillionUSD: 3.0, outputPerMillionUSD: 15.0)
        } else if lower.contains("flash") {
            return ModelPriceRate(modelFamily: "Gemini 2.5 Flash", inputPerMillionUSD: 0.15, outputPerMillionUSD: 0.60)
        } else if lower.contains("gemini") {
            return ModelPriceRate(modelFamily: "Gemini 2.5 Pro", inputPerMillionUSD: 1.25, outputPerMillionUSD: 10.0)
        } else if lower.contains("o3") || lower.contains("codex") || lower.contains("gpt-5") {
            return ModelPriceRate(modelFamily: "GPT-5 Codex / o3", inputPerMillionUSD: 2.0, outputPerMillionUSD: 8.0)
        } else if lower.contains("gpt-4o-mini") || lower.contains("gpt-4.1-mini") {
            return ModelPriceRate(modelFamily: "GPT-4.1 Mini", inputPerMillionUSD: 0.40, outputPerMillionUSD: 1.60)
        } else if lower.contains("gpt") {
            return ModelPriceRate(modelFamily: "GPT-4.1", inputPerMillionUSD: 2.0, outputPerMillionUSD: 8.0)
        }
        // Default blended frontier agent model rate ($2.50 / $10.00 per 1M)
        return ModelPriceRate(modelFamily: modelName, inputPerMillionUSD: 2.50, outputPerMillionUSD: 10.0)
    }

    public static func computeCostUSD(inputTokens: Int, outputTokens: Int, modelName: String) -> Double {
        let rate = priceRate(for: modelName)
        let inCost = (Double(inputTokens) / 1_000_000.0) * rate.inputPerMillionUSD
        let outCost = (Double(outputTokens) / 1_000_000.0) * rate.outputPerMillionUSD
        return inCost + outCost
    }

    // MARK: - Automatic Caller Agent & Model Detection

    public static func normalizeAgentDisplayName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("antigravity") {
            return "Antigravity"
        } else if lower.contains("openclaw") || lower.contains("clawd") {
            return "OpenClaw"
        } else if lower.contains("claude") {
            return "Claude Code"
        } else if lower.contains("codex") {
            return "OpenAI Codex"
        } else if lower.contains("opencode") {
            return "OpenCode"
        } else if lower.contains("minimax") || lower.contains("mmx") || lower.contains("mcode") {
            return "MiniMaxCode"
        } else if lower.contains("harness") || lower.contains("hermes") {
            return "Harness"
        } else if lower == "pi" || lower.contains("pi-coding") || lower.contains("pi_agent") {
            return "Pi"
        } else if lower.contains("cursor") {
            return "Cursor Agent"
        } else if lower.contains("windsurf") {
            return "Windsurf Cascade"
        } else if lower.contains("gemini") {
            return "Gemini CLI"
        }
        return trimmed
    }

    public func registerMCPClient(name: String?, modelHint: String? = nil) {
        let normalizedName = name.map { Self.normalizeAgentDisplayName($0) }
        let inferredOrExplicitModel: String?
        if let m = modelHint, !m.isEmpty {
            inferredOrExplicitModel = m
        } else if let n = normalizedName, !n.isEmpty {
            inferredOrExplicitModel = Self.inferModelForAgent(n, ancestryText: n.lowercased())
        } else {
            inferredOrExplicitModel = nil
        }

        lock.lock()
        if let n = normalizedName, !n.isEmpty {
            mcpClientName = n
            lastExplicitAgent = n
        }
        if let m = inferredOrExplicitModel, !m.isEmpty {
            mcpModelHint = m
            lastExplicitModel = m
        }
        lock.unlock()
        if (normalizedName != nil && !normalizedName!.isEmpty) || (inferredOrExplicitModel != nil && !inferredOrExplicitModel!.isEmpty) {
            savePersistedOperatorContext(agent: normalizedName, model: inferredOrExplicitModel)
        }
    }

    /// Inspects explicit flags, environment variables, MCP handshake, live macOS process ancestry (`getppid()` chain with
    /// full executable path + command-line arguments), and persisted operator context to determine which AI Agent and
    /// LLM Model is currently operating ComputerUseX in real time.
    public func detectCurrentOperator(
        explicitAgent: String? = nil,
        explicitModel: String? = nil
    ) -> AgentOperatorIdentity {
        let env = ProcessInfo.processInfo.environment

        let cleanExplicitAgent = explicitAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanExplicitModel = explicitModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExplicitAgent = (cleanExplicitAgent != nil && !cleanExplicitAgent!.isEmpty)
            ? Self.normalizeAgentDisplayName(cleanExplicitAgent!)
            : nil

        lock.lock()
        let prevStickyAgent = lastExplicitAgent
        let prevStickyModel = lastExplicitModel
        lock.unlock()

        // Walk parent process chain (up to 9 levels) to detect the live calling Agent process
        let ancestry = Self.collectProcessAncestry(maxDepth: 9)
        let joinedAncestry = ancestry.joined(separator: " | ").lowercased()
        let liveAncestryAgent = Self.detectAgentFromAncestryAndEnv(joinedAncestry: joinedAncestry, env: env)

        var resolvedAgent: String? = normalizedExplicitAgent
        if resolvedAgent == nil || resolvedAgent!.isEmpty {
            if let envAgent = env["CUX_AGENT"] ?? env["OCU_AGENT"] ?? env["MCP_CLIENT_NAME"], !envAgent.isEmpty {
                resolvedAgent = Self.normalizeAgentDisplayName(envAgent)
            } else if let mcpAgent = mcpClientName, !mcpAgent.isEmpty {
                resolvedAgent = Self.normalizeAgentDisplayName(mcpAgent)
            } else if let liveAgent = liveAncestryAgent, !liveAgent.isEmpty {
                // Live process ancestry ALWAYS takes priority over stale stickyAgent from a previous session!
                resolvedAgent = liveAgent
            } else if let sticky = prevStickyAgent, !sticky.isEmpty {
                resolvedAgent = Self.normalizeAgentDisplayName(sticky)
            } else if FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity").path) {
                resolvedAgent = "Antigravity"
            } else {
                resolvedAgent = "Terminal CLI Agent"
            }
        }

        let finalAgent = resolvedAgent ?? "Antigravity"
        let agentChangedFromSticky = (prevStickyAgent != nil) && (Self.normalizeAgentDisplayName(prevStickyAgent!) != finalAgent)

        var resolvedModel: String? = cleanExplicitModel
        if resolvedModel == nil || resolvedModel!.isEmpty {
            if let envModel = env["CUX_MODEL"] ?? env["OCU_MODEL"] ?? env["ANTHROPIC_MODEL"] ?? env["OPENAI_MODEL"] ?? env["GEMINI_MODEL"] ?? env["MINIMAX_MODEL"], !envModel.isEmpty {
                resolvedModel = envModel
            } else if let mcpMod = mcpModelHint, !mcpMod.isEmpty, mcpClientName == finalAgent {
                resolvedModel = mcpMod
            } else if !agentChangedFromSticky,
                      let stickyMod = prevStickyModel,
                      !stickyMod.isEmpty,
                      Self.isModelCompatibleWithAgent(model: stickyMod, agent: finalAgent) {
                resolvedModel = stickyMod
            } else {
                resolvedModel = Self.inferModelForAgent(finalAgent, ancestryText: joinedAncestry)
            }
        }

        let finalModel = (resolvedModel != nil && !resolvedModel!.isEmpty)
            ? resolvedModel!
            : Self.inferModelForAgent(finalAgent, ancestryText: joinedAncestry)

        lock.lock()
        let shouldPersist = (lastExplicitAgent != finalAgent) || (lastExplicitModel != finalModel)
        lastExplicitAgent = finalAgent
        lastExplicitModel = finalModel
        lock.unlock()

        if shouldPersist {
            savePersistedOperatorContext(agent: finalAgent, model: finalModel)
        }

        return AgentOperatorIdentity(
            agentName: finalAgent,
            modelName: finalModel,
            clientPid: getpid(),
            sourceDescription: (cleanExplicitModel != nil) ? "agent-reported" : "ancestry"
        )
    }

    private static func detectAgentFromAncestryAndEnv(joinedAncestry: String, env: [String: String]) -> String? {
        if joinedAncestry.contains("antigravity") || env["ANTIGRAVITY_AGENT"] != nil || env["__CFBundleIdentifier"]?.lowercased().contains("antigravity") == true {
            return "Antigravity"
        } else if joinedAncestry.contains("openclaw") || joinedAncestry.contains("clawd") || env["OPENCLAW_HOME"] != nil {
            return "OpenClaw"
        } else if joinedAncestry.contains("claude") || env["CLAUDECODE"] != nil {
            return "Claude Code"
        } else if joinedAncestry.contains("codex") || env["CODEX_SANDBOX"] != nil {
            return "OpenAI Codex"
        } else if joinedAncestry.contains("opencode") || env["OPENCODE"] != nil {
            return "OpenCode"
        } else if joinedAncestry.contains("minimax") || joinedAncestry.contains("mmx") || joinedAncestry.contains("mcode") || env["MINIMAX_API_KEY"] != nil {
            return "MiniMaxCode"
        } else if joinedAncestry.contains("harness") || joinedAncestry.contains("hermes") || env["HARNESS_AGENT"] != nil {
            return "Harness"
        } else if joinedAncestry.contains("pi-coding") || joinedAncestry.contains("/pi ") || env["PI_AGENT_DIR"] != nil {
            return "Pi"
        } else if joinedAncestry.contains("cursor.app") || joinedAncestry.contains("cursor-") {
            return "Cursor Agent"
        } else if joinedAncestry.contains("windsurf") {
            return "Windsurf Cascade"
        } else if joinedAncestry.contains("gemini-cli") || joinedAncestry.contains("@google/gemini-cli") {
            return "Gemini CLI"
        }
        return nil
    }

    private static func isModelCompatibleWithAgent(model: String, agent: String) -> Bool {
        let lowerAgent = agent.lowercased()
        let lowerModel = model.lowercased()
        if lowerAgent.contains("antigravity") {
            return lowerModel.contains("gemini") || lowerModel.contains("argon") || lowerModel.contains("claude")
        }
        if lowerAgent.contains("openclaw") {
            // Never let Antigravity's internal "Gemini 4 Argon" default leak into OpenClaw unless configured in openclaw.json
            if lowerModel.contains("argon") { return false }
            return true
        }
        return true
    }

    private static func inferModelForAgent(_ agent: String, ancestryText: String) -> String {
        let lowerAgent = agent.lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser

        if lowerAgent.contains("codex") {
            if let toml = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8) {
                for line in toml.split(separator: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("model") && trimmed.contains("=") {
                        let val = trimmed.split(separator: "=").last?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .replacingOccurrences(of: "\"", with: "")
                            .replacingOccurrences(of: "'", with: "")
                        if let v = val, !v.isEmpty { return v }
                    }
                }
            }
            return "gpt-5-codex"
        }

        if lowerAgent.contains("openclaw") {
            let clawConfigURL = home.appendingPathComponent(".openclaw/openclaw.json")
            if let data = try? Data(contentsOf: clawConfigURL),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let agents = root["agents"] as? [String: Any],
               let defaults = agents["defaults"] as? [String: Any],
               let modelDict = defaults["model"] as? [String: Any],
               let primary = modelDict["primary"] as? String,
               !primary.isEmpty {
                return primary
            }
            return "claude-sonnet-4"
        }

        if lowerAgent.contains("claude") {
            let claudeSettingsURL = home.appendingPathComponent(".claude/settings.json")
            if let data = try? Data(contentsOf: claudeSettingsURL),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let model = root["model"] as? String,
               !model.isEmpty {
                return model
            }
            return "claude-sonnet-4"
        }

        if lowerAgent.contains("minimax") || lowerAgent.contains("mmx") {
            return "MiniMax-M2.5"
        }

        if lowerAgent.contains("opencode") {
            return "claude-sonnet-4"
        }

        if lowerAgent.contains("pi") {
            return "claude-sonnet-4"
        }

        if lowerAgent.contains("harness") || lowerAgent.contains("hermes") {
            return "claude-sonnet-4"
        }

        if lowerAgent.contains("antigravity") {
            return "Gemini 4 Argon Medium"
        }

        if lowerAgent.contains("cursor") {
            return "claude-sonnet-4"
        }

        if lowerAgent.contains("gemini") {
            return "Gemini 2.5 Pro"
        }

        return "Gemini 4 Argon Medium"
    }

    private static func collectProcessAncestry(maxDepth: Int) -> [String] {
        var results: [String] = []
        var pid = getpid()
        for _ in 0..<maxDepth {
            guard pid > 1 else { break }
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            let rc = sysctl(&mib, 4, &info, &size, nil, 0)
            guard rc == 0 else { break }

            let comm = withUnsafePointer(to: &info.kp_proc.p_comm) { ptr -> String in
                let raw = UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                return String(cString: raw)
            }

            // Also resolve full executable path and command-line arguments via KERN_PROCARGS2
            // so Node/Electron/Python wrappers reveal their real parent Agent (e.g. Antigravity.app, openclaw, claude, codex)
            let procArgs = readProcessArguments(pid: pid)
            if !procArgs.isEmpty {
                results.append("\(comm) (\(procArgs))")
            } else {
                results.append(comm)
            }

            let ppid = info.kp_eproc.e_ppid
            if ppid == pid || ppid <= 1 { break }
            pid = ppid
        }
        return results
    }

    private static func readProcessArguments(pid: pid_t) -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 65536 else {
            return ""
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else {
            return ""
        }
        var argc: Int32 = 0
        memcpy(&argc, &buffer, MemoryLayout<Int32>.size)
        let maxArgs = min(Int(max(1, argc)), 8)
        var pos = MemoryLayout<Int32>.size

        var tokens: [String] = []
        // First string is the executable path
        while pos < size && buffer[pos] == 0 { pos += 1 }
        let start = pos
        while pos < size && buffer[pos] != 0 { pos += 1 }
        if pos > start, let execPath = String(bytes: buffer[start..<pos], encoding: .utf8) {
            tokens.append(execPath)
        }
        // Skip null padding after execPath
        while pos < size && buffer[pos] == 0 { pos += 1 }

        // Read up to `maxArgs` argv strings
        for _ in 0..<maxArgs {
            guard pos < size else { break }
            let argStart = pos
            while pos < size && buffer[pos] != 0 { pos += 1 }
            if pos > argStart, let argStr = String(bytes: buffer[argStart..<pos], encoding: .utf8), !argStr.isEmpty {
                if argStr.count <= 220 {
                    tokens.append(argStr)
                }
            }
            pos += 1
        }
        return tokens.joined(separator: " ")
    }

    // MARK: - Real-Time Command Metering & Billing

    public static func estimateTokens(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var asciiCount = 0
        var nonAsciiCount = 0
        for scalar in text.unicodeScalars {
            if scalar.value < 128 {
                asciiCount += 1
            } else {
                nonAsciiCount += 1
            }
        }
        // ~4 ASCII chars per token, ~1.4 CJK/Unicode chars per token
        let estimated = Int((Double(asciiCount) / 3.8).rounded(.up)) + Int((Double(nonAsciiCount) / 1.4).rounded(.up))
        return max(1, estimated)
    }

    /// Immediately updates the active operator identity and broadcasts `.operatorStatus` to the HUD / Mini PiP / MenuBar
    /// BEFORE a command starts executing (so cursor animations and status pills show the real caller right away).
    public func notifyCommandStarting(request: IPCRequest) {
        let ignoredCommands: Set<String> = ["hud_event", "status", "bill", "bills", "audit", "dashboard", "open", "session_finish"]
        if ignoredCommands.contains(request.command) {
            return
        }

        let identity = detectCurrentOperator(
            explicitAgent: request.agentName,
            explicitModel: request.modelName
        )

        lock.lock()
        // If a different Agent takes over while an older Agent's session was still open, finalize the previous Agent's bill cleanly
        if activeSessionId != nil && !activeSteps.isEmpty && currentOperator.agentName != identity.agentName {
            lock.unlock()
            _ = finalizeCurrentSessionIfActive(isIdleTimeout: true)
            lock.lock()
        }
        currentOperator = identity
        let actionCount = activeSteps.count
        let totalTokens = cumulativeInputTokens + cumulativeOutputTokens
        let runningCost = Self.computeCostUSD(
            inputTokens: cumulativeInputTokens,
            outputTokens: cumulativeOutputTokens,
            modelName: identity.modelName
        )
        lock.unlock()

        let targetDesc = request.target ?? request.app ?? request.command
        KillSwitchMonitor.shared.emitHUDEvent(
            .operatorStatus(
                agentName: identity.agentName,
                modelName: identity.modelName,
                currentAction: "\(request.command) → \(targetDesc)",
                actionCount: actionCount,
                totalTokens: totalTokens,
                costUSD: runningCost
            )
        )
    }

    /// Records a single command execution into the current active session bill and emits live operator HUD updates.
    public func recordCommandUsage(
        request: IPCRequest,
        response: IPCResponse,
        elapsedMs: Int
    ) {
        // Skip internal HUD event forwarding, pure status pings, or outer batch containers (inner steps are recorded individually)
        let ignoredCommands: Set<String> = ["hud_event", "status", "bill", "bills", "audit", "batch", "dashboard", "open", "session_finish"]
        if ignoredCommands.contains(request.command) {
            return
        }

        let identity = detectCurrentOperator(
            explicitAgent: request.agentName,
            explicitModel: request.modelName
        )

        // Estimate input tokens (tool call arguments + ~160 tokens of LLM tool-use framing per step)
        let reqData = (try? JSONEncoder().encode(request)) ?? Data()
        let reqStr = String(data: reqData, encoding: .utf8) ?? ""
        let stepInputTokens = 160 + Self.estimateTokens(for: reqStr)

        // Estimate output tokens & saved tokens
        var stepOutputTokens = 45
        var stepVisionTokens = 0
        var stepSavedTokens = 0
        var targetApp: String? = request.app
        var targetDesc: String = request.target ?? request.command

        if let snap = response.snapshot {
            targetApp = snap.activeApp
            targetDesc = "\(snap.activeApp) (\(snap.elements.count) elements)"
            let compactStr = snap.formatCompact()
            stepOutputTokens = Self.estimateTokens(for: compactStr)
            stepSavedTokens += Int(Double(stepOutputTokens) * 1.4)

            if snap.imageDeduplicated == true {
                stepSavedTokens += 1150
            } else if snap.imageBase64 != nil || snap.annotatedScreenshotPath != nil || snap.screenshotPath != nil {
                stepVisionTokens = 1100
                stepOutputTokens += stepVisionTokens
            }
        } else if let out = response.outcome {
            targetDesc = out.targetDescription
            let outText = [out.action, out.targetDescription, out.details].compactMap { $0 }.joined(separator: " ")
            stepOutputTokens = max(28, Self.estimateTokens(for: outText))
            if out.details?.contains("focus:") == true || out.details?.contains("changed:") == true || out.details?.contains("added(") == true {
                stepSavedTokens += 950
            }
        }

        lock.lock()
        let now = Date()
        if activeSessionId == nil {
            activeSessionId = UUID().uuidString.prefix(8).lowercased()
            // Start time is the moment the very first command began executing
            sessionStartDate = now.addingTimeInterval(-Double(max(1, elapsedMs)) / 1000.0)
            activeTargetApps = []
            activeSteps = []
            cumulativeInputTokens = 0
            cumulativeOutputTokens = 0
            cumulativeVisionTokens = 0
            cumulativeSavedTokens = 0
            cumulativeExecutionMs = 0
        }
        lastActivityDate = now
        currentOperator = identity

        if let app = targetApp, !app.isEmpty, !activeTargetApps.contains(app) {
            activeTargetApps.append(app)
        } else if let snapApp = ElementSnapshotStore.shared.currentSnapshot()?.activeApp,
                  !snapApp.isEmpty,
                  !activeTargetApps.contains(snapApp) {
            activeTargetApps.append(snapApp)
        }

        let stepRecord = UsageStepRecord(
            command: request.command,
            targetApp: targetApp ?? activeTargetApps.last,
            targetDescription: targetDesc,
            elapsedMs: elapsedMs,
            inputTokens: stepInputTokens,
            outputTokens: stepOutputTokens,
            visionTokens: stepVisionTokens,
            savedTokens: stepSavedTokens
        )
        activeSteps.append(stepRecord)
        cumulativeInputTokens += stepInputTokens
        cumulativeOutputTokens += stepOutputTokens
        cumulativeVisionTokens += stepVisionTokens
        cumulativeSavedTokens += stepSavedTokens
        cumulativeExecutionMs += max(1, elapsedMs)

        let totalTokens = cumulativeInputTokens + cumulativeOutputTokens
        let runningCost = Self.computeCostUSD(
            inputTokens: cumulativeInputTokens,
            outputTokens: cumulativeOutputTokens,
            modelName: identity.modelName
        )
        let actionCount = activeSteps.count
        lock.unlock()

        // Emit real-time operator identity & running usage telemetry to HUD / Mini PiP / MenuBar!
        KillSwitchMonitor.shared.emitHUDEvent(
            .operatorStatus(
                agentName: identity.agentName,
                modelName: identity.modelName,
                currentAction: "\(request.command) → \(targetDesc)",
                actionCount: actionCount,
                totalTokens: totalTokens,
                costUSD: runningCost
            )
        )

        scheduleIdleSessionFinalize()
    }

    private func scheduleIdleSessionFinalize() {
        lock.lock()
        idleFinalizeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            _ = self.finalizeCurrentSessionIfActive(isIdleTimeout: true)
        }
        idleFinalizeWorkItem = item
        let timeout = sessionIdleTimeoutSeconds
        lock.unlock()

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
    }

    /// Returns a live snapshot of the currently active session bill (or the most recent completed bill if idle).
    public func currentOrLatestBill() -> UsageSessionBill? {
        lock.lock()
        if let sid = activeSessionId, let start = sessionStartDate {
            let end = Date()
            let duration = max(Double(cumulativeExecutionMs) / 1000.0, end.timeIntervalSince(start))
            let totalTok = cumulativeInputTokens + cumulativeOutputTokens
            let cost = Self.computeCostUSD(
                inputTokens: cumulativeInputTokens,
                outputTokens: cumulativeOutputTokens,
                modelName: currentOperator.modelName
            )
            let savedCost = Self.computeCostUSD(
                inputTokens: cumulativeSavedTokens / 2,
                outputTokens: cumulativeSavedTokens / 2,
                modelName: currentOperator.modelName
            )
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let bill = UsageSessionBill(
                billId: sid,
                startTime: formatter.string(from: start),
                endTime: formatter.string(from: end),
                agentName: currentOperator.agentName,
                modelName: currentOperator.modelName,
                targetApps: activeTargetApps,
                actionCount: activeSteps.count,
                totalDurationSeconds: duration,
                activeExecutionMs: cumulativeExecutionMs,
                inputTokens: cumulativeInputTokens,
                outputTokens: cumulativeOutputTokens,
                visionTokens: cumulativeVisionTokens,
                totalTokens: totalTok,
                savedTokens: cumulativeSavedTokens,
                costUSD: cost,
                savedCostUSD: savedCost,
                steps: activeSteps
            )
            lock.unlock()
            return bill
        }
        lock.unlock()
        return recentBills(limit: 1).last
    }

    /// Finalizes the active session into a persisted `UsageSessionBill` and writes it to `~/.opencomputeruse/bills.jsonl`.
    @discardableResult
    public func finalizeCurrentSessionIfActive(
        explicitInputTokens: Int? = nil,
        explicitOutputTokens: Int? = nil,
        isIdleTimeout: Bool = false
    ) -> UsageSessionBill? {
        lock.lock()
        idleFinalizeWorkItem?.cancel()
        idleFinalizeWorkItem = nil

        guard let sid = activeSessionId, let start = sessionStartDate, !activeSteps.isEmpty else {
            lock.unlock()
            return nil
        }

        // If finalized explicitly via `ocu bill --finish`, measure up to `Date()` (including final Agent verification).
        // If finalized via idle timeout, measure up to `lastActivityDate` (start of step 1 -> completion of step N, including all LLM thinking intervals between steps).
        let effectiveEnd = isIdleTimeout ? (lastActivityDate ?? Date()) : Date()
        let activeSec = Double(cumulativeExecutionMs) / 1000.0
        let totalWallSec = max(activeSec, effectiveEnd.timeIntervalSince(start))

        let inTok = explicitInputTokens ?? cumulativeInputTokens
        let outTok = explicitOutputTokens ?? cumulativeOutputTokens
        let totTok = inTok + outTok
        let cost = Self.computeCostUSD(
            inputTokens: inTok,
            outputTokens: outTok,
            modelName: currentOperator.modelName
        )
        let savedCost = Self.computeCostUSD(
            inputTokens: cumulativeSavedTokens / 2,
            outputTokens: cumulativeSavedTokens / 2,
            modelName: currentOperator.modelName
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let completedBill = UsageSessionBill(
            billId: sid,
            startTime: formatter.string(from: start),
            endTime: formatter.string(from: effectiveEnd),
            agentName: currentOperator.agentName,
            modelName: currentOperator.modelName,
            targetApps: activeTargetApps,
            actionCount: activeSteps.count,
            totalDurationSeconds: totalWallSec,
            activeExecutionMs: cumulativeExecutionMs,
            inputTokens: inTok,
            outputTokens: outTok,
            visionTokens: cumulativeVisionTokens,
            totalTokens: totTok,
            savedTokens: cumulativeSavedTokens,
            costUSD: cost,
            savedCostUSD: savedCost,
            steps: activeSteps
        )

        // Reset active state
        activeSessionId = nil
        sessionStartDate = nil
        lastActivityDate = nil
        activeTargetApps = []
        activeSteps = []
        cumulativeInputTokens = 0
        cumulativeOutputTokens = 0
        cumulativeVisionTokens = 0
        cumulativeSavedTokens = 0
        cumulativeExecutionMs = 0
        lock.unlock()

        persistBill(completedBill)
        KillSwitchMonitor.shared.emitHUDEvent(.sessionBillCompleted(completedBill))
        return completedBill
    }

    private func persistBill(_ bill: UsageSessionBill) {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(bill),
              var line = String(data: data, encoding: .utf8) else {
            return
        }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: billsFileURL.path) {
            if let handle = try? FileHandle(forWritingTo: billsFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: lineData)
            }
        } else {
            try? lineData.write(to: billsFileURL, options: .atomic)
        }
    }

    public func recentBills(limit: Int = 10) -> [UsageSessionBill] {
        lock.lock()
        defer { lock.unlock() }
        guard let content = try? String(contentsOf: billsFileURL, encoding: .utf8) else {
            return []
        }
        let lines = content.split(separator: "\n").suffix(max(1, limit))
        let decoder = JSONDecoder()
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(UsageSessionBill.self, from: data)
        }
    }
}
