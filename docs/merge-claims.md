# P6 认领台账（merge 时被「取 acp 版」让位的 term 改动）

> **为什么有这个文件**：P1 的 merge commit 落地后，term 分支的这批提交已进入祖先链，
> git **永远不会再把被丢弃的一侧摆到你面前**。P6 外壳认领时对着本清单逐条处理，
> 素材有两个来源：① 树内并存的文件对（`bento-terminal-core/` 里的 term 版 ↔
> `bento-core/` 里的 acp 版）；② 本 merge commit 的第二父提交：
> `git diff <merge>^1 <merge>^2 -- <path>` 可随时取回 term 侧原文。
>
> 纪律（用户 2026-07-28 定）：**所有 UI/UX 变化必须先向用户确认**；默认不改变
> 产品行为；不做向前兼容。

## 整文件取了 acp 版的（term 侧改动待认领）

| 文件 | term 侧被让位的内容 | 处置建议 |
|---|---|---|
| `BentoMenubar/Sources/App/BentoMenubarApp.swift` | pane 内查找 ⌘F/⌘G/⇧⌘G/⌘E（scoped 到活动 pane scrollback）；⌘T 语义重排（New tmux Window / New Session / no-tmux）；⌘0–9 选 window；"Track Session Size to This Window" ⇧⌘R；Split 菜单措辞 "Split Right (-h)"/"Split Down (-v)" | 查找四连是 B 外壳特性，认领进 Bento Term；⌘T 重排与 Split 措辞是 UI 变化 → **须用户确认** |
| `BentoMenubar/Sources/App/AppDelegate.swift` | `applicationShouldTerminate` 先标 `isTerminating` 再关窗（reopen 列表记录整组而非看着排空）；「tmux 客户端退出无须确认」设计注释；TmuxCLI kill-session 接线 | reopen 标记属于 P6 认领表「窗口尺寸/位置记忆·取 term」那行；其余归 B 外壳 |
| `BentoMenubar/Sources/Views/FirstRunWindow.swift` | 未逐条读（取了 acp 版） | P6 时 diff 并存对再认领 |
| `BentoMenubar/Sources/Views/MenuContent.swift` | 未逐条读（取了 acp 版） | 同上；注意菜单本来就是「谈判」项 |
| `BentoMenubar/Sources/Views/SettingsView.swift` | 未逐条读（取了 acp 版） | 同上 |
| `Bento/Sources/Views/HostList/WelcomeFlowView.swift` | 未逐条读（取了 acp 版） | 同上（iOS 欢迎流） |
| `docs/prd.md` | term 侧 7 处 PRD 演进未并入 | 文档谈判，随两产品文档拆分一起做 |

## 自动合并后被回退的（term 文案泄漏，非丢失——B 侧自留）

- `Bento/Sources/Views/Common/HowBentoWorksView.swift` — term 把 onboarding 概念图改成
  tmux 词汇（"Sessions persist"、`tmux ls`）。对 ACP 产品是事实错误；B 的 onboarding
  文案从 term 侧取。
- `Bento/Sources/Views/HostList/RelayPairView.swift` · `BentoMenubar/Sources/Views/PairingWindow.swift`
  — "workspaces"→"sessions" 文案回退（acp 的 Session→Workspace 改名是有意决策）。
  配对流其余逻辑两边一致。

## 保留了 term 版/合并版的（记录在案）

- `desktop/cmd/bento-daemon/daemon.go` — 并入 `BENTO_LOG_LEVEL` 调试开关（默认行为不变）。
- `docs/prd-mac-client.md` — term 的尺寸权威/handoff 演进保留（产品 B 文档）。
- `desktop/internal/relay/client.go` — 两边实现逐字节相同（serve-loop 卡死恢复各写了一遍），仅注释措辞取 acp。

## 直接删除的（不向前兼容，无认领）

- `desktop/internal/sshserver/` — SSH 传输在退役名单（BentoLink 接班）；term 分支继续
  维护自己的副本至 P7。

## 同一天双方重复实现清单（合并紧迫性的证据，非待办）

iPad 四方向声明 · iPad pane 标题状态语言 · iPad 分屏 chrome · iOS 浏览 pane 工作目录 ·
SIGUSR1 goroutine dump · relay serve-loop 卡死恢复
