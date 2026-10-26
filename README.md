# ✦ OpenComputerUse (`ocu`)

**Product-Grade macOS Computer Use Engine, Zero-Focus Background Virtual Cursor, Live PiP Preview, Session Billing & Universal MCP / Skill Plugin for AI Agents.**

[English](./README.md) | [简体中文](./README_CN.md) | [Security Policy](./SECURITY.md) | [Contributing](./CONTRIBUTING.md) | [Changelog](./CHANGELOG.md)

`OpenComputerUse` (`ocu`) is a **100% native Swift 6** (zero external dependencies) macOS desktop perception and GUI automation engine designed for **Antigravity, Claude Code, Claude Desktop, OpenAI Codex, Cursor, and Windsurf**.

Unlike screenshot-only Computer Use wrappers that hijack your physical mouse, yank background windows to the front, and burn tens of thousands of vision tokens per task, `OpenComputerUse` operates background apps silently with a **Google Gemini Live-inspired UI**, a **Zero-Focus Virtual Cursor**, a **Persistent Live Picture-in-Picture (PiP) Preview**, and **Full Session Usage Billing**.

---

## 🌟 Key Highlights

### 1. 🔍 Tri-Modal Hybrid Grounding (`AXUIElement` + Apple `Vision` OCR + Set-of-Marks)
- **Millisecond Native AX Tree**: Directly traverses macOS `AXUIElement` hierarchies (`button`, `textfield`, `menuitem`, `checkbox`, etc.) and assigns deterministic references (`@e1`, `@e2`, ...).
- **On-Device Vision OCR Fallback**: Automatically runs Apple `Vision` (`VNRecognizeTextRequest`, `zh-Hans` + `en-US`) on custom canvases, Electron/WeChat views, or unlabelled icons, deduplicating against AX nodes via IoU matching.
- **Set-of-Marks (SoM) Visual Annotation**: Renders color-coded bounding boxes and `@eX` badges onto window-cropped screenshots for multimodal verification.
- **Token-Saving Compact & Diff Engine**: Supports `--compact` (top-N salient elements), `--diff` (incremental AX tree diff), and perceptual `dHash` image deduplication.

### 2. 👻 Zero-Focus Background Virtual Cursor & Persistent Live PiP Preview
- **Never Hijacks Your Physical Mouse**: Dispatches actions directly to target windows (`AXPress`, `AXValue`, background `CGEvent.postToPid`, and CoreGraphics window-specific synthetic focus) without moving your hardware cursor or stealing foreground focus.
- **Persistent Bottom-Right Live PiP Window**: While an Agent operates a background app (e.g., sending a WeChat message across multiple steps), a floating **Gemini Aurora-framed Live PiP Window** stays continuously open in the bottom-right corner—showing the unified virtual pointer, click ripples, and `"✦ Agent 正在分析与规划下一步..."` status—until `ocu bill --finish` completes the task.
- **One-Click Foreground Takeover**: Click anywhere on the Live PiP preview window to immediately unminimize and summon the real target window to the front.

### 3. ✦ Google Gemini (Mobile Live & Desktop) Design System
- **Ambient Aurora Halos**: Deep obsidian canvas (`#0D0F15`) paired with diffused 4-stop Google Gemini Aurora gradients (`#66B8FF` -> `#4285F4` -> `#9B72CB` -> `#D96570`) and concave 4-point Gemini sparkle icons (`✦`).
- **100% Unified Cyber-Blade Pointer**: Both the desktop virtual cursor and the Mini PiP preview cursor share a single `UnifiedGeminiCursorView` with an aerodynamic tailless aurora blade, crystalline inner facet, 4-point sparkle glint, and tip energy halo.
- **Multi-Monitor Single-Screen Lock**: In multi-display setups, the screen-edge Gemini Aurora border glow and floating bottom status capsule lock strictly onto the single display currently being operated on.

### 4. 🖥️ Main Control Center (`ocu dashboard`) & End-to-End Session Billing (`ocu bill`)
- **App Authorization & Sandbox Control Center**: Manage "Allow Any App" vs. interactive first-time app consent prompts, per-app allowlists, zero-focus Chrome/Safari/Arc/Brave/Edge DOM bridges, and lock-screen background sandboxing.
- **Complete Task Billing Receipts**: Tracks which **Agent** and **LLM Model** (e.g., `Antigravity · Gemini 4 Argon Medium`) is operating `OpenComputerUse`, recording **Total Task Duration (including LLM thinking time) + ComputerUse Tool Execution Duration**, input/output tokens, and USD / CNY cost.

---

## 🏗️ Architecture

