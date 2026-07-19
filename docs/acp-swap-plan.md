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
