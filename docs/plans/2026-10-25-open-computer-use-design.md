# OpenComputerUse (`ocu`) — 产品级架构与详细设计文档

- **日期**: 2026-10-25
- **项目目录**: `./OpenComputerUse`
- **命令行 / MCP 名称**: `ocu`
- **桌面宿主应用**: `OpenComputerUse.app`
- **技术栈**: Swift 6.0 (macOS 14+), AppKit / SwiftUI, ApplicationServices (AXUIElement), Vision (VNRecognizeTextRequest), ScreenCaptureKit / CoreGraphics, POSIX Unix Domain Socket, MCP (JSON-RPC 2.0 over stdio)

---

## 1. 项目愿景与定位

**OpenComputerUse (`ocu`)** 是一个面向 macOS 的开源、跨 Agent 通用的产品级桌面 GUI 自动化引擎与视觉交互套件。它旨在为 Antigravity、Claude Code、Claude Desktop、Cursor、Windsurf、Codex 等任意 AI Agent 提供媲美甚至超越原生 Computer Use 的桌面操控能力。

### 核心差异化特性
1. **三合一混合感知引擎 (Tri-Modal Hybrid Grounding)**：
   - **AX 辅助功能树 (`AXUIElement`)**：毫秒级读取原生控件树，提取精确语义、角色、状态与坐标，分配 `@e1`, `@e2` 引用编号。
   - **Apple Vision 原生 OCR (`VNRecognizeTextRequest`)**：针对自绘界面（Canvas、Electron、游戏、未暴露无障碍标签的图标/文本）自动进行本地中英文 OCR 识别，并与 AX 元素基于 IoU 去重融合，统一编号为 `@eX`。
   - **Set-of-Marks (SoM) 视觉标注截图**：在截图上绘制高对比度元素边框与 `@eX` 标签，彻底解决多模态大模型估算 Retina 像素坐标漂移的问题。
2. **媲美 Codex 的全屏穿透视觉 HUD (`OverlayHUDWindow`)**：
   - 屏幕四周 Agent 接管状态呼吸流光边框。
   - 三次贝塞尔曲线 (Cubic Bézier) 平滑鼠标轨迹与光环尾迹。
   - 点击目标框高亮闪烁 + 左/右/双击彩色扩散波纹。
   - 屏幕底部磨砂玻璃悬浮胶囊，实时展示当前动作与急停快捷键提示。
3. **100% 纯原生 Swift 双端协同架构**：
   - `OpenComputerUse.app`：常驻菜单栏宿主，统一管理 TCC 权限（辅助功能 + 录屏）、渲染全屏 HUD、监听安全急停、提供 Unix Domain Socket RPC。
   - `ocu`：零外部依赖的极速 CLI 与标准 MCP Server（`ocu mcp`），优先通过 Socket 驱动 `.app` 守护进程，也可在无 `.app` 时独立直连执行。
4. **产品级安全护栏**：
   - 全局快捷键 (`Option + Escape`) 立即急停。
   - 人类物理鼠标大幅晃动自动检测并让出控制权。
   - 敏感应用黑名单保护与安全剪贴板事务（支持中文/Emoji 零乱码输入且不污染用户剪贴板）。

---

## 2. 系统总体架构

```
+-----------------------------------------------------------------------+
|                        AI Agents (Clients)                            |
|   Antigravity  |  Claude Code / Desktop  |  Cursor  |  OpenAI Codex   |
+-----------------------------------+-----------------------------------+
                                    | MCP (stdio JSON-RPC 2.0) 或 Skill CLI
                                    v
+-----------------------------------------------------------------------+
|                     `ocu` (CLI & MCP Server Binary)                   |
|  - CLI Parser: status, doctor, apps, snapshot, click, type, press...  |
|  - MCP Server: ocu_status, ocu_apps, ocu_snapshot, ocu_click...       |
|  - IPC Client: connects to /tmp/ocu-<uid>.sock (or fallback direct)   |
+-----------------------------------+-----------------------------------+
                                    | Unix Domain Socket (JSON-RPC)
                                    v
+-----------------------------------------------------------------------+
|               `OpenComputerUse.app` (MenuBar & HUD Host)              |
|  - MenuBarExtra: 权限状态指示、最近动作日志、HUD 开关、急停开关           |
|  - OnboardingWindow: 辅助功能与屏幕录制权限一键检测与引导                  |
|  - OverlayHUDWindow: 全屏穿透流光边框、鼠标轨迹、点击波纹、状态胶囊        |
|  - OCUCore Engine:                                                    |
|      * Perception: AXScanner + VisionOCRScanner + SoMAnnotator        |
|      * Action: MouseController (Bézier) + KeyboardController          |
|      * Safety: KillSwitchMonitor (Opt+Esc & Mouse Takeover)           |
+-----------------------------------------------------------------------+
```

