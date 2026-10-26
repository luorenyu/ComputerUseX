# ✦ ComputerUseX (`cux`)

**Product-Grade Desktop Computer Use Engine, Zero-Focus Background Virtual Cursor, Live PiP Preview, Session Billing & Universal MCP / Skill Plugin for AI Agents.**

[English](./README.md) | [简体中文](./README_CN.md) | [Security Policy](./SECURITY.md) | [Contributing](./CONTRIBUTING.md) | [Changelog](./CHANGELOG.md)

`ComputerUseX` (`cux`) is a **100% native Swift 6** (zero external dependencies) desktop perception and GUI automation engine designed for **Antigravity, Claude Code, Claude Desktop, OpenAI Codex, Cursor, and Windsurf**.

Unlike screenshot-only Computer Use wrappers that hijack your physical mouse, yank background windows to the front, and burn tens of thousands of vision tokens per task, `ComputerUseX` operates background apps silently with a **Google Gemini Live-inspired UI**, a **Zero-Focus Virtual Cursor**, a **Persistent Live Picture-in-Picture (PiP) Preview**, and **Full Session Usage Billing**.

---

## 🌟 Key Highlights

### 1. 🔍 Tri-Modal Hybrid Grounding (`AXUIElement` + Apple `Vision` OCR + Set-of-Marks)
- **Millisecond Native AX Tree**: Directly traverses macOS `AXUIElement` hierarchies (`button`, `textfield`, `menuitem`, `checkbox`, etc.) and assigns deterministic references (`@e1`, `@e2`, ...).
- **On-Device Vision OCR Fallback**: Automatically runs Apple `Vision` (`VNRecognizeTextRequest`, `zh-Hans` + `en-US`) on custom canvases, Electron/WeChat views, or unlabelled icons, deduplicating against AX nodes via IoU matching.
- **Set-of-Marks (SoM) Visual Annotation**: Renders color-coded bounding boxes and `@eX` badges onto window-cropped screenshots for multimodal verification.
- **Token-Saving Compact & Diff Engine**: Supports `--compact` (top-N salient elements), `--diff` (incremental AX tree diff), and perceptual `dHash` image deduplication.

### 2. 👻 Zero-Focus Background Virtual Cursor & Persistent Live PiP Preview
- **Never Hijacks Your Physical Mouse**: Dispatches actions directly to target windows (`AXPress`, `AXValue`, background `CGEvent.postToPid`, and CoreGraphics window-specific synthetic focus) without moving your hardware cursor or stealing foreground focus.
- **Persistent Bottom-Right Live PiP Window**: While an Agent operates a background app (e.g., sending a WeChat message across multiple steps), a floating **Gemini Aurora-framed Live PiP Window** stays continuously open in the bottom-right corner—showing the unified virtual pointer, click ripples, and `"✦ Agent 正在分析与规划下一步..."` status—until `cux bill --finish` completes the task.
- **One-Click Foreground Takeover**: Click anywhere on the Live PiP preview window to immediately unminimize and summon the real target window to the front.

### 3. ✦ Google Gemini (Mobile Live & Desktop) Design System
- **Ambient Aurora Halos**: Deep obsidian canvas (`#0D0F15`) paired with diffused 4-stop Google Gemini Aurora gradients (`#66B8FF` -> `#4285F4` -> `#9B72CB` -> `#D96570`) and concave 4-point Gemini sparkle icons (`✦`).
- **100% Unified Cyber-Blade Pointer**: Both the desktop virtual cursor and the Mini PiP preview cursor share a single `UnifiedGeminiCursorView` with an aerodynamic tailless aurora blade, crystalline inner facet, 4-point sparkle glint, and tip energy halo.
- **Multi-Monitor Single-Screen Lock**: In multi-display setups, the screen-edge Gemini Aurora border glow and floating bottom status capsule lock strictly onto the single display currently being operated on.

### 4. 🖥️ Main Control Center (`cux dashboard`) & End-to-End Session Billing (`cux bill`)
- **App Authorization & Sandbox Control Center**: Manage "Allow Any App" vs. interactive first-time app consent prompts, per-app allowlists, zero-focus Chrome/Safari/Arc/Brave/Edge DOM bridges, and lock-screen background sandboxing.
- **Complete Task Billing Receipts**: Tracks which **Agent** and **LLM Model** (e.g., `Antigravity · Gemini 4 Argon Medium`) is operating `ComputerUseX`, recording **Total Task Duration (including LLM thinking time) + ComputerUse Tool Execution Duration**, input/output tokens, and USD / CNY cost.

---

## 🏗️ Architecture

