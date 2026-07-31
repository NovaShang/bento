# Term 还原欠账台账

> **为什么有这个文件**：把 Bento Term 从 daemon 上摘下来时，`TmuxSessionLink` /
> `TmuxAuthority` / `ControlModeTmuxTransport` / iOS `TmuxShell` 是**对着协议重写的**，
> 不是从 `../bento-term` 逐段移植的。结构对了，但旧版几个月调出来的行为大量丢失。
>
> 这些行为的知识只存在于旧代码的注释里——每一条都是一次线上事故的墓志铭。重写时
> 代码的**形状**保住了，**为什么是这个形状**扔了。这份台账把它们钉下来，免得下一个
> 人重新审计一遍。
>
> 同 `merge-claims.md` 的用意：git 永远不会再把被丢弃的一侧摆到你面前。

**旧代码 = `/Users/nova/code/bento-term/bento-terminal-core/Sources/BentoTerminalCore/`**
（`TerminalViewModel.swift` = TVM，`TerminalViewModel+Structure.swift` = TVM+S）

**状态图例**：`MISSING` 完全没有 · `PARTIAL` 有形无实 · `FIXED` 已补 · `WONTFIX` 有意不要（附理由）

---

## 结论：这不是补丁能收的

`applyTiled` 的重试算法、`refreshPanes` 的竞态防护、通知总序队列、尺寸权威三件套——
**它们本身就是旧代码里的那几段函数**，不是"加个 if"。正确的工作单元是把 TVM 的
tmux 那一半整段搬进新结构。这份台账是那次移植的验收清单。

---

## 一、会造成可见损坏（结构 / 布局）

