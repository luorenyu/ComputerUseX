---
name: open-computer-use
description: "Controls macOS GUI applications and desktop interfaces using Tri-Modal Grounding (AXUIElement Accessibility Tree + Apple Vision OCR + Set-of-Marks annotated screenshots), smooth Bézier cursor trajectories, visual HUD feedback, and safe multi-language keyboard input. Use when the user asks to operate macOS apps, click buttons, fill native forms, inspect desktop windows, or automate GUI workflows."
---

# OpenComputerUse (`ocu`) — macOS Desktop Computer Use Skill

`ocu` gives AI Agents full desktop GUI perception and control on macOS with zero coordinate drift and visual HUD feedback.

## Core Workflow: Observe -> Act -> Verify -> Finish Bill

Always follow the **Snapshot (`@e1`) -> Action -> Verify -> Finish Bill** loop, and pass `--agent` and `--model` (e.g. `--agent "Antigravity" --model "Gemini 4 Argon Medium"`) on your first command so OpenComputerUse displays your exact Agent & LLM Model in real time:

1. **Capture Tri-Modal Background Snapshot (with Agent & Model self-reporting)**:
   ```bash
   ocu snapshot --app "WeChat" --compact --agent "Antigravity" --model "Gemini 4 Argon Medium"
   # Or with Set-of-Marks (SoM) annotated screenshot saved to disk:
   ocu snapshot --app "WeChat" --som --output /tmp/ocu_som.png
   ```
   `ocu snapshot` returns numbered interactive elements (`@e1`, `@e2`, ...) combining the native `AXUIElement` tree and Apple `Vision` OCR, and opens the persistent bottom-right Mini PiP preview window for the entire duration of the task.
2. **Act by Element Reference (`@eX`) or Batch**:
   ```bash
   # Single click element @e3 with smooth Bézier virtual cursor:
   ocu click @e3

   # Click and type Chinese/English/Emoji safely in background and press Return:
   ocu type @e5 "OpenComputerUse 桌面自动化" --clear --submit

   # Execute multiple steps in one batch:
   ocu batch "click @e3" "type '黑骑士' --submit" "wait --timeout 0.8" "snapshot --app WeChat --compact"
   ```
3. **Finalize Task & Close Preview Window (`ocu bill --finish`)**:
   When the user's task is complete, ALWAYS run:
   ```bash
   ocu bill --finish --agent "Antigravity" --model "Gemini 4 Argon Medium"
   ```
   This closes the bottom-right Mini PiP preview window and records the complete session bill (showing Total Task Duration + ComputerUse Tool Execution Duration, Token usage, and USD/CNY cost).

## Safety Guardrails
- **Kill Switch (`Option + Escape`)**: Immediately aborts any running agent action. Reset with `ocu reset`.
- **Human Takeover Detection**: If the user physically moves the mouse while the agent is moving the pointer, `ocu` yields control immediately with `ERR_HUMAN_TAKEOVER`.
