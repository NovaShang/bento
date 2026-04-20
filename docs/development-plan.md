# SpeakTerm 开发计划

## Context

基于 `/Users/nova/code/speakterm/docs/prd.md` (v0.2)，这是一个全新的 iOS/iPadOS SSH terminal app。项目目录目前只有 PRD 文档，需要从零开始构建。本计划覆盖从技术选型到 TestFlight 发布的完整路径。

---

## 技术栈选型

| 领域 | 选择 | 理由 |
|------|------|------|
| **终端渲染** | SwiftTerm (fork) | 成熟的 iOS terminal engine，被 Secure Shellfish/La Terminal 等商业 app 使用。需 fork 以禁用内置手势、暴露 buffer 给状态机 |
| **SSH 网络** | Citadel (基于 SwiftNIO SSH) | 纯 Swift，async/await，Apple 密码学原语，比 NMSSH/libssh2 更现代 |
| **架构** | MVVM + Coordinator + Service Layer | 比 TCA 轻量，适合小团队 UI 密集型 app |
| **UI 框架** | UIKit (画布/终端) + SwiftUI (设置/主机列表) | 画布的手势消歧和 SwiftTerm 的 UIKit 特性决定核心用 UIKit |
| **语音识别** | SFSpeechRecognizer (MVP), 抽象为 SpeechEngine 协议 | 本地、免费、低延迟，协议抽象方便未来切 Whisper/SpeechAnalyzer |

## 架构总览

```
┌─────────────────────────────────────────────────┐
│              App / Coordinators                  │
├──────────────┬────────────────┬──────────────────┤
│ HostListView │  CanvasView    │  SettingsView     │
│ (SwiftUI)    │  (UIKit)       │  (SwiftUI)        │
├──────────────┴────────────────┴──────────────────┤
│                ViewModels                         │
│ HostListVM   CanvasVM   PaneVM[]   SettingsVM     │
├──────────────────────────────────────────────────┤
│               Service Layer                       │
│ SSHService          TmuxControlModeService        │
│ SpeechService       LLMService                    │
│ KeychainService     HapticService                 │
│ StateDetectionService   LiveActivityService       │
├──────────────────────────────────────────────────┤
│             External Libraries                    │
│ SwiftTerm (fork)    Citadel/SwiftNIO SSH          │
│ ActivityKit         Speech framework              │
└─────────────────────────────────────────────────┘
```

---

## 分阶段开发计划

### Phase 1: SSH 连接 + 单终端 (第 1-3 周)

> 最高风险技术验证：SSH + 终端渲染能否可靠工作

**开发内容：**
- `SSHService` — Citadel SSH 连接、PTY 分配、双向数据流
- `KeychainService` — iOS Keychain 存储 SSH 密钥（Face ID 保护）
- `HostListView` (SwiftUI) — 主机列表卡片、添加/编辑表单
- 单个全屏 `TerminalView` (SwiftTerm)
- `KeyboardAccessoryView` — 基础工具栏 (Esc/Tab/Ctrl/方向键)
- `Host` 模型 + 持久化 (SwiftData 或 JSON)

**关键文件：**
- `Services/SSHService.swift`
- `Services/KeychainService.swift`
- `Models/Host.swift`
- `Views/HostList/HostListView.swift`
- `Views/Terminal/TerminalContainerVC.swift`
- `Views/Terminal/KeyboardAccessoryView.swift`

**验收标准：**
- 可添加主机（用户名/密码或 SSH key）
- SSH key 存入 Keychain，Face ID 取出
- 连接后看到 shell prompt，可输入命令、看到输出
- 键盘工具栏正确发送 Ctrl-C、方向键、Esc、Tab
- 断开/重连正常工作
- 连接失败有清晰错误提示

---

### Phase 2: tmux Control Mode 集成 (第 4-6 周)

> 第二高风险：整个多 pane 画布依赖 tmux -CC 协议的正确解析

**开发内容：**
- `TmuxControlModeService` — 解析 `%begin/%end/%error` 响应块、`%output`/`%layout-change`/`%window-add` 等异步通知
- 远端 tmux 检测（无则提示安装）
- 创建/attach tmux session
- 输出路由：tmux pane → 对应 TerminalView
- 多 pane 模型：每个 tmux pane 一个 `PaneVM`
- 基础 split-window 支持
- Grouped session 创建（多设备 attach）

**关键文件：**
- `Services/TmuxControlModeService.swift` — 协议解析 + 命令发送
- `Models/TmuxNotification.swift` — 通知类型枚举
- `Models/Workspace.swift` — 对应 tmux session
- `Models/Pane.swift` — 对应 tmux pane
- `ViewModels/PaneVM.swift`
- `Services/TmuxCommandBuilder.swift`

