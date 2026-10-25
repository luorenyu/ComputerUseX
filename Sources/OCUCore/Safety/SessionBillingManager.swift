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

    public func formatReceiptText() -> String {
        let appsStr = targetApps.isEmpty ? "系统桌面" : targetApps.joined(separator: ", ")
        let cnyEstimate = costUSD * 7.20
        let savedCny = savedCostUSD * 7.20
        var lines: [String] = []
        lines.append("╔══════════════════════════════════════════════════════════════════╗")
        lines.append("║                 🧾 OpenComputerUse 使用账单明细                  ║")
        lines.append("╠══════════════════════════════════════════════════════════════════╣")
        lines.append("║ 账单编号 (Bill ID)   : #\(billId) (\(endTime))")
        lines.append("║ 操作主体 (Agent)     : 🤖 \(agentName)")
        lines.append("║ 驱动模型 (Model)     : 🧠 \(modelName)")
        lines.append("║ 操控应用 (Apps)      : 🖥️ \(appsStr)")
        lines.append("║ 耗时统计 (Duration)  : ⏱️ \(String(format: "%.2fs", totalDurationSeconds)) (执行 \(actionCount) 步动作, 引擎耗时 \(activeExecutionMs)ms)")
        lines.append("║ Token 消耗明细       : 📊 共 \(totalTokens) Tokens")
        lines.append("║   ├─ 输入 (Prompt)   : \(inputTokens) Tokens")
        lines.append("║   ├─ 输出 (Snapshot) : \(outputTokens) Tokens (含视觉 Token: \(visionTokens))")
        lines.append("║   └─ 压缩节省 (Saved): 💎 省下 \(savedTokens) Tokens (Compact + AX Diff + 图像去重)")
        lines.append("║ 折算费用 (Cost USD)  : 💵 $\(String(format: "%.5f", costUSD)) USD (约 ¥\(String(format: "%.4f", cnyEstimate)) CNY)")
        if savedCostUSD > 0 {
            lines.append("║ 帮您节省 (Saved USD) : 🎉 $\(String(format: "%.5f", savedCostUSD)) USD (约 ¥\(String(format: "%.4f", savedCny)) CNY)")
        }
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

    // Active session state
    private var activeSessionId: String?
    private var sessionStartDate: Date?
    private var lastActivityDate: Date?
    private var currentOperator: AgentOperatorIdentity = AgentOperatorIdentity(
        agentName: "AI Agent",
        modelName: "Claude Sonnet 4 / Gemini 2.5 Pro"
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
    public var sessionIdleTimeoutSeconds: TimeInterval = 6.5

    public var billsFileURL: URL {
        AuditAndSecurityGuard.shared.baseDirectory.appendingPathComponent("bills.jsonl")
    }

    private init() {}

    // MARK: - Pricing Table

    public static func priceRate(for modelName: String) -> ModelPriceRate {
        let lower = modelName.lowercased()
        if lower.contains("opus") {
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

    public func registerMCPClient(name: String?, modelHint: String? = nil) {
        lock.lock()
        if let n = name, !n.isEmpty {
            mcpClientName = n
        }
        if let m = modelHint, !m.isEmpty {
            mcpModelHint = m
        }
        lock.unlock()
    }

    /// Inspects explicit flags, environment variables, MCP handshake, and macOS process ancestry (`getppid()` chain)
    /// to determine which AI Agent and LLM Model is currently operating OpenComputerUse.
    public func detectCurrentOperator(
        explicitAgent: String? = nil,
        explicitModel: String? = nil
    ) -> AgentOperatorIdentity {
        let env = ProcessInfo.processInfo.environment

        var resolvedAgent = explicitAgent?.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedModel = explicitModel?.trimmingCharacters(in: .whitespacesAndNewlines)

        if resolvedAgent == nil || resolvedAgent!.isEmpty {
            resolvedAgent = env["OCU_AGENT"] ?? env["MCP_CLIENT_NAME"] ?? mcpClientName
        }
        if resolvedModel == nil || resolvedModel!.isEmpty {
            resolvedModel = env["OCU_MODEL"] ?? env["ANTHROPIC_MODEL"] ?? env["OPENAI_MODEL"] ?? env["GEMINI_MODEL"] ?? mcpModelHint
        }

        // Walk parent process chain (up to 6 levels) if agent is not explicitly provided
        let ancestry = Self.collectProcessAncestry(maxDepth: 7)
        let joinedAncestry = ancestry.joined(separator: " | ").lowercased()

        if resolvedAgent == nil || resolvedAgent!.isEmpty {
            if joinedAncestry.contains("antigravity") || env["ANTIGRAVITY_AGENT"] != nil || env["__CFBundleIdentifier"]?.lowercased().contains("antigravity") == true {
                resolvedAgent = "Antigravity"
            } else if joinedAncestry.contains("claude") || env["CLAUDECODE"] != nil {
                resolvedAgent = "Claude Code"
            } else if joinedAncestry.contains("codex") || env["CODEX_SANDBOX"] != nil {
                resolvedAgent = "OpenAI Codex"
            } else if joinedAncestry.contains("cursor") {
                resolvedAgent = "Cursor Agent"
            } else if joinedAncestry.contains("windsurf") {
                resolvedAgent = "Windsurf Cascade"
            } else if joinedAncestry.contains("openclaw") || joinedAncestry.contains("clawd") {
                resolvedAgent = "OpenClaw"
            } else if joinedAncestry.contains("gemini") {
                resolvedAgent = "Gemini CLI"
            } else {
                // Check if Antigravity is running and owns our workspace
                if FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity").path) {
                    resolvedAgent = "Antigravity Agent"
                } else {
                    resolvedAgent = "Terminal CLI Agent"
                }
            }
        }

        let finalAgent = resolvedAgent ?? "Antigravity Agent"

        if resolvedModel == nil || resolvedModel!.isEmpty {
            resolvedModel = Self.inferModelForAgent(finalAgent, ancestryText: joinedAncestry)
        }

        let finalModel = resolvedModel ?? "Gemini 2.5 Pro"
        return AgentOperatorIdentity(
            agentName: finalAgent,
            modelName: finalModel,
            clientPid: getpid(),
            sourceDescription: "ancestry"
        )
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

        if lowerAgent.contains("claude") {
            return "claude-sonnet-4"
        }

        if lowerAgent.contains("antigravity") {
            return "Gemini 2.5 Pro / Claude Sonnet 4"
        }

        if lowerAgent.contains("cursor") {
            return "claude-sonnet-4"
        }

        if lowerAgent.contains("gemini") {
            return "gemini-2.5-pro"
        }

        return "claude-sonnet-4"
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
            results.append(comm)
            let ppid = info.kp_eproc.e_ppid
            if ppid == pid || ppid <= 1 { break }
            pid = ppid
        }
        return results
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

    /// Records a single command execution into the current active session bill and emits live operator HUD updates.
    public func recordCommandUsage(
        request: IPCRequest,
        response: IPCResponse,
        elapsedMs: Int
    ) {
        // Skip internal HUD event forwarding or pure status pings from starting a bill
        let ignoredCommands: Set<String> = ["hud_event", "status", "bill", "bills", "audit"]
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
            // Compact tabular format saves ~60% compared to verbose raw JSON element trees
            stepSavedTokens += Int(Double(stepOutputTokens) * 1.4)

            if snap.imageDeduplicated == true {
                // Perceptual hash deduplication saved ~1,150 vision tokens!
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
                // Post-action AX diff avoided a full follow-up screenshot + snapshot turn (~1,400 tokens saved!)
                stepSavedTokens += 950
            }
        }

        lock.lock()
        let now = Date()
        if activeSessionId == nil {
            activeSessionId = UUID().uuidString.prefix(8).lowercased()
            sessionStartDate = now
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
            _ = self.finalizeCurrentSessionIfActive()
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
            let end = lastActivityDate ?? Date()
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
            let bill = UsageSessionBill(
                billId: sid,
                startTime: ISO8601DateFormatter().string(from: start),
                endTime: ISO8601DateFormatter().string(from: end),
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

    /// Finalizes the active session into a persisted `UsageSessionBill`, writes it to `~/.opencomputeruse/bills.jsonl`,
    /// and notifies the HUD to display the visual Session Bill Receipt card.
    @discardableResult
    public func finalizeCurrentSessionIfActive(
        explicitInputTokens: Int? = nil,
        explicitOutputTokens: Int? = nil
    ) -> UsageSessionBill? {
        lock.lock()
        idleFinalizeWorkItem?.cancel()
        idleFinalizeWorkItem = nil

        guard let sid = activeSessionId, let start = sessionStartDate, !activeSteps.isEmpty else {
            lock.unlock()
            return nil
        }

        let end = Date()
        let wallSec = end.timeIntervalSince(start)
        let activeSec = Double(cumulativeExecutionMs) / 1000.0
        // If finalized via idle timer, subtract the idle wait window so duration reflects true usage time
        let adjustedWallSec = wallSec > sessionIdleTimeoutSeconds ? max(activeSec, wallSec - sessionIdleTimeoutSeconds + 0.3) : max(activeSec, wallSec)

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
            endTime: formatter.string(from: end),
            agentName: currentOperator.agentName,
            modelName: currentOperator.modelName,
            targetApps: activeTargetApps,
            actionCount: activeSteps.count,
            totalDurationSeconds: adjustedWallSec,
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
