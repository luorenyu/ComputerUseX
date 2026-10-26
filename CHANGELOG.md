# Changelog

All notable changes to **OpenComputerUse (`ocu`)** are documented in this file.

## [1.0.0] - 2026-10-26

### ✨ Added
- **Tri-Modal Hybrid Grounding Engine**:
  - Millisecond `AXUIElement` accessibility tree traversal + on-device Apple `Vision` OCR (`VNRecognizeTextRequest`, `zh-Hans`/`en-US`) + Set-of-Marks (SoM) annotated screenshot rendering.
  - Incremental `AX Diff` and perceptual `dHash` image deduplication to cut multimodal LLM token consumption by 60–80%.
- **Zero-Focus Background Virtual Cursor & Persistent Live PiP Preview**:
  - Operates background macOS applications (such as WeChat, Chrome, Finder, Notes) without stealing the user's physical mouse or bringing background windows to the front.
  - Persistent bottom-right **Live Picture-in-Picture (PiP) Preview Window** that stays continuously visible throughout multi-step Agent tasks (including LLM thinking intervals) and closes automatically when the task finishes (`ocu bill --finish`).
  - One-click window summoning from the PiP preview window to bring the target app to the foreground.
- **Google Gemini (Mobile Live & Desktop) UI Design System**:
  - Unified `GeminiUITheme` with deep obsidian surfaces (`#0D0F15`), 4-stop Gemini Aurora gradients, concave 4-point Gemini sparkle icons (`✦`), and diffused ambient aurora halos.
  - 100% unified aerodynamic cyber-blade pointer (`UnifiedGeminiCursorView`) across both the desktop virtual cursor and the Mini PiP preview window.
  - Multi-monitor single-screen HUD lock: screen-edge aurora glow and bottom status capsule lock strictly onto the display currently being operated on.
- **Main Control Center Window (`ocu dashboard`)**:
  - Manage per-app authorization allowlists, interactive app consent prompts, zero-focus browser DOM/JS bridge settings, and background virtual cursor preferences.
  - View historical session bills, step-by-step execution timelines, and cumulative KPI metrics.
- **End-to-End Task Session Billing (`ocu bill`)**:
  - Tracks active Agent name and LLM model (`--agent` / `--model` self-reporting + automatic MCP/environment detection).
  - Dual duration metrics: **Total End-to-End Task Duration (including Agent LLM thinking time) + ComputerUse Tool Execution Duration**.
  - Input/output token accounting and real-time USD / CNY cost calculation.
- **17 Universal MCP Tools & CLI Subcommands**:
  - `status`, `apps`, `snapshot`, `click`, `move`, `type`, `press`, `scroll`, `drag`, `wait`, `batch`, `clipboard`, `browser`, `watch`, `workflow`, `audit`, `bill`, `dashboard`, `hud-demo`.
