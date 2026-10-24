# OpenComputerUse (`ocu`)

**Product-Grade macOS Computer Use Engine, Visual HUD Companion App & Universal MCP / Skill Plugin for AI Agents.**

`OpenComputerUse` (`ocu`) brings Codex-class (and beyond) native GUI desktop perception and pointer control to **Antigravity, Claude Code, Claude Desktop, Cursor, Windsurf, OpenAI Codex**, and any MCP- or CLI-compatible Agent on macOS.

---

## ✨ Why OpenComputerUse?

Traditional "Computer Use" implementations rely purely on full-screen screenshots and asking a vision LLM to guess `(x, y)` pixel coordinates—resulting in high latency, heavy token cost, and Retina scaling drift.

**OpenComputerUse (`ocu`) solves this with a 100% native Swift 6 dual-end architecture:**

1. **🔍 Tri-Modal Hybrid Grounding (`AXUIElement` + Apple `Vision` OCR + Set-of-Marks)**
   - **Native AX Tree**: Reads interactive macOS controls (`button`, `textfield`, `menuitem`, `checkbox`, etc.) in milliseconds and assigns deterministic references (`@e1`, `@e2`, ...).
   - **Apple Vision OCR Fallback**: Automatically runs on-device Chinese/English OCR (`VNRecognizeTextRequest`) to detect clickable text inside custom canvases, Electron apps, games, or unlabelled UI, deduplicating against AX nodes via IoU matching.
   - **Set-of-Marks (SoM) Visual Annotation**: Draws color-coded bounding boxes, `@e1` badges, and logical coordinate rulers directly onto screenshots for multimodal verification.
2. **✨ Codex-Style Full-Screen Click-Through Visual HUD (`OpenComputerUse.app`)**
   - **Active Border Glow**: Soft cyan/indigo breathing border around the display while an Agent is operating.
   - **Cubic Bézier Pointer Physics**: Human-like smooth cursor movement with ease-in-out velocity and a glowing comet trail.
   - **Target Frame Highlight & Click Ripples**: Visual highlight around `@eX` targets and color-coded expanding ripples (Cyan for left-click, dual ring for double-click, Amber for right-click).
   - **Floating Action Pill**: Frosted glass status capsule at the bottom of the screen showing real-time agent actions and the `Opt+Esc` kill-switch hint.
3. **🛡️ Hardware-Level Safety Guardrails**
   - **Global Kill Switch (`Option + Escape`)**: Immediately aborts any ongoing automation sequence.
   - **Human Mouse Takeover Detection**: Automatically yields control (`ERR_HUMAN_TAKEOVER`) if the user physically grabs and moves the mouse during agent execution.
   - **Zero-Garble Multi-Language Input**: Transactional pasteboard injection types Chinese, English, Emoji, and code snippets instantaneously while preserving the user's original clipboard.

---

## 🏗️ Architecture

```
+-----------------------------------------------------------------------+
|   Antigravity  |  Claude Code / Desktop  |  Cursor  |  OpenAI Codex   |
+-----------------------------------+-----------------------------------+
                                    | MCP (stdio JSON-RPC 2.0) or Skill CLI
                                    v
+-----------------------------------------------------------------------+
|                     `ocu` (CLI & MCP Server Binary)                   |
|  - Subcommands: status, doctor, apps, snapshot, click, type, press... |
|  - MCP Server: 10 tools over stdio (`ocu mcp`)                        |
+-----------------------------------+-----------------------------------+
                                    | Unix Domain Socket (/tmp/ocu-<uid>.sock)
                                    v
+-----------------------------------------------------------------------+
|             `OpenComputerUse.app` (MenuBar Host & HUD Engine)         |
|  - Holds unified macOS TCC Permissions (Accessibility + ScreenRecord) |
|  - Renders Full-Screen Non-Activating Click-Through Visual HUD        |
|  - Executes OCUCore Tri-Modal Perception & Bézier Action Engine       |
+-----------------------------------------------------------------------+
```

---

## 🚀 Quick Start

### 1. Build & Package Release Bundle
```bash
./scripts/build-app.sh
```
This compiles the Swift 6 release binaries and produces:
- `dist/OpenComputerUse.app` (Menu Bar companion app + HUD daemon)
- `dist/ocu` (Standalone CLI & MCP Server binary)

### 2. Launch the Menu Bar & Visual HUD App
```bash
open dist/OpenComputerUse.app
```
Grant **Accessibility** and **Screen Recording** permissions from the Menu Bar popover, or test the visual HUD directly:
```bash
./dist/ocu hud-demo
```

### 3. Run CLI Diagnostics & Commands
```bash
# Check permissions, screen metrics, and daemon status
./dist/ocu doctor

# List running GUI apps and windows
./dist/ocu apps

# Scan active window (AX Tree + Apple Vision OCR + SoM Annotated Screenshot)
./dist/ocu snapshot --som --output /tmp/som.png

# Click element @e1 with smooth Bézier trajectory & HUD ripple
./dist/ocu click @e1

# Type Chinese/English text into @e3 and submit
./dist/ocu type @e3 "Hello OpenComputerUse 桌面自动化" --clear --submit

# Trigger keyboard shortcut
./dist/ocu press "cmd+shift+p"
```

---

## 🔌 Agent Integration

### Option A: MCP Server (Antigravity / Claude / Cursor / Windsurf)
Add to your MCP configuration (`mcp_config.json` or `claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "open-computer-use": {
      "command": "/Users/ronny/Agent/RonnyDaily/OpenComputerUse/dist/OpenComputerUse.app/Contents/MacOS/ocu",
      "args": ["mcp"]
    }
  }
}
```

#### Provided MCP Tools (10 Tools)
| Tool | Description |
| :--- | :--- |
| `ocu_status` | Inspect TCC permissions, daemon connection, screen resolution, and cursor coordinates |
| `ocu_apps` | List running GUI apps & windows, or focus/launch/resize a target application |
| `ocu_snapshot` | Capture Tri-Modal UI snapshot (`@e1..@eN` from AX + Vision OCR) and optional SoM annotated PNG |
| `ocu_click` | Click by `@eX` reference, fuzzy label, or `(x, y)` coordinates (left/right/double/ax_native) |
| `ocu_move` | Glide mouse cursor smoothly along a cubic Bézier curve to `@eX` or `(x, y)` |
| `ocu_type` | Click optional `@eX` and type multi-language text safely with optional `--clear` and `--submit` |
| `ocu_press` | Press key or shortcut combination (`cmd+c`, `cmd+shift+p`, `enter`, `escape`, `tab`) |
| `ocu_scroll` | Smooth pixel scrolling (`dx`, `dy`) at current cursor or target `@eX` |
| `ocu_drag` | Smooth drag between two elements (`@e1` -> `@e2`) or coordinate pairs |
| `ocu_wait` | Poll until target text appears on screen (AX + OCR) or wait for fixed seconds |

### Option B: Agent Skill (`SKILL.md`)
Copy or symlink `skills/open-computer-use` into your `~/.gemini/config/skills/` or `~/.claude/skills/` directory.

---

## 🧪 Testing

Run the unit test suite (covering geometry IoU, Bézier trajectory sampling, Vision OCR coordinate transforms, SoM image annotation, Unix Socket IPC round-trip, and MCP JSON-RPC protocol):
```bash
swift test
```
