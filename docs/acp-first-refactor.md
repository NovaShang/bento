# ACP-first 重构计划：根除 tmux、废除 window、pane 四类模型

2026-07-19。用户决策（本文档为执行依据）：

> 首先重构，把 tmux 部分彻底清理掉——**产品设计和实现两层**都要。terminal 部分不删除，但和活跃部分解耦，暂时不向用户暴露。先做一个体验好的 ACP 版本。session 概念和分屏功能保留，但内部实现与 tmux 不该有任何关系。为将来做多 pane 类型：**acp / terminal / file / browser 四种内部类型**。window 概念彻底去掉，Focus 模式切换的是 **pane**。

这解除了 v2 时代"视图零改动"的约束：AcpTmuxBridge/方言层的存在理由（伪装成 tmux 让旧视图不动）消失，整层拆除。

## 1. 目标架构

### 模型（中立命名，无任何 tmux 词汇）

```
PaneKind: .acp | .terminal | .file | .browser     // 现阶段仅 .acp 可由 UI 创建
PaneEntry { id, kind, presetID, customPreset, cwd, title,
            instanceID, acpSessionID, startCommand, ... }
SessionEntry { id, name, panes: [PaneEntry], layout: LayoutTree,
               activePaneID, zoomedPaneID?, cols, rows, lastActivity }
```

- **WindowEntry 消亡**。session 直接持有 panes + 一棵布局树。
- `LayoutTree` = 现 TmuxLayoutTree 的数学原样搬进 bento-terminal-core 并改名（splitting/swapping/neighbor/resizing/docking/tiledPreset 全保留），swift-tmux 包退出构建。
- 两模式（Tiled/List）的**结构变换机器整套报废**（break/join 重建、mode 推导、@bento_mode）：mode 降级为纯视图偏好——Tiled=布局树平铺，Focus=单 pane 全屏 + 切换；切换零结构变化、零丢失（因为根本不动结构）。zoom 保留为 Tiled 内的临时最大化。

### 数据流

```
AgentWorkspaceStore（唯一事实源：结构 + agent runtime + 持久化 + daemon statekv 同步）
        ↓ 直接观察（Combine/@Published，不再合成 tmux 通知）
WorkspaceViewModel（新建，干净的视图门面：panes/layout/activePaneID/paneStates/doneUnseen/sessions）
        ↓ 属性名尽量沿用旧 VM，最小化视图 diff
视图层（tiled host / sidebar / tab 条 / iOS wrapper——文件保留，仅换数据源与 window→pane 语义）
```