**验收标准：**
- 连接时自动启动 `tmux -CC` 或 attach 已有 session
- 终端输出正确路由到对应 pane
- 可通过 UI 按钮创建分屏
- 各 pane 输入互不干扰
- Detach/reattach 保持 session 状态
- `%layout-change` 通知更新 pane 几何信息

---

### Phase 3: 画布多 Pane + 手势基础 (第 7-10 周)

> 核心创新的视觉载体：画布/视口模型 + 手势消歧系统

**开发内容：**
- `CanvasViewController` — UIKit 容器，管理视口变换
- 双指手势：`UIPinchGestureRecognizer` (缩放 20%-300%) + 双指 `UIPanGestureRecognizer` (平移)
- Pane 布局引擎：tmux layout 坐标 → canvas CGRect
- 活跃/非活跃 pane 视觉差异 (`CGAffineTransform` scale，不触发 tmux resize)
- Focus 模式（单 pane 全屏）
- 双击空白区 = 适应屏幕
- 单指滚动（覆盖 SwiftTerm 默认手势）
- 手势消歧：单指立刻拖动 = 滚动，快速点击 = 切换 pane
- Pane 标题栏 + 顶部状态栏

**关键文件：**
- `Views/Canvas/CanvasViewController.swift`
- `Views/Canvas/CanvasLayoutEngine.swift`
- `Views/Canvas/PaneContainerView.swift`
- `Views/Canvas/ViewportState.swift`
- `Views/Canvas/GestureCoordinator.swift` (关键)
- `ViewModels/CanvasVM.swift`

**验收标准：**
- 多 pane 按 tmux 布局正确渲染在画布上
- 双指捏合缩放画布（纯视觉缩放）
- 双指拖动平移画布
- 双击空白区适应屏幕
- 点击非活跃 pane 切换为活跃
- 活跃 pane 高亮 + 全尺寸，非活跃缩小 + 暗化
- Focus 模式进入/退出正常
- 单指拖动滚动 pane 历史（零延迟）

---

### Phase 4: 模式系统 + 语音输入 (第 11-14 周)

> 最具差异化的交互创新：微信式语音 + 方向手势。可与 Phase 5 并行。

**开发内容：**
- `InputMode` 枚举 (`.voice` / `.keyboard`) + per-host 持久化
- 模式切换：顶栏按钮、键盘弹起自动切换
- 语音模式手势识别器：按住 >200ms 不移动 → 触发录音
- `SpeechService` — `SFSpeechRecognizer` 封装，实时流式转写
- 语音浮层 UI：实时转写、四方向提示、方向高亮
- 方向检测：手指位移阈值判定
- 四种松开结果：仅注入(无方向) / 发送(上推) / LLM 转换(左右推) / 取消(下推)
- `HapticService` — 录音开始 light impact、方向越阈 selection、发送 success
- `LLMService` stub（Phase 6 完整实现）

**关键文件：**
- `Models/InputMode.swift`
- `Services/SpeechService.swift`
- `Services/HapticService.swift`
- `Views/Voice/VoiceOverlayView.swift`
- `Views/Voice/VoiceGestureRecognizer.swift` (关键)
- `Views/Canvas/ModeAwareGestureCoordinator.swift`

**验收标准：**
- 模式切换按钮正常工作
- 键盘弹起自动进入键盘模式
- 语音模式按住 pane >200ms 触发振动 + 录音
- 实时转写显示在浮层
- 方向滑动高亮对应提示
- 四种松开方向各自执行正确动作
- 滚动和录音不冲突
- per-host 模式偏好跨 session 持久化

---

### Phase 5: 三状态机 + Quick Keys (第 15-17 周)

> 可与 Phase 4 并行开发

**开发内容：**
- `StateDetectionService` — 监控 pane 终端 buffer
  - tmux silence 检测（无输出 > 阈值 = idle）
  - 输出正则匹配（最后 N 行匹配 `[y/N]`、`Continue?`、shell prompt 等）
  - Title / `pane_current_command` 匹配
- `PaneState` 枚举：`.working` / `.idle` / `.awaitingInput(profile:)`
- 内置 5 个 Profile：Claude Code / Codex / 通用 shell / vim / git interactive
- 状态视觉：working=默认 / idle=叠 5% 黑 / awaiting=琥珀色叠层
- `QuickKeysView` — pane 下方浮现快捷键按钮条
- Quick Keys 行为：点击发送按键后消失、状态变化时淡出
- 多 pane 同时 awaiting：活跃 pane 完整 Quick Keys，非活跃显示徽章

**关键文件：**
- `Services/StateDetectionService.swift` (关键)
- `Models/PaneState.swift`
- `Models/StateProfile.swift`
- `Models/BuiltInProfiles.swift`
- `Views/Canvas/QuickKeysView.swift`
- `Views/Canvas/PaneStateOverlayView.swift`

