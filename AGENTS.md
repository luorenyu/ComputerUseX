# AGENTS.md — OpenComputerUse (`ocu`) Engineering & Workflow Guidelines

## 1. Project Overview
**OpenComputerUse (`ocu`)** is a native macOS GUI automation and Computer Use engine built in Swift 6. It provides:
- `OCUCore`: Shared framework for Tri-Modal Perception (`AXUIElement` + Apple `Vision` OCR + Set-of-Marks annotation), Bézier curve Mouse/Keyboard control, Safety Guardrails, and Unix Domain Socket IPC.
- `ocu`: Fast CLI and standard Model Context Protocol (MCP) stdio server.
- `OpenComputerUseApp`: Menu bar companion app (`OpenComputerUse.app`) with full-screen click-through visual HUD (border glow, pointer trail, click ripples, floating action pill) and TCC permission onboarding.

## 2. Coding Standards
- **Language**: Swift 6 (`swift-tools-version: 6.0`), targeting `macOS(.v14)`.
- **Zero External Dependencies**: Prefer native Apple frameworks (`AppKit`, `SwiftUI`, `ApplicationServices`, `Vision`, `CoreGraphics`, `ScreenCaptureKit`, `Foundation`, `Darwin`) so `swift build` succeeds offline and instantaneously.
- **Coordinate System**: All external coordinates (`ScreenPoint`, `ScreenRect`) use standard macOS top-left screen coordinates (origin `(0, 0)` at top-left of main display), matching `CGEvent` and `AXUIElement`. Convert smoothly when rendering in `AppKit`/`SwiftUI` or `Vision` normalized bottom-left coordinates.
- **Safety First**: Always check `KillSwitchMonitor.shared.checkAborted()` during multi-step pointer animations and actions. Preserve user clipboard contents when using pasteboard text injection.

## 3. Build & Verification Workflow
- Build all targets: `swift build`
- Run unit tests: `swift test`
- Run CLI diagnostics: `.build/debug/ocu doctor`
- Package `.app` bundle: `./scripts/build-app.sh`
