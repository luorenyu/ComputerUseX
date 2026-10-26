# Security Policy & Safety Architecture (`ComputerUseX`)

Because `ComputerUseX` (`cux`) grants AI Agents the ability to inspect UI trees and dispatch mouse/keyboard actions on macOS, security and human-in-the-loop control are treated as first-class architectural invariants.

---

## 🛡️ 5-Layer Defense-in-Depth Guardrails

### 1. Hardware-Level Global Kill Switch (`Option + Escape`)
- At any moment during Agent execution, pressing **`Option + Escape`** (or clicking **"紧急停止"** in the Menu Bar popover) immediately trips the global `KillSwitchMonitor` circuit breaker.
- All queued or in-flight pointer movements, clicks, and keystrokes are aborted instantaneously with `ERR_KILL_SWITCH_TRIPPED`.

### 2. Human Mouse Takeover Detection
- When operating in physical pointer mode, `KillSwitchMonitor` continuously compares the actual hardware cursor position against the Agent's expected trajectory.
- If the user physically moves the mouse by more than the safety threshold, `cux` yields control immediately with `ERR_HUMAN_TAKEOVER`.

### 3. Application Allowlist, Sensitive App Blocklist & Interactive Consent
- **Sensitive App Blocklist**: Password managers and system credential stores (`1Password`, `Keychain Access`, `Bitwarden`, `Terminal` when restricted, etc.) are blocked by default in `~/.computerusex/config.json`.
- **Interactive App Consent**: When "Allow Any App" (`任意应用`) is disabled in the **ComputerUseX Control Center (`cux dashboard`)**, the first time an AI Agent attempts to interact with an unapproved application, `ComputerUseX` pauses execution and presents a native macOS authorization dialog (`允许一次` / `始终允许` / `拒绝`).

### 4. Sensitive Action Pattern Interception
- High-risk UI labels and destructive patterns (e.g., payment confirmation, password fields, permanent deletion, system shutdown) are inspected by `AuditAndSecurityGuard` before dispatching click or keyboard events.

### 5. Local Append-Only Audit Log & Session Billing
- Every command, target application, coordinate, token usage, and USD cost is logged locally to:
  - `~/.computerusex/audit.jsonl` (action-level security audit trail)
  - `~/.computerusex/bills.jsonl` (session-level usage & billing receipts)
- **Zero Telemetry**: `ComputerUseX` is 100% local, has **zero external Swift package dependencies**, and never transmits screenshots, UI trees, or keystrokes over the network.

---

## 📬 Reporting a Vulnerability

If you discover a security boundary bypass or privilege escalation issue in `ComputerUseX`, please open a security advisory on GitHub or contact the maintainers before public disclosure.
