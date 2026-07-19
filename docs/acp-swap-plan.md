# ACP 底层替换 — 从 main 出发的外科式改造计划

## 原则（不可违背）

这条分支从 `main`（完整终端版）拉出。目标是**只替换底层：终端渲染 + tmux/SSH 后端 → ACP**，
对用户而言除了 pane 内容从终端网格变成聊天 GUI，**其余一切交互和 UI 与原版逐像素一致**。

判定规则：**默认不改。** 一个文件只有当它直接实现"终端渲染"或"tmux/SSH 后端"时才进 diff。
其它一律保持 main 原样。任何"顺手优化/精简/我觉得更好"都是违规。

## 禁止改动（原版逐字保留）

app shell 与交互层，全部保留 `main` 原文件，禁止编辑：

- `BentoMenubar/` 全部：`BentoMenubarApp.swift`（Shell 菜单、activation policy 促升）、
  `AppDelegate.swift`、`MenuContent.swift`（含 SessionsMenuView）、`SettingsView.swift`、
  `FirstRunWindow.swift`（五步）、`AgentWizardWindow.swift`、`PairingWindow.swift`、`DevicesWindow.swift`
- 结构/侧栏/tiled/tab：`TerminalViewModel+Structure.swift`（两模式、break/join、WindowSeed 含
  duplicateCurrent、Move to Session）、`WindowSidebar.swift`、`GhosttyTiledPaneHost_macOS.swift`
  的布局/拖拽 dropzone/zoom/分隔条/pane 菜单、`GhosttyTerminalTabBar_macOS.swift`、
  `PaneDropZone.swift`、`CommandPalette*.swift`
- 语音：`MacVoiceController_macOS.swift`、`VoiceCompassView.swift`、`VoiceSession.swift`、
  引擎三件、`VoicePressGesture.swift`、`VoiceInputController.swift`、`VoiceOverlayView.swift`、
  `LLMService.swift`（left/right → shell）
- 文件预览/路径检测：`FilePreview*.swift`、`PathDetection.swift`、`SurfacePathHitEngine.swift`、
  `PathPreviewUI.swift`、`TurnNavigator.swift`、`ScrollReviewCompose.swift`
- iOS：`HostListView`、`HostSessionsView`、`WelcomeFlowView`、`RelayPairView`、
  `HowBentoWorksView`、`GestureOnboardingOverlay`、`KeyboardAccessoryView`、compose bar、
  `Settings/SettingsView.swift`（含 State Profile 编辑器）
- 遥测、外观、TipCenter、配对/daemon 存储、Keychain

## 唯一允许改动的接缝（真正的 swap）

1. **pane 内容**：`GhosttyTerminalSurface{,_macOS}` 满足 `TerminalSurface` 协议。
   新增一个 `AgentChatSurface` 满足同一协议（或让 tiled host 的子视图在"agent 模式"下换成
   ACP 聊天视图）。tiled host 的**外壳**（标题栏、拖拽、zoom、布局）不动，只换里面填的东西。

2. **后端操作层**：`TerminalViewModel` 里发 tmux 命令的地方（`splitPane`、`newWindow`、
   `newSession`、break/join、`capture-pane`、`send-keys`）改为对 ACP 会话数据模型 +
   daemon 的操作。`TerminalViewModel` 的**集合与 @Published 形状不变**（windows/panes/
   sessionPanes/paneStates），这样所有绑定它的原版视图零改动继续工作。
   - session→window→pane 三层结构：原来由 tmux 提供，现在由本地/daemon 的 agent 会话存储提供。
     命名 session = 一组 agent；window/pane = 单个 agent 会话。
   - `TerminalTransport` / `swift-tmux`：退役；由 `acpkit` + daemon acphost 取代。

3. **状态检测**：`StateDetectionService` / `AgentStatusRules` 截屏规则 → ACP 回合生命周期
   （prompt 在飞 / 权限待答 / 回合结束）。`PaneState` 调色板与消费方不动。

## 复用（从 acp-native 分支搬底层，非 UI）