| # | 行为 | 旧位置 | 为什么 | 状态 |
|---|---|---|---|---|
| 1 | `applyTiled` 每次 `join-pane` 后重新 tile，失败重试一次；装不下的 pane 留在自己窗口，`prev` 不前进到它 | TVM+S:521-553, 587-607 | `join-pane -t prev` 把目标**劈一半**；naive 链条让目标几何级缩小（½ ¼ ⅛…），5–6 个之后低于 tmux 最小 pane 尺寸 → 被拒 → pane 搁浅。**那个"~5 个 Parallel 上限"就是这么来的，不是设备尺寸限制** | `MISSING` — `TmuxAuthority.translateApplyTiled` 只在最后发一次 `select-layout`；且 `perform` 首错即 `break`，连最后那次布局都不执行 |
| 2 | `%layout-change` **从通知自带的 layout 字符串同步应用几何**；防抖的 `list-panes` 只补 layout 字符串说不了的部分 | TVM:780-797, `applyLayoutGeometry` TVM:984-1003 | tmux 在**同一条有序流**里先发 `%layout-change` 再发程序重绘的 `%output`。防抖 300ms 那版让 surface 还是旧尺寸时重绘就到了 → 重绘按旧网格折行 → **一直花屏到下次 resize** | `MISSING` — 新代码走 `scheduleRefresh(immediate:true)`，异步 + 3 次往返，layout 字符串被丢弃。`TmuxParsers.parsePaneGeometry` 现在是**死代码**（它自己的文档还写着"每次 %layout-change 都跑"） |
| 3 | `list-panes` 解析为空**或行数不足**时拒绝应用，250ms 后重取 | TVM:890-946 | *"空解析永远不是真状态——快速输入下 list-panes 的响应会和 %output 交错。应用空结果会清空 paneViewModels，**拆掉每一个 ghostty surface**（黑屏 + 响应链断 → 每次按键只响铃）。行数不足意味着响应体被 %output 插入过，会静默丢 pane，同样按空处理"* | `MISSING` — 只判 `isError` |
| 4 | `list-windows` 同样的防护，独立的 300ms 重取令牌 | TVM:948-977 | *"重负载下（例如 select-window 之后那阵重绘）命令响应会和 %output 交错。应用部分列表会缩短 windows，例如让手机的窗口标签栏消失"* | `MISSING` |
| 5 | 两个列举指向**同一个** session | TVM:894, TVM:949（都不带 `-t`，即客户端当前 session） | 隐含前提：一个客户端一个当前 session | `PARTIAL/发散` — `listWindows()` 用当前 session，`listPanes(target: sessionName)` 用**缓存名**。一旦不一致 → `buildSnapshot` 按 `window_id` 配对全落空 → **每个 window 零 pane → 全部 surface 拆除** |
| 6 | `%session-renamed` 只当**标签**用，不改变本客户端的目标 | TVM:826-827 | 旧解析器只产出裸名形式；名字从不作为列举目标 | `MISSING（回归）` — 新代码忽略通知里的 session id，直接 `sessionName = name`。而 `sessionName` 现在是 `list-panes -t` 的目标 → **服务器上任意 session 改名都会让本客户端渲染并操作错误的 session** |
| 7 | `capture-pane` 结果喂给 surface 前先 `stripControlModeChatter` | TVM:862-888，用于 TVM:1124, 1693 | *"否则把协议原文画进 pane —— `%output %5 \033[…`、`%begin/%end`、`%layout-change …`（BUG-007，iOS 居多）"* | `MISSING` — `modules/` 里没有任何实现 |
| 8 | 非当前 session 也要能被探查结构（跨 session 移动用） | TVM+S:976-995, 958-962 | *"目标 session 的形状，服务器侧探查（我们没挂在它上面，但命令能到任何 session）"*；新建 session 的占位 shell 窗口要用 `kill-window "name:^"` 清掉 | `MISSING（效果上）` — `refreshStructure` 给非当前 session 发空结构，而三个消费者都要它 → 跨 session 移动**永远新开窗口**、占位窗口**永远留着** |
| 9 | `list-sessions` 输出只认 `$` 开头的行 | TVM:580-588 | *"不是 `$id:…` 的都是通道噪声（已观测到 pane 输出混进响应里），不是 session"* | `MISSING` — 而 `translateKillSession` 会拿噪声行当 survivor 去 `switch-client` |
| 10 | 通知在主 actor 上保持**总序**，空队列时 `%output` 完全不上主线程，同 pane 连续 `%output` 合并 | TVM:315-348, 350-376 | *"保持总序（`%layout-change` 必须排在其后的 `%output` 之前，resize 正确性依赖它），同时合并突发以免每条都付一次主 actor 跳转"* | `MISSING` — 一条通知一个裸 `Task`。**总序保证没了**（同优先级 FIFO 是当前运行时的实现细节，不是承诺），突发合并没了，每个 `%output` 都付主线程跳转 |
| 11 | 结构刷新的防抖用**一个共享令牌**，取消再武装；并发刷新去重 | TVM:792-797, 929-935, 563-567 | *"并发刷新会在控制通道上堆叠 list-sessions —— 已有一个在飞时丢掉重复的"* | `PARTIAL` — 防抖在，但 `immediate:true` 取消防抖后发一个**不被追踪、不去重**的 Task；`refreshStructure` **没有 in-flight 保护**。拖拽 resize 时 `%layout-change` 连发 → N 个并发刷新 × 3 条命令 → 命令通道洪泛，正好喂大第 3 条 |
| 12 | `inActiveWindow` 从每条 pane 行**自己的** `#{window_active}` 读 | TVM:903-905 | *"当前窗口的 pane 用每行自己的 window_active 标志——不依赖单独刷新的（可能过期的）window 状态"* | `MISSING` — `buildSnapshot` 丢弃 `Pane.inActiveWindow`，改从 window 列举重建，还有个"没人声明就认 `[0]`"的兜底 → 可能选错窗口 → **可见 pane 集合错** |
| 13 | `%pane-mode-changed` 立刻重列 pane 以取到 `pane_in_mode` | TVM:829-840 | *"通知只带 pane id 不带模式，所以要重列。否则 copy-mode 徽章要等 2 秒轮询，久到 pane 看起来像坏了（滚动没反应，也没解释）"* | `PARTIAL` — 刷新了结构，但结构快照**故意不带**交互标志（它们走 `tmuxpanes` 轮询）→ 刷新的东西承载不了答案 |

## 二、连接生命周期 / 尺寸