```
+-------------------------------------------------------------------------+
|   Antigravity  |  Claude Code / Desktop  |  Cursor  |   OpenAI Codex    |
+------------------------------------+------------------------------------+
                                     | MCP (stdio JSON-RPC 2.0) or Skill CLI
                                     v
+-------------------------------------------------------------------------+
|                      `ocu` (CLI & MCP Server Binary)                    |
|  - 17 MCP Tools (`ocu mcp`) & CLI Subcommands                           |
|  - Self-reporting `--agent` & `--model` telemetry                       |
+------------------------------------+------------------------------------+
                                     | Unix Domain Socket (/tmp/ocu-<uid>.sock)
                                     v
+-------------------------------------------------------------------------+
|          `OpenComputerUse.app` (MenuBar Daemon & Gemini HUD)            |
|  - Native NSStatusItem + NSPopover MenuBar Controller                   |
|  - Main Control Center (`ocu dashboard`) & App Permission Guard         |
|  - Persistent Bottom-Right Live PiP Preview & Unified Gemini Pointer    |
|  - Single-Display Locked Full-Screen Click-Through Gemini Aurora HUD    |
+-------------------------------------------------------------------------+
```

---

## 🚀 1-Minute Quick Start

### 1. Build & Install
```bash
git clone https://github.com/luorenyu/OpenComputerUse.git
cd OpenComputerUse
./scripts/install.sh
```
This compiles the Swift 6 release binaries, generates the Gemini Aurora `AppIcon.icns`, installs `/Applications/OpenComputerUse.app`, and links `~/.local/bin/ocu`.

### 2. Launch the Companion App & Open Control Center
```bash
open /Applications/OpenComputerUse.app
ocu dashboard
```
Grant **Accessibility** and **Screen Recording** permissions using the one-click onboarding banner in the Control Center, then click **"✦ 演示效果 (Demo)"** (or run `ocu hud-demo`) to preview the Gemini Aurora HUD and unified pointer.

### 3. Core Agent CLI Workflow
```bash
# 1. Inspect a background app (opens persistent Live PiP preview & reports Agent/Model)
ocu snapshot --app "WeChat" --compact --agent "Antigravity" --model "Gemini 4 Argon Medium"

# 2. Click & type in the background without stealing foreground focus
ocu click @e3
ocu type @e5 "Hello from OpenComputerUse!" --clear --submit

# 3. Finish task session (closes Live PiP preview & records complete session bill)
ocu bill --finish --agent "Antigravity" --model "Gemini 4 Argon Medium"
```

---

## 🔌 MCP Server Integration (17 Tools)

Add to your MCP configuration (`mcp_config.json` or `claude_desktop_config.json`), or run `ocu mcp-install`:
```json
{
  "mcpServers": {
    "open-computer-use": {
      "command": "/Applications/OpenComputerUse.app/Contents/MacOS/ocu",
      "args": ["mcp"]
    }
  }
}
```

| Tool | Description |
| :--- | :--- |
| `ocu_status` | Inspect TCC permissions, daemon connection, screen resolution, and cursor coordinates |
| `ocu_apps` | List running GUI apps & windows, or focus/launch/resize a target application |
| `ocu_snapshot` | Capture Tri-Modal UI snapshot (`@e1..@eN`) with `--compact`, `--diff`, and optional SoM PNG |
| `ocu_click` | Click by `@eX` reference, fuzzy label, or `(x, y)` coordinates (left/right/double/ax_native) |
| `ocu_move` | Glide unified Gemini pointer smoothly along a cubic Bézier curve to `@eX` or `(x, y)` |
| `ocu_type` | Type multi-language text safely via `AXValue` or transactional pasteboard with `--clear` / `--submit` |
| `ocu_press` | Press key or shortcut combination (`cmd+c`, `cmd+shift+p`, `enter`, `escape`, `tab`) |
| `ocu_scroll` | Smooth pixel scrolling (`dx`, `dy`) at current cursor or target `@eX` |
| `ocu_drag` | Smooth drag between two elements (`@e1` -> `@e2`) or coordinate pairs |
| `ocu_wait` | Poll until target text appears on screen (AX + OCR) or wait for fixed seconds |
| `ocu_batch` | Execute multiple DSL commands (`click @e1`, `type "text" --submit`, `wait`) in one call |
| `ocu_clipboard` | Read or write macOS system clipboard without UI interaction |
| `ocu_browser` | Zero-focus DOM & JavaScript bridge for Chrome, Safari, Arc, Brave, and Edge |
| `ocu_watch` | Reactive UI monitor that blocks until target text appears or disappears |
| `ocu_workflow` | Record, replay, and list parameterized GUI automation macros (`~/.ocu/workflows/`) |
| `ocu_audit` | Inspect security audit logs and manage per-app authorization rules (`~/.ocu/security.json`) |
| `ocu_bill` | Query or finalize task session usage bills (`Total Duration + Tool Duration`, Tokens, USD/CNY) |

---

## 🧪 Testing

```bash
swift test
```

---

## 📈 Star History

<a href="https://star-history.com/#luorenyu/OpenComputerUse&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=luorenyu/OpenComputerUse&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=luorenyu/OpenComputerUse&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=luorenyu/OpenComputerUse&type=Date" />
 </picture>
</a>

---

## 📄 License

Licensed under the [MIT License](./LICENSE).