- `acpkit/`：ACP 客户端库（JSON-RPC/schema/ACPConnection/ProcessTransport），30 测试过。
- `desktop/internal/acphost/`：daemon agent 托管（spawn/attach/detach/list、X25519+ChaCha20
  加密、credit 流控、readfile），Go 测试过 + e2e 过。
- `bento-agent-core` 里纯协议/数据的部分（会话状态机、transcript 模型）可作参考，但**UI 一律以
  main 为准**，不从那边搬 UI。

## 执行顺序

1. Package.swift：`bento-terminal-core` 依赖里加 `acpkit`，去掉 `swift-tmux`（或先并存）。
2. 后端操作层：`TerminalViewModel` 的 tmux 操作逐个换成 ACP，保持 @Published 形状。
3. pane 内容：`AgentChatSurface` 实现 `TerminalSurface`，tiled host 换填充。
4. 状态：turn 生命周期喂 `paneStates`。
5. 逐屏截图对照 main 验收（docs 里 task #21）。

## 上下文说明

此计划在上下文接近上限时写就。执行需要在新 session 里带完整上下文做，避免半途耗尽再次留下半成品。
`acp-native`（旧分支）保留：其 acpkit/acphost/协议层是这条 v2 分支要复用的正确底层。

---

## 架构决策（2026-07-19，四路逐行映射后定稿）

映射报告全文见 session transcript；以下是执行依据的结论。

### 已完成的批次

- 2f3e2f9 acpkit 包搬入 + Package.swift 接线（24 测试绿）
- 95b0b34 desktop/ 整体搬 acp-native 端态（acphost+hostidentity+daemon 接线+doctor；
  Go 全绿）。sshserver/tmuxresolver 包仍在但已不被 daemon 引用，最终清理批删。
  注意：daemon relay StreamHandler 已切 acphost —— 过渡期终端 iOS 走 relay 会不通，可接受。

### D1. 视图零改动的根基 = 保留 SwiftTmux 值类型

发 tmux 命令的文件只有 3 个：`TerminalViewModel.swift`、`TerminalViewModel+Structure.swift`、
`PaneViewModel.swift` —— 这就是后端 swap 的全部 diff 面。其余文件（tiled host/sidebar/
tab bar/iOS wrapper/StateDetection）只依赖值类型 `TmuxPaneID`/`TmuxWindowID`/`TmuxWindow`/
`Pane`/`TmuxSessionMode`/`WindowDisplayStatus`/`MoveLanding`/`WindowSeed` + @Published 形状。
swift-tmux 保留为类型库（Types/LayoutTree），退役的只是 ControlMode/Command/Parsers 的使用。

### D2. mac pane 内容接缝 = 具体 API 模仿，不是协议 conformance

真实契约不是 `TerminalSurface` 协议（宿主从不用协议类型持有 pane 内容），而是
`GhosttyTiledPaneHost_macOS.swift` 使用的具体成员集（makeCell:218-235 构造 +
wireSurfaceCallbacks:239-319 接线 + PaneCell.surface:1987 类型）。
`PaneCellView.embed(_ view: NSView)`(:1445) 本来就收任意 NSView。

做法：新 `AgentChatSurface: NSView` 实现宿主用到的具体成员子集：
feed/applyTheme/teardown/scrollRows/scrollToLive/readScrollback/mouseReporting/
pathWrapCols/pathPreviewContext/reportedPwd/debugLabel + onInput/onSelect/onSplit/
onScrollbar/onSizeChanged/onVoicePrewarm/onVoiceStart/onVoiceDrag/onVoiceEnd。
tiled host 的 diff = makeCell 一行构造替换 + PaneCell.surface 类型。其余 1900 行原样编译。
**mac 右键长按语音在 surface 自己的 NSEvent 里** —— AgentChatSurface 必须移植
GhosttyTerminalSurface_macOS 的 rightMouse 手势逻辑（阈值/斜率一致），onVoice* 回调形状不变，
则 tiled host 的语音罗盘接线零改动。

### D3. iOS pane 内容接缝 = 换 VC，不改 TerminalContainerVC

