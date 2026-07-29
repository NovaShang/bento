# BentoTmuxPane 施工图（P7 第 6 步，G）

2026-07-29。客户端侧把 daemon 的 tmux 虚拟 instance（docs/tmux-host-design.md）
拼成产品 B 的 pane。模块依赖：`BentoTerminalPane`（渲染）+ `BentoWorkbench`
（store/缝）+ `BentoLink`（传输）+ `BentoUI`/`BentoFoundation`。**不 import
ACP 任何东西**——这是"三种 pane 只在 L4 分化"的客户端兑现。

## 概念映射（与 prd-bento-term.md 对齐）

| Bento 词汇 | tmux 词汇 | 来源 |
|---|---|---|
| workspace（产品 B 语境仍叫 session） | tmux session | statekv `tmux/<target>/structure` |
| Parallel 视图 | 一个 tmux window 内全部 pane 平铺 | window layout 字符串 |
| Focus 视图 | break-pane 后逐 window 单显 | prd §2.4 |
| pane | tmux pane（虚拟 instance `tmux:<target>:%N`） | attach/credit/seq 原语 |

LayoutTree（分数树）在 B 模式下是 tmux layout 的**只读投影**：daemon 存
tmux 自己的 layout 语言，客户端翻译展示。绝不客户端存权威（缝二铁律）。

## TmuxPaneRuntime : PaneRuntime

映射验证过，协议成立、无需改缝：

- `phase`：attach 成功=ready；`exit` 控制帧=ended；重连沿用 store 既有阶梯
- `title`：`pane_title`（statekv 结构携带）；rename 走 structure 动词
- **`send(text)` = WritePane(text+CR)，`insertIntoComposer(text)` = WritePane(text)**
  ——正好是语音"插入 vs 发送"的终端版（send-keys 语义），routeInput 白拿
- `composerDraft` getter 恒 ""（终端无草稿箱）；`isTurnActive`/`isAwaitingUserInput`
  由 BentoTerminalPane 的输出解析状态规则喂（AgentStatusRules —— 状态语言
  "怎么知道"下沉进后端，调色板共享，正是 PaneState 90/525 分歧的设计答案）
- `firstUserPromptPreview` nil；`hasCompletedTurn` 由状态规则的 done 沿翻译

## DaemonAuthority : StructureAuthority

- `apply(verb)` → BentoLink 控制帧 `{"op":"structure","verb":{…}}`；
  ack `structureApplied{rev}` 只表示"读路径将在 rev≥N 显示"——UI 永远吃
  statekv 变更流，不做乐观本地改树
- 树流：statekv `statechanged` 订阅 → 快照解码 → WorkspaceEntry 投影
- resize：pane 尺寸走 `{"op":"resize"}`；会话级尺寸权威三策略（prd §2.5）
  是 daemon 侧 seam，客户端只发意图

## PaneModule 注册（缝一收口）

现状：`TiledPaneHost.makeCell` 仍硬编 `AgentChatSurface`。G 顺带把注册表落地：

```swift
public protocol PaneModule {
    var kind: PaneKind { get }
    var capabilities: PaneCapabilities { get }
    @MainActor func makeSurface(for pane: PaneID, in store: AgentWorkspaceStore,
                                theme: CanvasTheme) -> PaneSurfaceView
}
```

- `AcpPaneModule` 补上 surface 工厂（现有 AgentChatSurface 路径原样入表）
- `TmuxPaneModule` 产 TerminalPane surface（字节流双向接 attach 流）
- 外壳按产品注册：BentoMac 注册 acp；BentoTermMac 注册 tmux；
  A 未来加 pty pane = 注册第三个模块，外壳零改动（能力位开关 UI）

## 构建顺序

1. TmuxPaneModule + TmuxPaneRuntime + DaemonAuthority（可先对 fake link 单测）
2. makeCell 走注册表（A 行为回归红线：165+44 不动全绿）
3. 真 daemon live 冒烟：ensure→镜像→开 pane→键入→输出渲染→split 动词→布局更新
4. 交给 H（Term Mac 外壳装配，吃 docs/term-shell-port.md 的清单）