| # | 行为 | 旧位置 | 为什么 | 状态 |
|---|---|---|---|---|
| 14 | **只有 session 的创建者才能强加自己的尺寸** | TVM:745 | *"只在我们创建了一个全新的独立 session 时才 resize tmux 客户端视口，因为缩小一个共享 session 会连带缩小桌面端的视图"* | `FIXED` — `TmuxSessionLink.SizeClaim`，默认 `adoptExisting`；**加入别人的 session 走 grouped session（`-t`）**，各自独立尺寸，这才是旧版支持多连接的方式（TVM:664 `shareWithDesktop`） |
| 15 | **iOS 掉线后重连** | TVM:1714, 1752, 1766 | *"relay/daemon 抖动可能超过任何固定预算，它留下的尸体屏就是用户实际经历的『reconnecting 卡住』"* | `MISSING` — iOS `TmuxShell` 从不设 `onConnectionStateChanged`；且 `SSHService` 把通道死亡报成 `.failed`，Mac 那个处理器只认 `.disconnected`。**一个丢包 = 死了但看起来活着** |
| 16 | iOS 声明设备真实网格 | TVM:745-750, 1444 | 同 14 的另一半 | `MISSING` — iOS 硬编码 `cols:80, rows:24`，整个 iOS 侧无任何 `refreshClient` 调用点 |
| 17 | 挂上时**采纳服务器的**尺寸策略（`adoptSizingPolicy`） | TVM+S:663 ← TVM:1481 ← TVM:762 | *"旧的 restoreSizingMode 把本机偏好重新强加给服务器，于是谁最后挂上谁赢——一台在重连循环里的 iPad 每 ~50 秒覆盖一次 Mac 的选择"* | `MISSING` — `refreshStructure` **从不填 `TmuxStructureState.sizing`**，所以 `adoptSizing` 永远在 `guard let sizing` 处返回，整套是死代码 |
| 18 | pin 之后只有 `resize-window` 有效 | TVM+S:744, 703, 736; TVM:1456, 1501 | *"`manual` 下只有 owner 说话，走 resize-window；`refresh-client -C` 在那里被 tmux 忽略，这就是旧的一次性『fit』静默失效的原因"* | `MISSING` — 新 `declare()` 只发 `refresh-client` |
| 19 | owner 离开时释放尺寸归属 | TVM+S:766 | *"把 session 放回 latest，免得剩下的设备被钳死在一台已经不在的设备上。这正是归属要用 tmux 客户端名做键的全部理由：无心跳、无轮询、无法泄漏 owner"* | `MISSING` — 手机 pin 了走人 = Mac **永久**被钳死，且 UI 上看不出来 |
| 20 | 用户离开 session 时拆掉 link | TVM:1512 | *"由 disconnect/删除主机置真，免得去救一个用户明确拆掉的 session"* | `MISSING` — iOS `links`/`stores`/`authorities` **从不移除**。幽灵客户端继续参与尺寸选举 |
| 21 | 前台恢复先探活再重挂 | TVM:1536, 1568 | *"socket 通常能活过后台挂起……在这里拆掉一个健康连接，是『每次解锁都重连、明明什么事都没有』的主因"* | `PARTIAL` — `probeLiveness()` **零调用者**；`SessionManager` 的 30 秒宽限机制通向空操作 |
| 22 | 双超时跳闸（`noteCommandTimeout`） | TVM:1795, 897 | *"传输可以以任何层都不上报的方式半死：WS 还应 ping 但远端 shell 没了，tmux 永不回复，屏幕冻在那儿显示『已连接』。连续两次超时（~25s）是通用的绊线"* | `MISSING` — 每个调用点把 `isError`（超时就是它）当"安静返回" |
| 23 | 重连中途失败不得报成功（`failedDuringReattach`） | TVM:268-276, 1671 | *"reattach 末尾那阵播种正是 iPad 上 relay socket 真正死掉的地方，因为 isReconnecting 还是 true，没人发现，直到 ~48s 后看门狗才响——然后下一次尝试同样死法，无限循环"* | `MISSING` — 且 `LocalPtyTransport.connect` 无条件置 `.connected` 从不抛错，`start()` 基本不可能失败。退避状态还是每次调用的局部变量 → 瞬间失败的主机会**永远以 ~0.5s 重试** |
| 24 | 可见的"Reconnecting…"状态 | TVM:71 | *"驱动一个『Reconnecting…』横幅，让 UI 永远不会静默冻住"* | `MISSING`（产品 B）— 只剩日志一行 |
| 25 | 重挂前停掉轮询 | TVM:1630-1648 | *"list-panes 一直打进半建成的连接——在 tmux -CC 起来前被敲进裸 shell，每个孤儿续体排在新 session 真正的响应前面（错位 N、超时风暴、看门狗重连循环）"* | `PARTIAL` — 协议半边在（greeting 闩 + `control.reset()`），但轮询没停，且 `disconnect()` 在死亡路径上**从不被调用** |
| 26 | 重连后逐窗口重新声明视口 | TVM:1419-1427 | *"在传输连上之前触发的 resize 会丢失……让远端 PTY 的宽度和渲染的不一致"* | `PARTIAL` — `TermSessionHost` 只重放 `lastViewport`（跨所有窗口 last-writer-wins）。`ViewportDeclarationGate.invalidate()` 正是为此存在，**零调用者** |
| 27 | `%exit` 结束会话 | TVM:845-848 | — | `PARTIAL` — 只置 `connected = false`，不通知任何人。macOS 上 pty 退出 → 重连 → `new-session -A` → **静默复活一个同名空 session** 而不是结束窗口 |
| 28 | 列举 session 前先解锁 Mac 钥匙串 | TVM:509-511, 1403 | *"先解锁再列举，让下一条命令看到一个稳定的 shell"* | `MISSING` — `Host.unlockMacKeychain` 和 iOS 开关都还在，**没有任何东西执行它** |