- TerminalViewModel（tmux 形状的 VM）、TerminalViewModel+Structure（方言刷新管线）、AcpTmuxBridge、TmuxCommanding **整体删除**。
- PaneState 管线：VM 直接读 store 的 AgentSessionViewModel turn 生命周期（pendingPermission→awaiting / turnActive→working / done-unseen 轴不变）。
- 快捷键语义重定向：⌘1-9/⌘]/⌘[ = 切 pane；⌘⇧L = 视图模式切换；iPhone 底部 tabs = panes；sidebar 行 = panes（状态灯保留）。

## 2. 阶段与提交批次（每级 BUILD+测试绿 → 单独 commit）

- **S1 模型层**：LayoutTree 搬家改名；PaneKind 落地；store 去 window（动词表：split/kill/select/rename/swap/dock/resize/zoom/tiledPreset 保留，newWindow/killWindow/selectWindow/renameWindow/moveWindow/breakPane/joinPane 删除）；持久化 schema v2 + 迁移（见 §3）；store 测试改写。
- **S2 mac 重定向**：WorkspaceViewModel 新建；tiled host / sidebar / tab 条 / 快捷键 / Focus 模式换语义；删 bridge/方言/旧 VM（mac 路径）；菜单去 tmux/SSH 词条。
- **S3 iOS 重定向**：TerminalWrapperView / SessionManager / 底部 tabs / Focus；删 TmuxLister 残留。
- **S4 封存与退役**：终端遗产解耦（切断活跃引用，移入 `Legacy/`，保持可编译，见 §4）；swift-tmux 退出全部 target；desktop `sshserver/`、`tmuxresolver/` 删除；菜单/文案/onboarding 里的 terminal 入口隐藏。
- **S5 验收**：持久化 e2e 脚本重跑（spawn/detach/attach/重启/跨端）；mac+iOS 冒烟；细节抠图继续。

## 3. 持久化迁移

- `acp_workspace_<daemonID>` 与 daemon statekv blob：schema 版本号 +1。
- 旧结构 windows 扁平化：全部 window 的 panes 按 window 顺序并入 session.panes；布局取 active window 的树，其余 panes 以 tiledPreset 重排并入。用户基数=本人+朋友，可接受的有损迁移。
- daemon 侧无需改动（statekv 是客户端定义的 blob）；版本不识别时以 daemon 实例对账重建结构（reconcileInstances 已有）。

## 4. 终端遗产封存标准（不删除、不暴露、不腐烂）

- 移入 `Legacy/` 目录（xcodegen glob 仍编译），**活跃代码零引用**；文件头注释标注封存原因与回归条件（hybrid 方案 P1 时启用为 kind=.terminal）。
- 封存名单（探查报告出来后定稿）：GhosttyTerminalSurface(+macOS)、GhosttyRuntime、LocalPty(_macOS)、LocalPtyTransport、SSHService/SSHKeyGenerator（iOS）、SSHConfigHosts、PredictiveEcho、ScrollReviewCompose、ScreenTitleStripper、AgentStatusRules、StateDetectionService、TerminalContainerVC 及终端专属交互（quick-keys 等）。
- 封存文件若 import SwiftTmux → 剥离该依赖或随 tmux 一起删（tmux 插桩≠终端渲染资产；只保后者）。
- swift-tmux 包：LayoutTree 数学搬走后整包退出构建（git 历史即归档）。

## 5. 风险与护栏

- **打磨回归**是主要风险（drag/dock、zoom、状态灯、语音手势都在被重定向的视图里）：视图文件只换数据源不重写；每阶段跑一次截图冒烟对照。
- 遥测事件、UserDefaults key、菜单文案里烙着 window/tmux 词汇的地方以探查报告为准逐一清理（对外语义改为 pane）。
- file/browser 两类只落 enum 与文档占位，不做实现；防止本次重构范围膨胀。

## 6. 执行进度

- **S1 完成（80c6c74）**：LayoutTree（Codable 树，含 tiledPreset/inserting）落地；store 去 window（session 直持 panes+一棵树）、PaneKind 四类、schema v2 + 旧 blob 扁平化迁移（测试覆盖）；bridge 缩成过渡 shim（每 session 一个伪 window @1，newWindow→newPane 最大格插入、join→dock/movePane、break/moveWindow 报错、options 惰性化）；新增 zoom 语义修正（选中隐藏 pane 自动退 zoom，tmux 行为）。核心测试 117+90 全绿。
- **S2 完成（3af01d9）**：mac 视图 pane 化——setMode=纯视图偏好（UserDefaults 每 session 记忆）；Focus=activePane 全屏走 zoom 通路；sidebar 行=panes（名字+状态灯+关闭+移动）；session 菜单 Windows 段→Panes 切换表（序号对齐 ⌘1-9）；⌘1-9 切 pane；跨会话移动塌缩成单一落点语义（占位 pane 清理），落点对话框删除。
- **S3 完成（41c91da）**：iPhone 底部 tabs=panes、溢出菜单 Windows 段删除、落点对话框删除；iPad sidebar 随 S2 共享文件已完成。
- **S4a 完成（e388fb6）**：Go 死包 sshserver/tmuxresolver 删除（-1700 行），daemon 构建+测试绿。
- **S4b 完成（40d1991 / ed57c71 / 47d9fc4）**：活跃代码与 tmux 零关系。WorkspaceTypes（PaneID/Pane/SessionViewMode）+ store 访问器；TerminalViewModel/PaneViewModel/+Structure/+Voice 全部直连 store（`workspace: AgentWorkspaceStore?`，nil=raw-shell 模式）；AcpTmuxBridge/TmuxCommanding/方言删除；swift-tmux 整包退出构建并 git rm（-3577 行）；测试重生为 WorkspaceStoreTests(18)+WorkspaceViewModelTests(3)，114+90 全绿双端 BUILD SUCCEEDED；验收 grep（SwiftTmux/TmuxCommand/TmuxParsers/TmuxControlMode/TmuxPaneID/AcpTmuxBridge）零匹配。已知取舍：PredictiveEcho 接线保留在 raw 路径、PaneViewModel 内部保留 TurnNavigator/Stripper（S4c 封存文件的编译依赖，chat pane 下 inert）、视图可见 API 名冻结（`resizeTmuxClient`/`activeTmuxSessionName`/`TmuxStartChoice` 等改名归 S4c）、iOS direct-SSH host 降级为"不支持"错误（HostListView 未收口）、movePane 建新会话仍 spawn-再-kill 一个占位 agent。
- **S4c 未做**：终端遗产入 Legacy/、menubar TmuxCLI/AgentWizard 外部终端路径清理、iOS HostListView SSH 入口收口、`Tmux*` 残名与文案扫尾、遥测复查。
- **S5 未做**：e2e 重跑 + 双端冒烟 + 逐屏验收。
- 并行说明：另一 session 在同一 worktree 推进 ACP 客户端 UX（docs/acp-client-ux.md、composer 能力条 f1140f7…）；两边按文件 stage，互不回滚。

## 7. 与既有文档的关系

- `hybrid-workbench-design.md` 仍是产品终态（terminal pane 将来以 kind=.terminal 回归，daemon pty 实例、vt 网格、JSONL 投影不变）；本重构是其前置地基 + "ACP 先行"的排序决定。
- `acp-swap-plan.md` 的 M4 清单由本计划取代。
