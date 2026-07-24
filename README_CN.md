# Bento — 指挥一队 AI 编程 agent

[English](README.md) | 简体中文

在自己的 Mac 上并行跑多个编程 agent。谁在干活、谁在等你，一眼看清。用语音回答它们——走到哪都行。

<!-- hero：发布前放一张截图或短 GIF。
     建议构图：Parallel 窗口 4 个 agent pane 混合状态
     （working / waiting / done），侧栏可见，语音悬浮层激活。
<p align="center"><img src="docs/hero-mac.png" width="720" alt="Bento 并行运行四个 agent"></p>
-->

现代编程是几个 agent 同时干活，你负责 review、解卡、拍板。Bento 就是为这个工作流打造的原生 macOS 工作台——像便当盒一样把 agent 分格摆开——还有 iOS 伴侣应用，让你的 agent 团队跟着你出门。

Agent 通过 [ACP](https://agentclientprotocol.com)（Agent Client Protocol）接入，每个 pane 都是一等公民的对话：流式 Markdown、带真实 diff 的工具卡片、按钮化的权限确认——不是抓屏拼出来的终端画面。

## 一眼看清整个 agent 团队

- **每个 pane 都知道自己 agent 的状态**——工作中（蓝）、等你输入（琥珀）、已完成（绿 ✓）、空闲——同一套颜色 + 图形语言贯穿 pane 标题栏、侧栏和会话标签。
- **状态来自协议本身。** 回合进行中、权限待确认，都是 ACP 生命周期事件，不靠屏幕启发式猜测。
- **任何 ACP agent 都能用：** Claude Code、Codex、Gemini CLI、OpenCode、Cursor Agent、Copilot CLI、Amp、OpenClaw、Hermes、Antigravity——还能用自己的 API key 接入 Kimi、GLM、DeepSeek，或任何会说 ACP 的自定义命令。
- **同一工作区的两种读法：** Parallel（全部平铺）和 Focus（单个对话全屏 + 列表切换）。切换只是视图偏好——结构零变化、零丢失。

## 真正的对话，不是抓屏

- **流式 transcript**：Markdown 渲染、可折叠的推理过程、带实时状态与统一 diff 的工具卡片。
- **权限即按钮**——看完真实 diff 后 ⌘⏎ 批准；agent 提问时从选项列表里选答案。
- **斜杠命令、模型/模式切换、用量仪表、图片附件**——agent 声明什么能力，composer 就露出什么。
- **文件预览：** 点工具卡片里的任意路径，侧边 dock 里直接看高亮代码或渲染后的 Markdown；⌘P 打开命令面板，搜文件、翻历史。

## 用说的，别打字

- **在任意处按住说话。** 松手把转写文本放进 composer；上滑当场发送。右键长按某个 pane（iOS 双指长按），就是直接说给那个 agent。
- **识别懂你的对话。** 词表由屏幕上的 transcript 动态偏置，中英混说也没问题。
- **零配置。** 语音开箱即用（走 Bento relay）。想直连也行——Apple 端上、OpenAI、Qwen 三种引擎都支持自带 key。

## 比一切都长寿的会话

- **Agent 活在 daemon 里，不在 app 里。** 退出 Mac app，agent 继续干活；重新打开，对话原地恢复。
- **随时捡起任何历史对话。** 历史目录记住每个会话；重新打开会重启 agent 并完整回放 transcript。
- **iOS 伴侣：** 扫码配对、端到端加密、无账号。跑到一半合上笔记本，在口袋里继续回答 agent——工作区结构双向同步。

## 安装

**要求：** macOS 14+，Apple Silicon。

1. 从[最新 release](https://github.com/NovaShang/bento/releases/latest) 下载 `Bento-macos-arm64.zip`。
2. 解压，把 `Bento.app` 拖进 `/Applications`。应用已签名并公证——打开不会有警告。
3. 首次启动会引导你创建第一个 agent 会话，没装的 agent 也有一键安装命令。

Mac app 完全自包含（内嵌 daemon 和 CLI）。独立的 `bento` CLI + daemon（`brew install NovaShang/bento/bento-terminal`）只在无头主机上需要。

## 隐私

- **无账号。** 不需要注册任何东西；配对就是唯一的身份。
- **遥测默认关闭**，严格 opt-in——只有一组封闭的功能计数器，永不包含对话内容。
- **语音音频**经 Bento relay 到语音服务商（key 在服务端）；用自己的 key 则直连服务商。对话内容只会通过端到端加密的 relay 到达你自己配对的设备。

## 架构

完整版见 [docs/architecture.md](docs/architecture.md)。速览：

```
┌─ iOS app ──────┐        ┌─ Cloudflare relay ─┐        ┌─ Mac ────────────────────────────┐
│ WorkspaceScreen │◄─wss──►│  (配对 + 端到端     │◄─wss──►│ bento-daemon                     │
│ 聊天 pane       │        │   加密管道)         │        │  ├─ agent 进程 (ACP, stdio)      │
│ 语音            │        └────────────────────┘        │  ├─ statekv (工作区镜像)          │
└─────────────────┘                                      │  └─ unix socket ─── Mac app/CLI  │
                                                         └──────────────────────────────────┘
```

| 层 | 选型 |
|---|---|
| Agent 协议 | [ACP](https://agentclientprotocol.com) over stdio，自研 [`acpkit`](acpkit/) Swift 包（协议 + daemon 传输） |
| 应用 | 端到端原生 Swift——macOS 用 AppKit/SwiftUI，iOS 用 UIKit/SwiftUI——都是共享包 [`bento-core`](bento-core/) 之上的薄壳 |
| 持久化 | Go daemon 托管 agent 进程 + 小型 statekv；对话存在 agent 自己的存储里（`session/load` 恢复） |
| 远程可达 | Go daemon + Cloudflare Worker relay：配对、端到端加密传输、ASR/LLM 代理——见 [docs/relay-protocol.md](docs/relay-protocol.md) |
| 语音 | `SpeechEngine` 抽象覆盖 Apple 端上 / OpenAI / Qwen 实时 ASR，transcript 上下文词表偏置 |

## 仓库结构

| 目录 | 内容 |
|---|---|
| `Bento/` | iOS / iPadOS 应用 |
| `BentoMenubar/` | macOS 应用（菜单栏 + 工作区窗口） |
| `bento-core/` | 共享 Swift core：工作区模型、agent 会话、聊天 UI、语音、文件预览 |
| `acpkit/` | ACP 协议 + daemon 传输 Swift 包 |
| `desktop/` | Go 主机侧 daemon + `bento` CLI（agent 托管、配对、relay 客户端） |
| `relay/` | Cloudflare Worker relay（配对、传输、ASR/LLM 代理） |
| `docs/` | [架构](docs/architecture.md)、PRD、设计文档、[relay 协议](docs/relay-protocol.md) |

## 从源码构建

需要 Xcode 16+ 和 Go 1.23+（Mac app 构建时内嵌 Go daemon）。

```sh
git clone https://github.com/NovaShang/bento.git && cd bento
xcodebuild -project Bento.xcodeproj -scheme BentoMenubar -configuration Release build
```

`BentoMenubar` scheme 是 macOS 应用；`Bento` scheme 是 iOS。改了 `project.yml` 后用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 重新生成工程。

## 许可

[Apache-2.0](LICENSE)