---

## 3. 核心数据模型与协议

### 3.1 UI 元素快照模型 (`UIElementRef`)
- `ref`: `String`（如 `"@e1"`, `"@e2"`）
- `source`: `"ax"` | `"ocr"`
- `role`: `String`（如 `"button"`, `"textfield"`, `"menuitem"`, `"staticText"`, `"ocrText"`）
- `label`: `String`（标题、描述或 OCR 识别出的文本）
- `value`: `String?`（当前值，如输入框内容或勾选状态）
- `frame`: `Rect`（屏幕全局坐标 `x, y, width, height`，原点位于主屏幕左上角）
- `centerPoint`: `Point`（默认点击中心点 `x, y`）
- `enabled`: `Bool`
- `focused`: `Bool`
- `appName`: `String`
- `windowTitle`: `String?`

### 3.2 CLI 与 MCP 工具矩阵

1. `ocu_status` / `ocu status`：返回权限状态、守护进程连接状态、屏幕信息、前台应用与安全护栏状态。
2. `ocu_apps` / `ocu apps`：枚举运行中应用与窗口，支持 `--launch <bundleId/name>`、`--focus <name>`、`--resize x,y,w,h`。
3. `ocu_snapshot` / `ocu snapshot`：
   - 参数：`app` (可选应用名)、`ocr` (是否启用 Vision OCR 补盲，默认自动/开启)、`som` (是否生成 Set-of-Marks 标注图)、`output` (截图输出路径)。
   - 返回：元素总数、前台窗口信息、`elements` 列表（含 `@e1` 编号、角色、文本、坐标）、以及可选的标注截图路径/Base64。
4. `ocu_click` / `ocu click`：
   - 参数：`target` (`@e1` 或文本匹配)、或 `x`, `y` 坐标；`button` (`left`/`right`/`middle`)；`count` (`1`/`2`/`3`)；`axNative` (是否优先调用 AXPress)。
5. `ocu_move` / `ocu move`：平滑移动指针到 `@eX` 或 `(x, y)`。
6. `ocu_type` / `ocu type`：
   - 参数：`target` (可选 `@eX`，若提供则先点击聚焦)、`text` (支持任意中英文与 Emoji)、`submit` (输入后是否按 Return)、`clear` (输入前是否 `Cmd+A` + `Backspace` 清空)。
7. `ocu_press` / `ocu press`：
   - 参数：`keys`（如 `"cmd+c"`, `"cmd+shift+p"`, `"enter"`, `"escape"`, `"tab"`）。
8. `ocu_scroll` / `ocu scroll`：
   - 参数：`dx`, `dy`（像素级平滑滚动），可选 `target` (`@eX` 或 `x,y`，先移至目标位置再滚动)。
9. `ocu_drag` / `ocu drag`：
   - 参数：`from` (`@eX` 或 `x,y`)，`to` (`@eY` 或 `x,y`)，`duration` (默认 0.35s)。
10. `ocu_wait` / `ocu wait`：
    - 参数：`text` (等待屏幕上出现指定文本/元素)、`timeout` (秒，默认 5.0) 或单纯 `seconds` 延时。

---

## 4. 错误处理与测试策略

- **结构化错误 (`OCUError`)**：包含 `code`、`message` 与 `recoveryHint`，引导 Agent 自愈（例如元素过期时提示重新 `snapshot`，缺少权限时引导授权）。
- **单元测试 (`OCUCoreTests`)**：覆盖贝塞尔曲线插值、矩形 IoU 去重与融合算法、快捷键字符串解析、SoM 标注画布绘制、Socket RPC 消息编解码、MCP JSON-RPC 2.0 路由测试。
- **打包与集成脚本**：
  - `scripts/build-app.sh`：编译并打包 `dist/OpenComputerUse.app` 及 `dist/ocu`。
  - `scripts/install.sh`：安装命令行与 `.app`，并输出 MCP 与 Skill 配置指南。
