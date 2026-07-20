# Bento 混合工作台技术方案（agent pane + terminal pane 双类型）

2026-07-19。基于 `acp-native-v2`（tag `acp-baseline-m3`）之上。
本方案**取代** `acp-swap-plan.md` 中 M4"全面退役终端"的方向：终端以 pane 类型的身份回归，但底层不回到 tmux。

---

## 0. 产品定位决策（本方案的前提）

来自 2026-07-19 产品讨论的结论：

- **产品身份 = AI 时代的并发工作台**：大量分屏、高效语音、持久会话、Mac↔手机接力。solo 利基产品，不追 venture 规模。
- **终端不再是产品身份，而是 per-pane 的选择。** 基底的体验天花板按 surface×场景 分布：
  - Mac + coding：终端天花板最高（全保真 Claude Code TUI、万物皆 pane——htop/lazygit/测试 watch；官方 app 结构性做不到）；
  - 手机：终端天花板低（实证结论），但手机的真实 job 是 chat 形状（看进展/批权限/语音派活）→ 原生投影 + 终端逃生舱；
  - 非 coding 场景：骑原生 chat 面，是同一批重度用户的场景扩张，不是新用户群。
- **竞品格局**（2026-07 调研）："agent 遥控器"赛道已拥挤（Omnara/Happy/官方 `/remote-control`）；"平铺并发工作台 + 语音 + 手机端"仍无人占位。ACP 生态健康（JetBrains 共建、registry、25+ agents），且**尚无移动端原生 ACP 客户端**。
- **tmux 从产品地基降级为 pane 里可跑的普通程序**：老兵在 terminal pane 里 `tmux attach` 即可续上自己的会话，v0 场景零成本兼容。
- ACP 实验的产出降级为部件：daemon 托管持久化（核心资产）、chat 渲染栈（chat pane + 手机投影）、ACP 协议（chat pane 的接入通道之一）。

## 1. 总体架构：一个世界，不做两套底层

纯 v2 基底，**不与 main 的 tmux 世界合并**。用户担心的几个"底层不一样"在 v2 里已经统一：

| 层 | v2 现状 | 本方案增量 |
|---|---|---|
| 分屏/结构 | AgentWorkspaceStore + TmuxLayoutTree 管全部布局动词，pane 内容无关 | 无变化 |
| 传输 | acphost 密封协议唯一（握手/ChaCha20/credit/statekv）；relay worker 载荷无感 | stdio 帧内容多一种（终端字节）；控制面 +`resize` |
| 持久化 | daemon instance registry：detach 不杀、跨端 attach、statekv 结构同步 | instance 多一种 kind |
| pane 渲染 | tiled host / wrapper 构造 surface | 按 kind 分派（ghostty 文件全部现存） |
| 状态 | ACP turn lifecycle 精确喂 paneStates | terminal pane 走 hooks sidecar（§6） |

真正的新工程只有一块：daemon 侧 vt 网格（§5 P3），且可以最后做。

## 2. 数据模型

- `PaneEntry.kind: .agent | .terminal`（默认 `.agent`；旧持久化记录无 kind → `.agent`，向后兼容）。
- terminal pane 携带：command（默认 login shell，可以是 `claude`、`htop`、`tmux attach` 任何程序）、cwd、cols/rows。
- 全部结构动词（split/kill/swap/dock/zoom/break/join/tiledPreset…）对两类 pane 完全同构——store 与 bridge 零语义变化，视图零改动。

## 3. daemon：pty 实例类型

- `spawn` 控制帧增加 `kind` 字段。`kind=pty` 时 daemon 用 pty 启动进程（而非 ACP stdio 管道）。
- stdio 帧（0x02）载荷 = 原始终端字节；帧层、credit 流控（256KiB）、加密通道全部复用。
- 新控制操作：`resize{cols,rows}` → pty resize + SIGWINCH。
- scrollback：每实例裸字节 ring buffer（约 2MiB 上限）→ P3 起被 vt 网格取代。
- 生命周期与 agentInstance 完全一致：stream 断 = detach 保活；`kill` 显式；`list` 可见；结构进 statekv。
- Mac 本地同样经 daemon（acp.sock 明文通道）——**本地 pty pane 也持久化**，app 重启不丢。旧 LocalPtyTransport（app 内直起 pty，无持久化）退役。

## 4. 客户端渲染与传输

- **Mac**：tiled host `makeCell` 按 kind 分派 `GhosttyTerminalSurface`（现存文件）/ `AgentChatSurface`。
- **iOS**：`TerminalWrapperView` 按 kind 分派 `TerminalContainerVC` / `AgentChatVC`（两者都在，PaneContentController 协议已抽象）。
- 新增 `PtyStreamTransport`：实现 TerminalTransport 协议，字节 ↔ acphost stdio 帧。Mac 本地走 acp.sock，远程走 relay 密封流。"ghostty surface 吃远端字节流"= main 分支 iOS 的原架构，已验证多年，唯一变化是字节来源。
- 输入路径：键盘/语音字节直写 pty（经 stdio 帧）。

## 5. attach 保真：三阶段（每阶段可发布）