TerminalContainerVC 与具体 surface 的选择/手势/滚动 API 深耦合（~40 成员）。正确接缝在
`TerminalWrapperView.swift` 的 `PaneContainerVC`（makeContainerVC:1057 + addChild 挂载
969-971/1051-1053）：agent pane 挂新的 AgentChatVC（保留 press-anywhere 语音、标题栏、
状态 tint 的等价交互），TerminalContainerVC 原样退休。

### D4. 结构模型：AgentWorkspaceStore 当 "tmux server"

- session⊃window⊃pane 三层 + 每 window cell 几何布局树：客户端 `AgentWorkspaceStore` 所有。
  pane/window ID 分配单调 Int（映射到 TmuxPaneID/TmuxWindowID），pane→daemon instanceID 映射
  存 store。布局 = tmux 语义的 split/kill/resize/swap 树运算，产出 Pane.x/y/width/height
  （虚拟 cell 格），tiled host 按比例渲染不变。
- 持久化：M1 先 UserDefaults（mac 单机可用），M2 给 acphost 加极小 statekv
  （setstate/getstate/statechanged 广播），结构随 daemon 走 → 重启/多设备同一棵树。
  agent 进程本身的持久化已由 acphost instance registry 提供。
- `updatePaneStates` 的产源换成每 pane 的 AgentSessionViewModel turn 生命周期
  （turnActive→working / pendingPermission→awaitingInput / 否则 idle）；
  doneUnseen 纯函数、counts、environment.onAwaitingTriggered/onSessionUpdate 全保留。
  StateDetectionService/AgentStatusRules 文件保留但不再被调用（Settings 的 Profile 编辑器
  UI 不动；promptBoundary/quickKeys 语义后续按 ACP 等价再接）。

### D5. 会话选择流的无损映射

- `.noTmux`（⌘⇧T "New Window (no tmux)"）→ in-process LocalAgentLauncher（agent 随 app 死）
  —— 与"无 tmux 无持久化"语义完全对应。
- `.createOrAttach(name)` → daemon 托管的命名 session group（attach 或 create）。
- `.createAgent(spec)` → AgentWizard 布局 spawn（spec.layout 张 pane 数）。
- `.shareWithDesktop` → 同 group attach。
- phase 机保留（.choosingSession 显示原 picker UI，列 daemon 的 session 组）。

### D6. 移植来源（从 acp-native 搬非 UI 文件进 bento-terminal-core/ACP/）

AgentSessionViewModel/TranscriptModels/AgentPreset/SessionActivityState +
Remote/{AcpHostClient,AcpRelayTransport,UnixSocketByteLink,RemoteAgentLauncher}。
不整包依赖 bento-agent-core（其内有与 main 冲突的 UI/主题/设置符号）。
chat 渲染 UI（MessageViews/ToolCallCard/DiffView/PlanCard/PermissionRequest）改造进
AgentChatSurface 内部，swift-markdown-ui 加为 bento-terminal-core 依赖。
mac 启动器用 AdaptiveMacLauncher 模式（acp.sock 在→daemon 托管；不在→in-process）。

### D7. 里程碑

- M1 mac 本地全链路：ACP 文件搬入 → AgentWorkspaceStore → TerminalViewModel 后端 swap →
  AgentChatSurface + makeCell 接缝 → 状态产源 swap → BentoMenubar 跑通目检。
- M2 持久化：statekv + syncWithHost + 重启/杀 app agent 存活 e2e。
- M3 iOS：AgentChatVC + relay sealed 通道 + 同一 store 逻辑。
- M4 退役 tmux/SSH 死代码 + 逐屏对照 main 验收（#21）。

### 开放问题（实现时决）

- 语音 ← 方向（NL→shell LLM）在无终端世界的语义：保手势，动作暂定"直接把原文发给 agent"，
  与 → 批量润色区分；实现 M1 语音接线时定。
- turn 导航 chevron 在 chat 里 = 跳上/下一个 user turn（PaneViewModel scroll-nav API 形状
  不变，内部改为 transcript 索引而非 regex 扫屏）。
