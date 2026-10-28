# Changelog

All notable changes to **ComputerUseX (`cux`)** are documented in this file.

## [1.1.0] - 2026-10-28

### ✨ Added
- **Multi-Monitor & Cross-Space Zero-Interruption Engine**:
  - In-place background execution when a target application resides on a secondary display or another macOS Space, without pulling windows across displays or triggering macOS Space switches (`AppKitDefined` subtype 1/4 guarded on off-Space windows).
  - Non-intrusive window unminimizing (`AppWorkspaceController.reopenAppWindowIfNeeded`): unminimizes Dock-hidden windows and tucks them directly below the user's active foreground window (`order(.below, relativeTo:)`) when on the same display, or operates them directly in place on another display.
  - Off-Space `AXWindow` discovery via Cocoa accessibility remote tokens (`_AXUIElementCreateWithRemoteToken`) in ~25ms.
- **Smart Foreground vs. Background HUD Adaptation**:
  - Automatically detects when the target application window is already frontmost and unobstructed on its display (`SyntheticFocusEnforcer.isWindowFrontmostOnScreen`), suppressing the redundant Mini PiP preview window and showing a clean window border glow with the virtual pointer and click ripple.
- **Automatic Chromium / Electron UI Zoom Coordinate Calibration (`WindowZoomTransform`)**:
  - Automatically detects non-100% UI zoom levels (e.g., `90%`, `110%`, `125%`) in Electron/Chromium applications by comparing `AXWindow` screen bounds against the inner `BrowserRootView` (`AXGroup`) CSS bounds, applying bidirectional coordinate scaling for both screen visual alignment and `AXUIElementCopyElementAtPosition` hit-testing.
- **Client-Side Real-Time Operator & Model Detection**:
  - Inspects the full process ancestry (`KERN_PROCARGS2` executable path, arguments, and environment) inside the `cux` CLI client prior to Unix Socket IPC dispatch, ensuring accurate, real-time `Agent · Model` attribution across Antigravity, OpenAI Codex, Claude Code, OpenClaw, OpenCode, Cursor, Windsurf, Pi, MiniMaxCode, and Harness.
- **Post-Action Incremental Snapshot Diffs**:
  - Action commands (`click`, `type`, `press`, `scroll`) automatically return compact incremental UI diffs (`added`, `removed`, `changed`, `focus`) while preserving stable `@e1..@eN` element references from the preceding full snapshot.

### 🔧 Improved & Fixed
- **Universal Rich-Text Editor & Send Button Handling**:
  - Added `activateRichTextEditor` and universal placeholder/send-button detection across ProseMirror, Slate, Lexical, Draft.js, and native AppKit/SwiftUI text inputs.
  - Geometry-aware per-`AXWebArea` element budget (`maxElements = 500`, 260 per `AXWebArea` branch) so dense main content panes never starve left navigation sidebars.
  - Centralized transparent overlay and enterprise watermark window filtering (`isOverlayHelperWindow`).
  - Removed target element rounded-rectangle clutter on click and streamlined foreground HUD prompts.

## [1.0.0] - 2026-10-26

### ✨ Added
- **Tri-Modal Hybrid Grounding Engine**:
  - Millisecond `AXUIElement` accessibility tree traversal + on-device Apple `Vision` OCR (`VNRecognizeTextRequest`, `zh-Hans`/`en-US`) + Set-of-Marks (SoM) annotated screenshot rendering.
  - Incremental `AX Diff` and perceptual `dHash` image deduplication to cut multimodal LLM token consumption by 60–80%.
- **Zero-Focus Background Virtual Cursor & Persistent Live PiP Preview**:
  - Operates background macOS applications (such as WeChat, Chrome, Finder, Notes) without stealing the user's physical mouse or bringing background windows to the front.
  - Persistent bottom-right **Live Picture-in-Picture (PiP) Preview Window** that stays continuously visible throughout multi-step Agent tasks (including LLM thinking intervals) and closes automatically when the task finishes (`cux bill --finish`).
  - One-click window summoning from the PiP preview window to bring the target app to the foreground.
- **Google Gemini (Mobile Live & Desktop) UI Design System**:
  - Unified `GeminiUITheme` with deep obsidian surfaces (`#0D0F15`), 4-stop Gemini Aurora gradients, concave 4-point Gemini sparkle icons (`✦`), and diffused ambient aurora halos.
  - 100% unified aerodynamic cyber-blade pointer (`UnifiedGeminiCursorView`) across both the desktop virtual cursor and the Mini PiP preview window.
  - Multi-monitor single-screen HUD lock: screen-edge aurora glow and bottom status capsule lock strictly onto the display currently being operated on.
- **Main Control Center Window (`cux dashboard`)**:
  - Manage per-app authorization allowlists, interactive app consent prompts, zero-focus browser DOM/JS bridge settings, and background virtual cursor preferences.
  - View historical session bills, step-by-step execution timelines, and cumulative KPI metrics.
- **End-to-End Task Session Billing (`cux bill`)**:
  - Tracks active Agent name and LLM model (`--agent` / `--model` self-reporting + automatic MCP/environment detection).
  - Dual duration metrics: **Total End-to-End Task Duration (including Agent LLM thinking time) + ComputerUse Tool Execution Duration**.
  - Input/output token accounting and real-time USD / CNY cost calculation.
- **17 Universal MCP Tools & CLI Subcommands**:
  - `status`, `apps`, `snapshot`, `click`, `move`, `type`, `press`, `scroll`, `drag`, `wait`, `batch`, `clipboard`, `browser`, `watch`, `workflow`, `audit`, `bill`, `dashboard`, `hud-demo`.
