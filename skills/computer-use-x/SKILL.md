---
name: computer-use-x
description: "Controls macOS GUI applications and desktop interfaces using Tri-Modal Grounding (AXUIElement Accessibility Tree + Apple Vision OCR + Set-of-Marks annotated screenshots), smooth Bézier cursor trajectories, visual HUD feedback, and safe multi-language keyboard input. Use when the user asks to operate macOS apps, click buttons, fill native forms, inspect desktop windows, or automate GUI workflows."
---

# ComputerUseX (`cux`) — Desktop Computer Use Skill

`cux` gives AI Agents full desktop GUI perception and control on macOS with zero coordinate drift and visual HUD feedback.

## Core Workflow: Observe -> Act -> Verify -> Finish Bill

Always follow the **Snapshot (`@e1`) -> Action -> Verify -> Finish Bill** loop, and pass `--agent` and `--model` (e.g. `--agent "Antigravity" --model "Gemini 4 Argon Medium"`) on your first command so ComputerUseX displays your exact Agent & LLM Model in real time:

1. **Capture Tri-Modal Background Snapshot (with Agent & Model self-reporting)**:
   ```bash
   cux snapshot --app "WeChat" --compact --agent "Antigravity" --model "Gemini 4 Argon Medium"
   # Or with Set-of-Marks (SoM) annotated screenshot saved to disk:
   cux snapshot --app "WeChat" --som --output /tmp/cux_som.png
   ```
   `cux snapshot` returns numbered interactive elements (`@e1`, `@e2`, ...) combining the native `AXUIElement` tree and Apple `Vision` OCR, and opens the persistent bottom-right Mini PiP preview window for the entire duration of the task.
2. **Act by Element Reference (`@eX`) or Batch**:
   ```bash
   # Single click element @e3 with smooth Bézier virtual cursor:
   cux click @e3

   # Click and type Chinese/English/Emoji safely in background and press Return:
   cux type @e5 "ComputerUseX 桌面自动化" --clear --submit

   # Execute multiple steps in one batch:
   cux batch "click @e3" "type '文件传输助手' --submit" "wait --timeout 0.8" "snapshot --app WeChat --compact"
   ```
3. **Finalize Task & Close Preview Window (`cux bill --finish`)**:
   When the user's task is complete, ALWAYS run:
   ```bash
   cux bill --finish --agent "Antigravity" --model "Gemini 4 Argon Medium"
   ```
   This closes the bottom-right Mini PiP preview window and records the complete session bill (showing Total Task Duration + ComputerUse Tool Execution Duration, Token usage, and USD/CNY cost).

## Safety Guardrails
- **Kill Switch (`Option + Escape`)**: Immediately aborts any running agent action. Reset with `cux reset`.
- **Human Takeover Detection**: If the user physically moves the mouse while the agent is moving the pointer, `cux` yields control immediately with `ERR_HUMAN_TAKEOVER`.