**验收标准：**
- 运行中命令 → working 状态（默认外观）
- 无输出超时 → idle（略暗）
- 出现 `[y/N]` 类 prompt → awaiting input（琥珀色）
- Quick Keys 在 awaiting pane 下方浮现
- 点击 Quick Key 发送按键后消失
- 状态转换响应 < 500ms
- Claude Code profile 正确检测确认 prompt
- 多 pane 可同时处于不同状态
- 状态颜色可在设置中自定义

---

### Phase 6: LLM 集成 + 文本选择 + 字体/主题 (第 18-20 周)

**开发内容：**
- `LLMService` 完整实现 — 用户自带 API key、pane 上下文 50 行、首次使用隐私告知
- 文本选择 — 双击选词、拖动手柄调整选区、浮出操作条（复制/全选）
- 字体系统 — 内置 SF Mono / JetBrains Mono / Fira Code / Menlo + Nerd Font 变体
- 主题系统 — 8 套内置主题 + iTerm2 `.itermcolors` 导入
- Settings 界面 (SwiftUI) — 字体/主题/状态颜色/振动/语音引擎/LLM 配置

**关键文件：**
- `Services/LLMService.swift`
- `Views/Terminal/TextSelectionHandler.swift`
- `Models/Theme.swift` + `BuiltInThemes.swift`
- `Services/ITermColorImporter.swift`
- `Views/Settings/SettingsView.swift`

**验收标准：**
- 语音左/右推 → LLM 返回 shell command → 注入 pane
- 首次 LLM 使用弹隐私告知
- 双击选词 + 手柄调整 + 复制到剪贴板
- 8 套主题正确渲染
- iTerm2 .itermcolors 可导入
- Nerd Font 图标正确显示

---

### Phase 7: Live Activity + Onboarding + 打磨 (第 21-23 周)

**开发内容：**
- `LiveActivityService` — ActivityKit 集成
  - 后台时 awaiting pane 显示在锁屏/灵动岛
  - 多 pane 合并显示
  - 点击直达对应 pane
- Widget Extension target
- Onboarding — 5 张可跳过的手势教学卡片（GIF/动画演示）
- 错误处理 UI — 连接失败/认证失败/网络错误
- 后台处理 — SSH keep-alive、前台恢复时重连 UI
- 性能优化 — 终端渲染帧率、大 scrollback 内存
- 无障碍 — VoiceOver labels

**关键文件：**
- `SpeakTermWidgets/LiveActivityView.swift` (新 target)
- `Services/LiveActivityService.swift`
- `Models/SpeakTermActivity.swift`
- `Views/Onboarding/OnboardingView.swift`

**验收标准：**
- 后台时 awaiting pane 在锁屏显示 Live Activity
- 灵动岛显示等待输入 pane 数
- 点击 Live Activity 直达对应 pane
- 首次启动显示 Onboarding，可跳过，Settings 可重看
- 连接错误有清晰 UI + 重试按钮
- 10000+ 行 scrollback 不 OOM

---

### Phase 8: TestFlight 准备 (第 24-26 周)

**开发内容：**
- 端到端集成测试
- 性能 profiling (Instruments)
- 边界情况加固（超长行、二进制输出、输出洪流、连接中断、tmux crash）
- App Store 素材准备
- TestFlight 分发

**验收标准：**
- iPhone + iPad 全部关键流程端到端通过
- 1 小时连续使用无 crash
- 终端渲染 60fps
- 内存稳定
- TestFlight build 分发给种子用户

---

## 依赖图

```
Phase 1 (SSH + 终端)
    │
    v
Phase 2 (tmux Control Mode)
    │
    v
Phase 3 (画布 + 手势)
   / \
  v   v
Phase 4          Phase 5
(语音输入)       (状态机 + Quick Keys)
  \   /              ← 可并行
   v v
Phase 6 (LLM + 选择 + 主题)
    │
    v
Phase 7 (Live Activity + Onboarding)
    │
    v
Phase 8 (TestFlight)
```

## 风险清单

| 风险 | 严重度 | 缓解措施 |
|------|--------|----------|
| tmux -CC 协议边界情况/文档不足 | 高 | 研究 iTerm2 开源的 tmux 集成代码；Phase 2 建立完善协议测试 |
| 手势消歧体验不对 | 高 | Phase 3-4 预留额外迭代时间；先隔离原型再集成 |
| SwiftTerm 手势冲突 | 中 | Fork SwiftTerm，禁用内置手势，通过 GestureCoordinator 统一管理 |
| Citadel 缺少某些密钥格式支持 | 中 | 早期测试 RSA/Ed25519/ECDSA；备选方案：降级到裸 SwiftNIO SSH |
| iOS 后台杀 SSH 连接 | 中 | 接受此限制（tmux 持久化是答案）；专注重连 UX |

## 总时间线

**单人开发约 26 周（6 个月）**。Phase 4 和 5 可并行，双人开发可缩短到约 23 周。