```
+-------------------------------------------------------------------------+
|   Antigravity  |  Claude Code / Desktop  |  Cursor  |   OpenAI Codex    |
+------------------------------------+------------------------------------+
                                     | MCP (stdio JSON-RPC 2.0) or Skill CLI
                                     v
+-------------------------------------------------------------------------+
|                      `cux` (CLI & MCP Server Binary)                    |
|  - 17 MCP Tools (`cux mcp`) & CLI Subcommands                           |
|  - Self-reporting `--agent` & `--model` telemetry                       |
+------------------------------------+------------------------------------+
                                     | Unix Domain Socket (/tmp/cux-<uid>.sock)
                                     v
+-------------------------------------------------------------------------+
|          `ComputerUseX.app` (MenuBar Daemon & Gemini HUD)               |
|  - Native NSStatusItem + NSPopover MenuBar Controller                   |
|  - Main Control Center (`cux dashboard`) & App Permission Guard         |
|  - Persistent Bottom-Right Live PiP Preview & Unified Gemini Pointer    |
|  - Single-Display Locked Full-Screen Click-Through Gemini Aurora HUD    |
+-------------------------------------------------------------------------+
```

---

## 🚀 1-Minute Quick Start

### 1. Build & Install
```bash
git clone https://github.com/luorenyu/ComputerUseX.git
cd ComputerUseX
./scripts/install.sh
```
This compiles the Swift 6 release binaries, generates the Gemini Aurora `AppIcon.icns`, installs `/Applications/ComputerUseX.app`, and links `~/.local/bin/cux`.

### 2. Launch the Companion App & Open Control Center
```bash
open /Applications/ComputerUseX.app
cux dashboard
```
Grant **Accessibility** and **Screen Recording** permissions using the one-click onboarding banner in the Control Center, then click **"✦ 演示效果 (Demo)"** (or run `cux hud-demo`) to preview the Gemini Aurora HUD and unified pointer.

### 3. Core Agent CLI Workflow
```bash
# 1. Inspect a background app (opens persistent Live PiP preview & reports Agent/Model)
cux snapshot --app "WeChat" --compact --agent "Antigravity" --model "Gemini 4 Argon Medium"

# 2. Click & type in the background without stealing foreground focus
cux click @e3
cux type @e5 "Hello from ComputerUseX!" --clear --submit

# 3. Finish task session (closes Live PiP preview & records complete session bill)
cux bill --finish --agent "Antigravity" --model "Gemini 4 Argon Medium"
```

---

## 🔌 MCP Server Integration (17 Tools)

Add to your MCP configuration (`mcp_config.json` or `claude_desktop_config.json`), or run `cux install-mcp`:
```json
{
  "mcpServers": {
    "computer-use-x": {
      "command": "/Applications/ComputerUseX.app/Contents/MacOS/cux",
      "args": ["mcp"]
    }
  }
}
```

| Tool | Description |
| :--- | :--- |
| `cux_status` | Inspect TCC permissions, daemon connection, screen resolution, and cursor coordinates |
| `cux_apps` | List running GUI apps & windows, or focus/launch/resize a target application |
| `cux_snapshot` | Capture Tri-Modal UI snapshot (`@e1..@eN`) with `--compact`, `--diff`, and optional SoM PNG |
| `cux_query` | Targeted fast lookup for matching UI elements by role or text without full window dump |
| `cux_click` | Click by `@eX` reference, fuzzy label, or `(x, y)` coordinates (left/right/double/ax_native) |
| `cux_move` | Glide unified Gemini pointer smoothly along a cubic Bézier curve to `@eX` or `(x, y)` |
| `cux_type` | Type multi-language text safely via `AXValue` or transactional pasteboard with `--clear` / `--submit` |
| `cux_press` | Press key or shortcut combination (`cmd+c`, `cmd+shift+p`, `enter`, `escape`, `tab`) |
| `cux_scroll` | Smooth pixel scrolling (`dx`, `dy`) at current cursor or target `@eX` |
| `cux_drag` | Smooth drag between two elements (`@e1` -> `@e2`) or coordinate pairs |
| `cux_wait` | Poll until target text appears on screen (AX + OCR) or wait for fixed seconds |
| `cux_batch` | Execute multiple DSL commands (`click @e1`, `type "text" --submit`, `wait`) in one call |
| `cux_upload_file` | Select and submit a local file path inside a macOS Open/Save file dialog |
| `cux_secondary_action` | Invoke native Accessibility secondary actions (`AXShowMenu`, `AXIncrement`, etc.) |
| `cux_browser` | Zero-focus DOM & JavaScript bridge for Chrome, Safari, Arc, Brave, and Edge |
| `cux_sandbox` | Park or restore background windows in the Ghost Space peripheral sandbox |
| `cux_bill` | Query or finalize task session usage bills (`Total Duration + Tool Duration`, Tokens, USD/CNY) |

---

## 🧪 Testing

```bash
swift test
```

---

## 📈 Star History

<a href="https://star-history.com/#luorenyu/ComputerUseX&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=luorenyu/ComputerUseX&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=luorenyu/ComputerUseX&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=luorenyu/ComputerUseX&type=Date" />
 </picture>
</a>

---

## 📄 License

Licensed under the [MIT License](./LICENSE).
