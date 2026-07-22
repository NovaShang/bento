# 差异审计存档 — 旧版(main) vs 错误重写版(acp-native)

四路 subagent 逐行取证的完整差异地图（2026-07-19）。**这是 v2 外科式 swap 的验收基准**：
下列每一项"旧版行为"都必须在 v2 保持不变。路径 OLD=main，NEW=acp-native 分支。
（NEW 列仅用于说明我当时改坏了什么；v2 从 main 出发，这些坏改动天然不存在。）

## A. mac shell / 菜单 / 窗口（最高优先级 = 用户第一眼看到）

- **activation policy（根因）**：OLD 在窗口打开时 `setActivationPolicy(.regular)`（Dock 图标+完整菜单栏出现），最后一个窗口关闭时 `.accessory`。文件 `GhosttyTerminalWindow_macOS.swift:117,123-125,148,157,177`。NEW 从未调用 → 无 Dock 图标、无菜单栏。**v2 保留原版即自动正确。**
- **主菜单 = "Shell" 菜单**（`BentoMenubarApp.swift:55`），条目与快捷键：⌘P Command Palette、⌥⌘P Toggle Preview Panel、⌘T New Terminal Window、⌘⇧T New Window(no tmux)、⌘D Split Vertically、⌘⇧D Split Horizontally、⌃⌘T New tmux Window、⌘] Select Next Pane、⌘[ Select Prev Pane、⌥⌘↑/↓ Swap Pane Up/Down、⌘⇧↩ Toggle Zoom、⌘1-9 Select Window N、⌘⇧R Fit Workspace、⌘W Close Pane、⌘⇧W Close Window。（NEW 把菜单改名 Agents、删了一半、加了 ⌘⇧L/⌘. 等——v2 全部保留原样。）
- **menubar 下拉**（`MenuContent.swift`）：状态头（Connected·N devices / relay offline / not running，图标 wifi/wifi.exclamationmark/xmark.circle）、daemon id 行、daemon-down 修复行、Pair new iPhone ⌘P、New agent workspace ⌘N（开 AgentWizardWindow）、New terminal(Ghostty) ⌘T、New SSH connection 子菜单（SSHHostsMenu，逐 ~/.ssh/config host）、Paired devices（`lock.iphone`，daemon down 时禁用）、**Workspaces section（SessionsMenuView：点击 attach + 每 workspace 的 Windows 子菜单 + Rename…/Kill workspace + 打开✓标记）**、Settings ⌘,、Getting started guide…、Refresh ⌘R、Quit ⌘Q。
- **menubar label**：仅图标；awaiting 数走 Dock badge（`MacAwaitingNotifier`），不是内联文字 badge。
- **原生 NSWindow tab 条**：`newWindowForTab`→`newSessionTab()`（`AppDelegate.swift:165-171`），tabbingMode 默认 automatic，Finder 风格 workspace tabs 在 `NSToolbar`（`GhosttyTerminalTabBar_macOS.swift`），右键 tab→sessionActionsMenu。
- **窗口 chrome**：styleMask 含 fullSizeContentView、`titleVisibility=.hidden`、`titlebarAppearsTransparent`、`titlebarSeparatorStyle=.none`、主题色背景、`setFrameAutosaveName("BentoMainTerminalWindow")`（记住位置/大小）、sidebar split autosave、fullscreen `.autoHideToolbar`（按 pref）。
- **生命周期**：applicationWillTerminate = flush 遥测 + SIGTERM daemon（注：v2 若沿用 daemon 托管持久会话，此处需按 acphost 语义改为不杀 daemon — 属"后端接缝"，允许改）；applicationDidBecomeActive 清 awaiting Dock badge；appearance 走 `NSApp.effectiveAppearance` KVO 实时跟随。
- **Preview dock**：trailing NSSplitViewItem 面板 + toolbar toggle + ⌥⌘P（`togglePreviewDock`）。
- 逐字节相同、未退化：`PairingWindow.swift`、`DevicesWindow.swift`（v2 保留即可）。

## B. workspace / window / pane 模型 + workspace 交互

- **三层结构**：命名 tmux SESSION ⊃ WINDOW ⊃ pane。`TerminalViewModel+Structure.swift`：结构读作 `.degenerate/.tiled/.list/.hierarchical`(:26-36)，`panesByWindow`(:154-161)。**v2 必须保留这三层**（后端从 tmux 换成 ACP 工作区存储，但形状不变）。
- **两模式** `TmuxSessionMode{tiled,list}`：模式是对真实结构的**读取**，非自由开关；切换 = 无损 break-pane/join-pane 变换（`spreadToList`/`mergeToTiled` :131-148,325-466）；`@bento_mode` 服务端持久；`.hierarchical` 读作 Tiled，展平到 List 需 `force:true` 并警告。默认 Tiled。切换 UI = 窗口工具栏 `NSSegmentedControl` "Parallel"/"Focus"，无快捷键。
- **新建流程两种子** `WindowSeed{duplicateCurrent, custom}`：sidebar footer "New Window" 菜单含 "Duplicate Current" 和 "Path & Command…"（`WindowSidebar.swift:218-256`）。
- **Duplicate Current**（用户明确点名"没了"）：三处入口 —— sidebar(:220-224)、tiled pane 菜单 "Split — Duplicate Current"(`GhosttyTiledPaneHost_macOS.swift:562-563)、List 模式 ⌃⌘T(:1189-1195)；解析逻辑 = 活动 pane 的 live cwd + 运行中程序，`resolveSeed`(`+Structure:274-298`)。
- **sidebar**（`WindowSidebar.swift`）：行首状态点（play/question/check/circle，`stateIcon:183-196`）、**名字按状态染色**(:157-176)、hover 追踪、**每行尾部 ✗ 关闭按钮**(:201-214)、右键菜单 = Move to Workspace 子菜单(+New Workspace…)、Close Window（确认对话框，文案"...processes...terminated"）。窗口**无 rename**（`+Structure:171` 明确"deliberately no rename"）。
- **tiled host**（`GhosttyTiledPaneHost_macOS.swift`）：镜像 tmux cell 几何；PaneTitleBar = 状态glyph+命令文本+跳转chevron+zoom+⋯菜单(:1513-1717)；单击聚焦+accent 边框；zoom(⌘⇧↩)；分屏 ⌘D/⌘⇧D + 种子分屏；cyclePane ⌘]/⌘[（window 内 panes）；swapPane ⌥⌘↑/↓；**拖拽 = VS Code drop zones**（`handlePaneDrag` + `PaneDropZoneOverlay`，center=swap/edge=dock，`PaneDropZone.swift`）；**分隔条拖动改大小**（`DividerOverlay`→resize-pane）；Move to Workspace 子菜单；pane 菜单 ~10 项；PaneStateTintView 状态色渐变冲洗 pane 体；**右键长按 pane = 语音**(:475-539)。

## C. 语音（交互锚点）

- **mac = 右键点住窗口任意处 + 径向罗盘**：`MacVoiceController_macOS.swift:66-104` + `VoiceCompassView`。方向：release/none=**发送**(insert+CR)、↑=send、→=re-transcribe→**可编辑预览条**(自己的 send/cancel)、↓=cancel、←=**NL→shell(LLM)** `voiceSwipeLeftLLM`。（我在 acp-native 已逐字恢复这套，可作 v2 参考。）
- **iOS = 长按终端表面任意处 + 径向罗盘**（`VoicePressGesture.swift`：180ms arm 阈值、6pt slop、finger-down prewarm、fling catch-touch veto；`TerminalContainerVC:799-953`；overlay `VoiceOverlayView` 定位在指尖）。方向语义同 mac（含 ←=NL→shell）。**NEW 退化成 mic 按钮 + 扁平提示行 + 丢了 ← —— v2 必须保留原版整套。**
- 方向分类器 `voiceDirection(forTranslation:)` 共享不变；haptics 三态。

## D. 设置（"简陋很多"确认）

- **mac = 5 tab**（General/Terminal/Voice/Relay/About），`SettingsView.swift` 349 行。控件全表见审计；非终端项**必须保留**：默认 workspace 名、语音→shell 的 LLM（toggle/key/model）、About tab、遥测"What gets counted"可展开列表。终端专属（字号/字体/主题/iTerm 导入/auto-hide toolbar）在 ACP 下按等价物处理或去除。
- **iOS = `Settings/SettingsView.swift` 537 行**，含完整 **State Detection Profiles 编辑器**（ProfileListView/ProfileEditView，增删改、regex 输出模式、quick keys、command pattern、reset）、Tap-to-Preview toggle、语音→shell 4 控件、Replay tips & gesture guide、About/Version、日本语言选项。
- 我加的、需撤销：Accent 颜色选择器、daemon ID 显示、Agents 说明。**注：用户后来单独要求了"mac 默认 system tint + 设置可选强调色全局生效"——这条是用户显式新增需求，v2 保留此 accent 功能，但其余我自作主张的加项撤销。**

## E. onboarding（"大幅降级"确认）

- **mac first-run = 5 步 664 行**（`FirstRunWindow.swift`）：welcome+ArchitectureDiagram+host/remote 讲解 → 后台服务checklist+agent检测+交互式安装器(copy/install/Node检查/Docs)+account讲解 → 工作区文件夹选择 → 语音步(mic 权限+手势讲解+状态色图例+zh→Qwen 提示) → 完成(第二 agent 卡+配对QR 1-2-3+menubar 讲解+**遥测同意 toggle**)。测试钩子 BENTO_FORCE_FIRST_RUN/FIRST_RUN_STEP/DETECT_PATH/OPEN_WINDOW。`AgentWizardWindow.swift` 196 行含 workspace名/目录/preset+自定义命令/**6-tile 布局网格**。
- **iOS onboarding**：`WelcomeFlowView`(3 主机路径：有 Mac/Linux-WSL/SSH) + `RelayPairView`(扫码/手动/**成功页**+友好错误分类+prefill 钩子) + `HowBentoWorksView`(架构图+4概念卡+状态图例卡+两视图概念+手势详解) + `GestureOnboardingOverlay`(首次终端手势教学，117 行)。

## F. iOS 交互（其余）

- 键盘配件条 `KeyboardAccessoryView`（Esc/Tab/Ctrl/Paste/箭头/标点/dismiss/compose 切换）+ 浮动 quick-keys 岛 `FloatingQuickKeysToolbar`（↑↓↵ Esc Tab Paste + Zoom + pane⋯）。**部分是真·终端专属**（Esc/Tab/Ctrl 原始 PTY），ACP 下 y/n 用权限按钮；但箭头+回车答 agent 提示需想清 ACP 等价。
- root = `HostListView`（SSH hosts + 配对 Mac 列表，永远先显示），tap host→`HostSessionsView`（tmux workspace 选择器）。add 菜单：Pair Mac / Add SSH host。swipe 删除。
- compose bar = 临时 inline liquid-glass 条（`VoiceInputController.ComposeBar`），双击终端唤出/右滑语音预览触发；键盘规避手动跟踪；escape 到 raw keyboard。
- 文件预览：**单击终端任意路径**→检测→浮动 chip→预览 sheet（`SmartPathResolver` 断行/截断路径重建）；detents medium/large。
- turn 导航：scroll-mark pager（右缘双 chevron，`TurnNavigator` 扫 promptBoundary regex）；bespoke 惯性 fling（CADisplayLink 120Hz）；**scroll-review-compose**（上滚时捕获按键进本地 draft，gap buffer+IME preedit）。
- 选择/复制：bespoke SelectionHandle（引擎几何）+ 自定义 Copy toast/haptic。

## 真·终端专属（ACP 下无意义，可不复现或用等价物）

预测回显、IME marked-text、终端字号/字体/主题/iTerm 导入、raw PTY 控制键(Esc/Tab/Ctrl/箭头/标点)、
scroll-review-compose 的"锁历史"、两指翻页、swap-pane/split-pane（agent 会话不可分屏）、
capture-pane 截屏状态规则、Fit Workspace to Window。
—— 但每一项都要判断"是否有 ACP 等价交互该保留"，而非直接删。
