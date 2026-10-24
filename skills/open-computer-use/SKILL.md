---
name: open-computer-use
description: "Controls macOS GUI applications and desktop interfaces using Tri-Modal Grounding (AXUIElement Accessibility Tree + Apple Vision OCR + Set-of-Marks annotated screenshots), smooth Bézier cursor trajectories, visual HUD feedback, and safe multi-language keyboard input. Use when the user asks to operate macOS apps, click buttons, fill native forms, inspect desktop windows, or automate GUI workflows."
---

# OpenComputerUse (`ocu`) — macOS Desktop Computer Use Skill

`ocu` gives AI Agents full desktop GUI perception and control on macOS with zero coordinate drift and visual HUD feedback.

## Core Workflow: Observe -> Act -> Verify

Always follow the **Snapshot (`@e1`) -> Action -> Verify** loop:

1. **Check or Focus Target Application**:
   ```bash
   ocu apps
   ocu apps --focus "Safari"
   ```
2. **Capture Tri-Modal Snapshot**:
   ```bash
   ocu snapshot
   # Or with Set-of-Marks (SoM) annotated screenshot saved to disk:
   ocu snapshot --som --output /tmp/ocu_som.png
   ```
   `ocu snapshot` returns numbered interactive elements (`@e1`, `@e2`, ...) combining the native `AXUIElement` tree and Apple `Vision` OCR (for custom canvases, Electron apps, and unlabelled icons).
3. **Act by Element Reference (`@eX`)**:
   ```bash
   # Single click element @e3 with smooth Bézier cursor & HUD ripple:
   ocu click @e3

   # Double-click or right-click:
   ocu click @e3 --double
   ocu click @e3 --right

   # Silent native AXPress without moving physical cursor:
   ocu click @e3 --ax-native

   # Click and type Chinese/English/Emoji safely into @e5 and press Return:
   ocu type @e5 "OpenComputerUse 桌面自动化" --clear --submit

   # Press keyboard shortcut:
   ocu press "cmd+shift+p"

   # Scroll over @e8:
   ocu scroll --target @e8 --dy -300

   # Drag from @e2 to @e6:
   ocu drag --from @e2 --to @e6
   ```
4. **Verify State**:
   ```bash
   ocu wait --text "Success" --timeout 5
   ocu snapshot
   ```

## Safety Guardrails
- **Kill Switch (`Option + Escape`)**: Immediately aborts any running agent action. Reset with `ocu reset`.
- **Human Takeover Detection**: If the user physically moves the mouse while the agent is moving the pointer, `ocu` yields control immediately with `ERR_HUMAN_TAKEOVER`.
