# Contributing to OpenComputerUse (`ocu`)

Thank you for your interest in contributing to **OpenComputerUse**!

## 🎯 Design Philosophy & Constraints

1. **100% Native Swift 6 & Zero External Dependencies**:
   - `Package.swift` intentionally depends **only** on native Apple system frameworks (`ApplicationServices`, `Vision`, `AppKit`, `SwiftUI`, `CoreGraphics`, `UniformTypeIdentifiers`).
   - Do not introduce third-party SPM dependencies unless strictly necessary and discussed in an issue first.
2. **Zero-Focus Background Automation First**:
   - Whenever possible, actions should operate via `VirtualCursorWindowController`, `SyntheticFocusEnforcer`, `AXValue` direct injection, or `CGEvent.postToPid` without stealing the user's physical mouse cursor or yanking background windows to the foreground.
3. **Strict Coordinate Consistency**:
   - All internal coordinates in `OCUCore` use **Top-Left Logical Screen Points (`ScreenPoint`, `ScreenRect`)**, where `(0, 0)` is the top-left corner of the primary display.

---

## 🛠️ Local Development Setup

### Requirements
- macOS 14.0 (Sonoma) or later
- Xcode 16+ / Swift 6.0 toolchain

### Build & Run Tests
```bash
# Run the unit test suite
swift test

# Build release app bundle (dist/OpenComputerUse.app) and CLI/MCP binary (dist/ocu)
./scripts/build-app.sh

# Install to /Applications/OpenComputerUse.app and ~/.local/bin/ocu
./scripts/install.sh
```

### Verify Diagnostics & Visual HUD
```bash
ocu doctor
ocu dashboard
ocu hud-demo
```

---

## 📋 Pull Request Checklist
- [ ] `swift test` passes with 0 failures and 0 warnings.
- [ ] `./scripts/build-app.sh` succeeds in Release mode.
- [ ] New MCP tools or CLI subcommands are registered in both `OCUCommandExecutor.swift` and `MCPServer.swift`.
- [ ] Documentation (`README.md` / `README_CN.md`) is updated if user-facing flags or tools changed.
