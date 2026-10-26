# ✦ ComputerUseX (`cux`)

**产品级原生 Computer Use 引擎 · 零焦点后台虚拟指针 · 持续画中画实时预览 · 任务级消费账单 · 全平台 AI Agent MCP / Skill 插件**

[English](./README.md) | [简体中文](./README_CN.md) | [安全架构](./SECURITY.md) | [贡献指南](./CONTRIBUTING.md) | [更新日志](./CHANGELOG.md)

`ComputerUseX` (`cux`) 是一款采用 **100% 原生 Swift 6（零第三方依赖）** 构建的桌面感知与 GUI 自动化操控引擎，专为 **Antigravity、Claude Code、Claude Desktop、OpenAI Codex、Cursor、Windsurf** 等 AI Agent 打造。

告别传统 Computer Use 方案“频繁全屏截图、强行抢占物理鼠标、把后台窗口拉到前台打断用户工作、单次任务消耗数万 Token”的痛点，`ComputerUseX` 带来了 **Google Gemini Live 极光视觉风格**、**零焦点后台合成操控**、**右下角持续画中画（PiP）预览**与**完整任务消费账单**。

---

## 🌟 核心特性与技术壁垒

### 1. 🔍 三模态混合界面感知（`AXUIElement` + Apple `Vision` OCR + Set-of-Marks）
- **毫秒级原生无障碍树（AX Tree）**：直接读取 macOS 原生交互控件并生成确定性标号（`@e1`, `@e2`, ...），彻底消除 Retina 缩放偏移与视觉大模型猜坐标误差。
- **端侧中英混合 OCR 自动兜底**：针对微信、自绘 Canvas、Electron 应用或无标签图标，自动调用 Apple `Vision`（`VNRecognizeTextRequest`）提取文字坐标，并通过 IoU 去重与 AX 节点融合。
- **增量 Diff 与 Compact 极速压缩**：支持 `--compact`（核心元素精简）、`--diff`（增量 DOM/AX 树对比）与感知哈希 `dHash` 图像去重，大幅降低多模态 Token 消耗。

### 2. 👻 零焦点后台虚拟指针 & 右下角持续画中画（PiP）预览
- **不抢物理鼠标、不打断前台工作**：通过 `AXPress`、`AXValue`、后台 `CGEvent.postToPid` 及 CoreGraphics 窗口级合成焦点（Synthetic Focus）直接操控后台软件，你的物理鼠标和正在工作的窗口完全不受干扰。
- **任务全程持续显示右下角预览小窗**：当 Agent 在后台执行多步任务（例如打开微信 → 搜索联系人 → 输入并发送消息）时，右下角带有 **Gemini 极光外发光光晕的实时预览小窗** 会全程保持开启（包含大模型分析规划下一步的间隔期，底部胶囊实时提示 `"✦ Agent 正在分析与规划下一步..."`），直至任务真正结束（`cux bill --finish`）后平滑收起。
- **一键唤起真实窗口接管**：随时点击右下角预览小窗，即可立即将后台被操作软件恢复并置顶到桌面前台。

### 3. ✦ Google Gemini（手机版 Gemini Live + 电脑版）视觉设计系统
- **多层次弥散极光光晕**：深邃星曜暗色画布（`#0D0F15`）搭配 Google Gemini 标志性四色极光渐变（天际蓝 `#66B8FF` → Gemini 蓝 `#4285F4` → 星云紫 `#9B72CB` → 珊瑚粉 `#D96570`）与四角内凹星芒图标（`✦`）。
- **100% 统一流光刀锋指针**：桌面虚拟指针与右下角预览窗内指针完全共享同一套 `UnifiedGeminiCursorView`（无尾翼流线型极光刀锋 + 冰晶高光内切面 + 内嵌四芒星 + 针尖径向光晕与点击脉冲波纹）。
- **多显示器单屏精准锁定**：在多屏幕办公环境下，屏幕四周的 Gemini 极光边框与底部悬浮状态胶囊**仅锁定在当前正在操作的那一块显示器上**，其余屏幕保持纯净。

### 4. 🖥️ 「电脑操控中心」主窗口（`cux dashboard`）& 完整任务消费账单（`cux bill`）
- **应用授权与后台沙箱管理**：在主窗口可视化管理「任意应用」开关、首次访问未知应用弹窗授权、「始终允许的应用」白名单、Chrome/Safari/Arc 零焦点浏览器桥接与锁屏后台沙箱。
- **每次任务完整使用账单**：支持 Agent 调用时通过 `--agent` 与 `--model` 自报当前操作主体与大模型（如 `Antigravity · Gemini 4 Argon Medium`），精准记录 **总耗时（含大模型分析规划时间）+ ComputerUse工具调用耗时**、输入/输出 Token 数以及折算美元（USD）/ 人民币（CNY）金额。

---

## 🚀 一分钟快速开始

### 1. 一行命令极速安装（或源码编译安装）
```bash
# 方式 A：一行命令全自动安装（优先下载 GitHub Release 预编译包，或自动本地编译）
curl -fsSL https://raw.githubusercontent.com/luorenyu/ComputerUseX/main/scripts/install.sh | bash

# 方式 B：克隆源码并编译安装
git clone https://github.com/luorenyu/ComputerUseX.git
cd ComputerUseX
./scripts/install.sh
```
脚本会自动将 `ComputerUseX.app` 安装至 `/Applications/ComputerUseX.app`、将命令行工具 `cux` 软链至 `~/.local/bin/cux`，并**全自动把插件、Skill 与 MCP 服务注册到 OpenAI Codex、Claude、Antigravity/Gemini 和 Cursor** 中。

### 2. 启动守护进程并打开「电脑操控中心」
```bash
open /Applications/ComputerUseX.app
cux dashboard
```
在主控中心完成「辅助功能」与「屏幕录制」权限授权，点击右上角 **「✦ 演示效果 (Demo)」** 即可预览 Gemini 极光光晕与统一流光指针动画。

### 3. Agent 标准操作闭环示例
```bash
# 1. 感知后台软件界面（开启持续画中画预览窗，并上报当前 Agent 与模型）
cux snapshot --app "WeChat" --compact --agent "Antigravity" --model "Gemini 4 Argon Medium"

# 2. 在后台平滑点击与输入（不抢占物理鼠标与前台焦点）
cux click @e3
cux type @e5 "来自 ComputerUseX 的测试消息" --clear --submit

# 3. 结束任务并结算完整账单（平滑关闭右下角预览小窗）
cux bill --finish --agent "Antigravity" --model "Gemini 4 Argon Medium"
```

---

## 🧪 单元测试

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

## 📄 开源协议

本项目基于 [MIT License](./LICENSE) 开源。
