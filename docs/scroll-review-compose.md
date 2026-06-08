# Scroll-Review Compose（滚动草稿）

> 状态：设计稿（待实现）。本文档是方案讨论的收敛结果，实现另起。

## 1. 动机

在 inline-render 类 TUI（Claude Code、aider、shell REPL）里往上滚看历史时，无法同时在底部输入框打字：

- 多数终端默认 **scroll-on-keystroke** —— 一打字视图就弹回底部，打断阅读；
- 就算压住不弹回，输入行在活动屏底部、被滚走，看不见自己打了啥。

本质是**显示问题**，不是输入路由问题（滚动时按键其实一直在进 pty）。目标：滚历史时给一个临时草稿框，边读边打，提交时把内容送进 tty。

## 2. 方案选型：为什么是 A（本地草稿）而非 B（实时镜像）

两条路线：

- **A 本地草稿框**：滚上去时按键进我们自己的框，攒着，提交时注入 app。
- **B 实时镜像**：把 app 活动输入区实时镜像、钉在底部。

否决 B 的**结构性原因**：要定位输入框，B 需要**光标位置**，而 libghostty 不暴露光标坐标（header 里只有 selection 的像素框，无 cursor query API）。一旦 TUI 把输入框放在非底部（中间/下方压着 footer 或补全菜单），B 就抓瞎。

A 天生**不需要知道 app 输入框在哪**（用自己的框），并顺带绕过多个难题，见下表：

| | B（镜像） | A（草稿+注入） |
|---|---|---|
| 要不要知道输入框位置 | 要光标坐标（拿不到） | 不要，用自己的框 |
| scroll-on-keystroke snap | 必须压住（风险闸） | 不存在——草稿期不喂 app，啥都不 snap |
| 改 libghostty | 彩色保真才要 | 完全不用 |
| 盲打丢补全 | 不丢 | 只在读历史时丢，提交时交还现场补回来 |

A 的「盲打丢补全」缺点，由**提交=注入到真实输入行+交还现场**化解：盲打只发生在你忙着读历史时，最终补全/提交在 app 真实输入框里完成。

## 3. libghostty 能力实测（可行性闸）

基于 `build/install/.../include/ghostty.h` + 现有 Swift 调用：

- ✅ **读活动屏任意区域**：`ghostty_surface_read_text(surface, selection, &text)`（header:1065）接受任意 `ghostty_selection_s`，point tag 含 `GHOSTTY_POINT_ACTIVE` + coord `EXACT`。返回纯 UTF-8（无颜色/属性）。
- ✅ **滚动状态**：`GHOSTTY_ACTION_SCROLLBAR`（header:818）带 `{total, offset, len}`（header:789），经 `action_cb` 投递。**当前 `action_cb` 是空桩**（`GhosttyRuntime.swift:53` = `{ _, _, _ in true }`），需实现。`total>len` 即说明有 scrollback。
- ✅ **alt-screen 免检测**：全屏 alt-screen 应用无 scrollback（`total==len`，滚不上去），mouse-tracking 应用吃掉滚轮 —— 本特性天然不触发。
- ✅ **注入**：`ghostty_surface_text(surface, bytes, len)`（header:1032）。
- ❌ 光标坐标、彩色保真镜像：不暴露（B 才需要）。

结论：A 在现成预编译 libghostty 上可行，不碰 Zig、不重编 ghostty。

## 4. 交互设计

### 4.1 已定决策

- **D1 Enter = 注入不执行**：文字落进 app 真实输入行、光标停在那、snap 到底，可用补全/改字/再回车跑。`Cmd/Ctrl+Enter` = 注入并执行（追加 CR，复用 commit `8545ef7` 的 iOS 软键盘 Enter→CR 逻辑）。
- **D2 控制键直通 app**：Ctrl-C/Ctrl-D/Ctrl-Z 等不进草稿，直发 app —— 滚着历史也能打断进程。只有这类显式信号才会 snap，符合预期，顺带避开 scroll-on-keystroke 风险。
- **D3 滚上去即显低调提示条**（`⌨ 打字会暂存为草稿`），首次打字展开成框。
- **D4 v1 最小**：单行为主 + 退格 + ←→ + Shift+Enter 多行。不做 Ctrl-A/E、词跳、历史等。

### 4.2 状态机