## 三、pane I/O 与状态检测

三份里最严重的一份。**注意 33、34、35 是我新造的回归，不是"没搬过来"。**

| # | 行为 | 旧位置 | 为什么 | 状态 |
|---|---|---|---|---|
| 29 | 控制客户端掉线后，surface 重新绑到活的 runtime 并重新播种一屏 | TVM:1611-1618, 1684-1705, 1646-1648 | *"否则它们还连在被丢弃的 PaneViewModel 上，而实时 %output 落进新的、没有 surface 的实例里（历史在涨但什么都不画，『重连后看着像死了』那个 bug）"*；*"tmux 不会为新控制客户端重绘静态内容"* | `MISSING` — `handleLinkClosed` 建**新** link，但所有 `ControlModeTmuxTransport` 的 `weak var link` 指着死的那个；幸存 pane 从不重新订阅，也没人重新播种。**掉线后每个 pane 永久死掉：收不到输出，按键静默丢弃**，而重连路径看起来是成功的 |
| 30 | capture 播种前把 `\n` 转成 `\r\n` | TVM:1130, 1696 | `capture-pane -p -J` 只出 LF，而 `ControlMode` 用 `"\n"` 拼响应行 | `MISSING` — 新树里零命中。**每次播种都渲染成阶梯**（每行按上一行长度缩进），首次打开和每次窗口切换都必现 |
| 31 | 播种失败/为空重试 3 次 | TVM:1122-1129 | *"capture-pane 会和 select-window 的 %output 突发竞速……丢失的播种让新 surface 一直空白，直到 TUI 碰巧重绘某个区域——就是窗口切换时那个『白屏，只有变动的部分显示』"* | `MISSING` — 只试一次 |
| 32 | 每个新建的 PaneViewModel 都播种 | TVM:1054-1058, 1104-1163（对所有 `newPaneIDs` 无条件） | 同上 | `PARTIAL/理由已过期` — `PaneViewModel:155` 用 `if runtime.updateSeq > 0` 卡住，理由写着*"daemon 会重放它自己 capture-pane 打开的日志"*——**daemon 没了**，`ControlModeTmuxTransport` 回的是 `replay:false, headSeq:0`，什么都不重放。和 #3 复合：竞态解析拆掉 runtime → 重生的 runtime `updateSeq == 0` → **永远空白** |
| 33 | `%output` 走解析队列直达 surface，**完全不碰主线程** | TVM:306-336, PaneViewModel:64-82 | *"快路径：已绑定 pane 的 %output，队列空且无待排空时，不可能越过任何东西……就在这个队列上投递，完全跳过主线程"*；*"主线程每次按键会冻 ~19ms（输入法 IPC），把回显路由过去就让它们排在产生自己的那次按键后面"* | `MISSING（最大的一处倒转）` — 每条通知一个 `Task { @MainActor }`，再经 `ControlModeTmuxTransport` **第二次**跳主 actor。解析队列还在、注释还在，但**没有任何东西在它上面跑过 `feedData`**。原来零跳转，现在每块两跳 |
| 34 | 按键写入不重回主 actor | PaneViewModel:107-110 → `sendData`（加锁入队 + 独立冲刷队列） | 我自己代码里的注释（`TmuxPaneRuntime:383-386`）写着*"输入合并器的冲刷队列调它，这样按键突发不用跳回主 actor 才能上线……因为它的 write 是同步的、加锁的入队"* | `MISSING —— 这句注释是假的` — `ControlModeTmuxTransport:66` 是 `Task { @MainActor in ... }`。每次按键跳主 actor，正好排在 #33 那股输出后面 |
| 35 | 检测工作不上逐块热路径 | StateDetectionService:60-75 | *"recordOutput 跑在输出热路径上（每个 pane 的每一块），所以它不能做任何字符串/正则工作"* | **新造的回归** — `TmuxPaneRuntime.consume` 每块都调 `refreshDetectedState()`，它里面 `agentDetector` 是**计算属性**，每块重建 `AgentDetector` 并把所有规则集正则匹配一遍，在主 actor 上。外加每块一次 Task 创建+取消 |
| 36 | 单层输入合并（16ms） | `ControlMode.sendData` | *"突发的头几个字节立刻发出，交互按键不付延迟；随后 16ms 内到的合并"* | **新造的回归（双层）** — `TmuxInputCoalescer`(16ms) 叠在 `ControlMode.sendData` 自己那 16ms 前面。它的头注释说 Go daemon *"故意把批处理上推"*，但 daemon 没了、Swift 那层又回到路径里 |
| 37 | 播种深度按链路类型分档：本地 2000 行 / 远端 400 行，可配 | TVM:1073-1102 | *"跨网络链路账单完全不同：同一份 capture 要解密并在主线程排空……每次窗口切换都要再付一次，而 `escapes:true` 让彩色 agent pane 膨胀数倍。所以远端只播几屏"* | `MISSING` — `TermSessionHost` 硬编码 2000 行给所有链路。`TmuxSessionLink.isLocalLink` **连同它的论证注释一起搬过来了，零调用者** |
| 38 | `doneUnseen` 和工具栏计数只算**被识别的 agent** pane | TVM:1874-1882, 1970-1974 | *"只数被识别的 coding agent（claude/codex/…），不数普通 shell"* | `MISSING（我自己在代码里标注了）` — `runtimeState` 丢掉了 `isAgent` 参数。**每个闲置的普通 shell 都会顶个"done"徽章**，工具栏"N working · M waiting"也把 shell 算进去 |
| 39 | `.awaitingInput` 带上匹配到的 profile id | TVM:1933, 1939 | 喂给 `quickKeys(for:)` | `MISSING` — 恒返回 `profile: ""`。（`quickKeys` 目前无调用点，所以是潜伏而非可见） |
| 40 | 每 pane 的 profile 覆盖能到达检测 | 旧版只有**一个** `StateDetectionService` | *"设了之后检测只用这个 profile 的模式，忽略命令匹配"* | `MISSING` — 现在有**三个**服务实例；覆盖写进了没人读的那个。**pane 菜单里的 "Change Profile" 对活 pane 是空操作** |
| 41 | `updatePaneStates` 只在序列化的 2 秒轮询上跑 | TVM:1818-1833 | *"幂等：绝不叠第二个轮询器——每个泄漏的轮询器每 2 秒多一次 list-panes，淹掉响应队列"* | `PARTIAL` — 轮询本身幂等，但 `handleStoreEvent(.activity)` 在每次 runtime 状态跳变时**额外**发一个不序列化的 `Task`，每次 2+N 次往返，全打在承载按键的同一条控制通道上 |

