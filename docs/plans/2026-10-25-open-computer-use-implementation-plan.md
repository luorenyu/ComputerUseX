# OpenComputerUse (`ocu`) — 产品级实施计划 (Implementation Plan)

## 阶段一：工程骨架与基础规范 (Project Scaffolding & Standards)
1. 创建 `AGENTS.md`、`CLAUDE.md`、`.gitignore` 与 `Package.swift`（Swift 6 / macOS 14+，定义 `OCUCore`、`ocu`、`OpenComputerUseApp`、`OCUCoreTests`）。
2. 定义统一的数据模型与错误体系（`Sources/OCUCore/Models/`）：
   - `GeometryModels.swift`（`ScreenPoint`, `ScreenRect`, IoU 计算、贝塞尔曲线插值算法）
   - `ElementModels.swift`（`UIElementRef`, `SnapshotResult`, `AppInfo`, `WindowInfo`）
   - `CommandModels.swift`（IPC / CLI / MCP 共享请求与响应载荷、`OCUError` 自愈错误码）
   - `HUDModels.swift`（HUD 动画事件：鼠标轨迹、点击波纹、目标高亮、状态胶囊更新）

## 阶段二：权限、安全护栏与三合一感知引擎 (Permissions, Safety & Tri-Modal Perception)
1. `PermissionManager.swift`：检测并请求 Accessibility (`AXIsProcessTrustedWithOptions`) 与 Screen Recording (`CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess`) 权限，提供打开系统设置指定隐私面板的快捷方法。
2. `KillSwitchMonitor.swift`：
   - 全局快捷键 `Option + Escape` 监听与紧急中止信号广播。
   - 物理鼠标接管检测（对比上次由 `OCUCore` 移动到的目标坐标与当前物理鼠标位置，若人类大幅拖拽偏移 `> 60px` 则自动触发保护）。
   - 敏感应用黑名单校验。
3. `ScreenCaptureService.swift`：
   - 捕获全屏或指定窗口高清截图，自动记录屏幕缩放比例（Retina backingScaleFactor）以确保逻辑点与像素点精准对齐。
4. `AXScanner.swift`：
   - 遍历 `NSWorkspace` 活动窗口或指定 App 的 `AXUIElement` 层级树（带深度与耗时上限保护，防止死循环或大型网页卡死）。
   - 提取 Role、Title、Description、Value、Frame、Enabled、Focused，标准化角色名并过滤无面积或离屏节点。
5. `VisionOCRScanner.swift`：
   - 使用 Apple `Vision` 框架 (`VNRecognizeTextRequest`，`.accurate`，支持 `zh-Hans`, `zh-Hant`, `en-US`) 识别图像中的文字块并转换回屏幕全局逻辑坐标。
   - 通过 IoU / 中心点包含算法与 `AXScanner` 结果去重融合，生成统一的 `@e1 ~ @eN` 元素列表。
6. `SoMAnnotator.swift`：
   - 使用 `CoreGraphics` 在截图上绘制高对比度彩色边框与 `@eX` 编号角标（区分 `ax` 与 `ocr` 颜色），加上顶部/左侧坐标刻度尺，导出压缩后的 PNG 文件与 Base64。
7. `ElementSnapshotStore.swift`：
   - 线程安全地持久化最新一次快照（内存 + `~/.opencomputeruse/last_snapshot.json`），支持跨 CLI 调用通过 `@e1` 直接检索坐标与元素信息。

## 阶段三：物理级键鼠动作引擎 (Action Engine)
1. `MouseController.swift`：
   - 三次贝塞尔曲线 (`CubicBezier`) 轨迹生成器（带微随机控制点与 Ease-In-Out 速度曲线），按 60fps 发送 `CGEvent` 鼠标移动事件并同步通知 HUD 绘制光标轨迹。
   - 支持左键、右键、中键单击/双击/三击，支持平滑拖拽 (`drag`) 与像素级平滑滚轮 (`scroll`)。
   - 支持 `--ax-native` 直接调用 `AXUIElementPerformAction(kAXPressAction)` 并在失败时平滑降级到 `CGEvent`。
2. `KeyboardController.swift`：
   - 完整 macOS 虚拟键码 (`CGKeyCode`) 映射表与修饰键 (`cmd`, `shift`, `opt`, `ctrl`, `fn`) 解析器。
   - 支持纯 ASCII 模拟按键输入，以及针对中文/多语言/长文本的**安全剪贴板事务注入**（备份 `NSPasteboard` -> 写入文本 -> 发送 `Cmd+V` -> 恢复原剪贴板）。
3. `AppWorkspaceController.swift`：
   - 列出运行中 GUI 应用与窗口列表（结合 `NSWorkspace` 与 `CGWindowListCopyWindowInfo`）。
   - 支持启动应用、激活置顶应用、以及通过 `AXUIElement` 调整窗口位置和尺寸。

## 阶段四：双端 IPC 通信、CLI 与 MCP Server (`ocu`)
1. `UnixSocketIPC.swift`：
   - 基于 POSIX `socket(AF_UNIX, SOCK_STREAM, 0)` 的服务端（运行在 `OpenComputerUse.app` 中，监听 `/tmp/ocu-<uid>.sock`）与客户端（运行在 `ocu` CLI/MCP 中）。
   - 当守护进程在线时，`ocu` 自动将指令转发给守护进程执行并联动全屏视觉 HUD；当守护进程未启动时，支持自动拉起或本地直接调用 `OCUCore` 执行。
2. `MCPServer.swift`：
   - 标准 MCP (Model Context Protocol, `2024-11-05` / `2025-03-26`) JSON-RPC 2.0 over stdio 服务端。
   - 暴露 10 个核心工具（`ocu_status`, `ocu_apps`, `ocu_snapshot`, `ocu_click`, `ocu_move`, `ocu_type`, `ocu_press`, `ocu_scroll`, `ocu_drag`, `ocu_wait`），支持返回结构化 JSON 文本与 `image/png` Base64 内容块。
3. `OCUCLI.swift`：
   - 零外部依赖的命令行解析器，支持 `--json` 输出、人类可读彩色输出、`ocu doctor` 全链路自检、`ocu hud-demo` 视觉特效演示、`ocu mcp` 启动 MCP 服务。

## 阶段五：菜单栏宿主 App 与全屏穿透视觉 HUD (`OpenComputerUseApp`)
1. `OverlayHUDWindow.swift` & `OverlayHUDView.swift`：
   - 全屏无边框鼠标穿透透明窗口（`.screenSaver` 层级）。
   - 绘制屏幕四周流光呼吸边框、平滑鼠标光环与彗星尾迹、点击扩散双层波纹、目标控件圆角高亮框、底部悬浮磨砂状态胶囊。
2. `MenuBarApp.swift` & `OnboardingView.swift`：
   - 状态栏常驻图标与控制面板（显示权限绿灯、IPC 状态、最近 20 条动作历史、一键测试 HUD 动画、紧急制动开关、权限设置快捷入口）。

## 阶段六：单元测试、应用打包与跨 Agent 插件生态 (Testing, Packaging & Ecosystem)
1. 编写 `Tests/OCUCoreTests/` 单元测试并运行 `swift test` 全部通过。
2. 编写 `scripts/build-app.sh` 与 `scripts/install.sh`，构建 Release 版 `dist/OpenComputerUse.app` 与 `dist/ocu`。
3. 编写 `skills/open-computer-use/SKILL.md`、MCP 配置模板 (`mcp/`) 与中英双语产品级 `README.md`。