```
        ┌──────────────────────────────────────────────┐
        │                                               │
        ▼          scroll up (offset≠bottom)            │
   ┌─────────┐ ───────────────────────────────► ┌──────────────┐
   │  LIVE   │                                   │ REVIEW_IDLE  │
   │ 直通    │ ◄─────────────────────────────── │ 滚上去/空草稿 │
   └─────────┘  scroll to bottom / Esc-when-empty└──────────────┘
        ▲                                          │   ▲
        │                                  第一次打字 │   │ 草稿删空
        │  commit(inject)+snap                       ▼   │
        │                                      ┌──────────────┐
        └───────────────────────────────────  │ REVIEW_DRAFT │
              Enter / scroll-to-bottom         │ 滚上去/有草稿 │
                                          Esc→ └──────────────┘
                                       (丢弃草稿,回 IDLE)
```

- **LIVE**：在底部，按键直通 pty（现状），无框。
- **REVIEW_IDLE**：滚上去、草稿为空，底部显低调提示条。
- **REVIEW_DRAFT**：草稿有内容，提示条展开成草稿框。

### 4.3 转移表

| 当前 | 事件 | 行为 | 去向 |
|---|---|---|---|
| LIVE | 向上滚（offset≠底） | 显示提示条 | REVIEW_IDLE |
| REVIEW_IDLE | 打印字符 | 进草稿，展开框 | REVIEW_DRAFT |
| REVIEW_IDLE | Enter | 仅 snap 到底（无内容可注入） | LIVE |
| REVIEW_IDLE | Esc / 滚到底 | 收起提示条 | LIVE |
| REVIEW_DRAFT | 打印/退格/←→ | 编辑草稿 | REVIEW_DRAFT |
| REVIEW_DRAFT | 草稿删空 | 收回提示条 | REVIEW_IDLE |
| REVIEW_DRAFT | **Enter** | **注入草稿到真实输入行（不执行）+ snap 到底 + 焦点交还** | LIVE |
| REVIEW_DRAFT | **Cmd/Ctrl+Enter** | 注入 + 追加 CR（执行）+ snap | LIVE |
| REVIEW_DRAFT | **滚到底** | 注入 + 交还（人已到 prompt，无缝） | LIVE |
| REVIEW_DRAFT | Esc | 丢弃草稿 | REVIEW_IDLE |

### 4.4 按键路由（仅 REVIEW_* 生效）

原则：**只截「文本和编辑键」，其余一律放行给 app。**

| 键 | 处理 |
|---|---|
| 可打印字符 / 粘贴 | → 草稿 |
| Backspace / Delete / ←→ | → 编辑草稿 caret |
| ↑↓ / PageUp·Down / 滚轮 / 触控板 | → 滚历史（不碰草稿） |
| Shift+Enter | → 草稿内插入换行 |
| Enter / Cmd·Ctrl+Enter / Esc | → 见转移表 |
| 控制键（Ctrl-C/D/Z 等信号） | → **直通 app** |

## 5. 实现落点（全在 Bento 侧，不碰 libghostty）

1. **`GhosttyRuntime.swift:53`** 空桩 `action_cb` → 实现，收 `GHOSTTY_ACTION_SCROLLBAR`，驱动 LIVE↔REVIEW 切换与 offset 判定。
2. **按键转发路径**（现调 `surface_key`/`surface_text` 处）→ 加 gate，REVIEW 态按 §4.4 分流。
3. **草稿框 UI** → SwiftUI overlay，钉在 pane viewport 底部（iOS 贴软键盘上方），挂 pane host 层。
4. **注入** → 复用现有 `ghostty_surface_text` 调用点。

## 6. 待验证 / 风险

- **视图锚定**：草稿期间 app 可能仍往 scrollback 吐输出（后台命令完成、流式）。hold 的滚动位置**不能用数字 offset**，要**锚到一条 scrollback 内容行**，否则底部新增内容会把视图顶走。体验成败关键。
- **多行注入 / bracketed paste**：查不到 app 是否开启 bracketed paste mode（无 mode query）。v1 先直接 `surface_text` 交 libghostty 编码，多行场景实测。
- **注入点已有内容**：`surface_text` 在 app 当前光标处插入，若真实框已有半截文字会拼接——通常 OK，记为边界。

## 7. 后续（非 v1）

- 彩色保真镜像（B 路线）——需给 libghostty 加 cursor/region 渲染能力。
- 完整 readline 编辑键（Ctrl-A/E、词跳、Ctrl-W、历史）。
- 草稿跨 pane / 跨 session 持久化。