### 两处"注释活过了行为"

- `TmuxSessionLink:51-52` 有一段注释，**下面没有代码**
- `PaneViewModel:74-79` 还留着*"nonisolated 所以 pane 输出不用跳主线程就能到 surface"*，而它唯一的调用者是 `@MainActor` 的

这和 `refresh-client` 那次是**同一个签名**：注释在，行为没了。审计时这类地方要专门找。

### 唯一变好的一处

`TmuxPaneRuntime` 在 `onOutput?` **之前**记录进检测，所以后台 pane 没绑 surface 时字节仍然喂给检测；重放历史用 `asActivity: false`；`isRecognizedAgent` 挡住了"最近活动"和规则引擎抢答。这几处比旧版好，移植时别退回去。

---

## 汇总

**三份审计，41 条行为，其中 26 条会造成可见损坏或发布阻断。**

按用户能看到的症状排：

1. **掉线后 pane 永久死掉**（#29）— 硬停，且重连看起来是成功的
2. **播种渲染成阶梯**（#30）— 必现
3. **竞态解析 → 永久空白 pane**（#3 + #32 复合）
4. **打字卡顿**（#33 + #34 + #35）— 输出被搬上主 actor，按键也被搬上去，然后排在输出后面
5. **≥5 个 pane 时 Focus→Parallel 丢 pane**（#1）
6. **split/resize 后花屏**（#2 / #4）

---

## 移植时的验收方式

每修一条，在状态列写 `FIXED` 并注明新位置。`WONTFIX` 必须写清理由——
**"没想到"不是理由，"daemon 时代才需要"才是**。