1. **P1 同尺寸裸回放**：Mac 本地 app 重启场景。尺寸持久化在 PaneEntry，回放 ring buffer（老 relay reattach+reseed 的成熟经验）。
2. **P2 跨尺寸 resize+SIGWINCH**：attach 时把 pty resize 到新 client 尺寸（**latest-wins**，与已验证的 tmux `window-size=latest` 同语义）。全屏 TUI（CC/vim/htop）收到 SIGWINCH 自行完整重画 → **当前屏即刻正确**；只有 shell 滚回历史在宽度变化后有毛边，可接受。
3. **P3 daemon vt 网格**：Go 终端状态机维护网格 + 带属性逐行 scrollback。attach 三步：scrollback 按新宽 re-wrap → 当前屏从网格重绘 → SIGWINCH。取代 ring buffer。选型硬要求：**CJK 宽字符**、true color、alt-screen（候选 charm x/vt 等，需专项测试）。

## 6. 状态检测

- agent pane：ACP turn lifecycle（现状，精确，不变）。
- terminal pane 里跑 CC：**hooks sidecar** —— CC 官方 hooks（Stop/Notification/PreToolUse）POST 到 daemon 本地端点，daemon 转 statekv/通知 → 客户端 paneState 与 badge。精确生命周期不需要 ACP，也不牺牲 TUI。注入方式（全局 settings vs per-spawn env）待定。
- 其他 TUI agent：现存 AgentStatusRules 截屏规则保留为兜底。
- 普通 shell pane：不检测（idle）。done-unseen/badge 轴不变。

## 7. 手机 CC 投影（增强路径，非必需）

目标：Mac 端全保真 TUI + 手机端原生聊天读，同一会话两种视图。

- 数据源：CC session transcript JSONL（回合/tool_call/diff 结构完整）。daemon 现成 readfile/listdir，新增 watch/tail 操作。
- 渲染：复用 AgentChatView/Cards。
- 输入：转写文本回注 pty。
- 逃生舱：同 pane 一键切网格视图。
- ✅ **承重假设已解剖（2026-07-19，实测本机 616 个 transcript）：有条件可行，偏乐观。** 要点：单文件含重建"气泡+thinking 折叠+工具卡片+diff+截图+token/标题/模式徽章"的全部信息（`tool_use.id↔tool_result.tool_use_id` 精确配对）；纯 append、行永远完整（2 万行抽验零解析失败）、54MB 全量解析 0.2s；`sessionId=文件名=claude --resume 键`；跨版本（2.1.112→2.1.205）schema 只加字段。**硬约束**：(1) 会话是树（rewind 分叉，实测单文件 84 分叉点）——必须从 `last-prompt.leafUuid` 沿 parentUuid 回溯活跃线程，不能按文件序/时间戳渲染；(2) Edit 工具存 old/new 字符串对非 diff，行级 diff 自己算（或读 file-history-snapshot 备份）；(3) 单行可达 1.28MB（base64 截图），image 块必须懒加载；(4) transcript 无 pane/PID，绑定靠 cwd+sessionId 外部关联；(5) subagent 正文在 `<sessionId>/subagents/*.jsonl` 兄弟文件；(6) 含代码/密钥，必须走密封信道+考虑脱敏开关。解析器按"未知 type/块类型优雅降级"写，别做硬断言。待挖备选：transcript 里的 `bridge-session {bridgeSessionId,lastSequenceNum}` 记录疑似官方 /remote-control 底层同步机制。

## 8. 语音

- agent pane：现状（← 插入 / → 发送 raw utterance）。
- terminal pane：转写直接打进 pty——CC 的输入框天然吃自然语言。**不复活** shell 的 LLM 命令转换层。
- compass 手势/阈值/触感全部不动。

## 9. 退役清单（取代 acp-swap-plan M4 范围）

| 时机 | 退役 |
|---|---|
| 立即 | desktop `sshserver/`、`tmuxresolver/`（已零引用） |
| P1 后 | mac LocalPtyTransport 直起路径（被 daemon pty 取代） |
| P2 后 | iOS SSH 栈（Citadel/SSHService/SSHKeyGenerator/直连 host）、TmuxControlMode 真连线、bundled tmux |
| 保留 | TmuxCommand/Parsers/LayoutTree 方言（内部协议词汇，后续可改名去 tmux 化）；GhosttyTerminalSurface 全套与 iOS 终端交互栈（IME/滚动/选择）——terminal pane 的渲染资产 |

## 10. 里程碑（每级独立可发布）

- **P1** pty pane 类型（Mac 本地，经 daemon，同尺寸回放）→ 工作台恢复终端能力
- **P2** 手机 attach（resize+SIGWINCH）+ iOS SSH 栈退役
- **P3** vt 网格，历史保真
- **P4** CC hooks 精确状态
- **P5** JSONL 手机投影（先做可行性解剖）
- 持续：逐屏验收（#21）、细节抠图清单

## 11. 开放问题

- 品牌：本方案下 fork 改名的必要性动摇（工作台定位回锚 Bento 与便当盒隐喻）——待定。
- 菜单语义：New Terminal Window 在本方案下重新有意义（= 新建 pty pane）；具体文案随细节阶段抠。
- 非 coding 场景在 Mac 端的入口（chat pane 新建路径/wizard 措辞）。
- vt 库选型专项调研（CJK 宽字符为第一淘汰项）。
- CC hooks 注入方式；非 CC agent 的 hooks 等价物盘点。
