# daemon tmux host（方案 B）施工图

2026-07-29。P7 的核心：`tmux -CC` 的解复用发生在 **daemon 侧**，每个 tmux pane
对客户端呈现为一个 acphost **虚拟 instance**——per-pane 的 seq 游标、credit
背压、durable scrollback 全部白拿，客户端三种 pane 说同一种协议。
`proto.go` 早已把 statekv 称作 "the tmux-server analogue"——这里让类比成真。

## 分层

```
internal/tmuxcm        纯解析层（swift-tmux 的 Go 移植，stdlib-only）
                       control-mode 分帧 · %output 八进制还原 · layout 树
                       · 命令构造/引用 · 回复配对状态机 · StructureSnapshot
internal/host/tmux     宿主层：一个 tmux server 目标 = 一个 ControlClient
                       （local `tmux -CC` 或 `ssh host -- tmux -CC`）
                       pane → 虚拟 instance 映射 · 结构镜像 → statekv
internal/acphost       路由层：Server 新增 kind 路由与三个 op（见下）
cmd/bento-daemon       组装：main 里把 tmux host 挂进 Server（避免 import 环：
                       host/tmux 实现 acphost 定义的接口，acphost 不 import 它）
```

## 协议扩展（对既有客户端零破坏——字段缺省 = 今天的行为）

1. `spawn` 增加 `"kind":"tmux"`（缺省 `"acp"`）。tmux 语义 = **ensure**：
   保证目标 tmux session 存在并被 control client 托管，回 `attached`；
   结构（windows/panes 树）落 statekv，客户端由此发现各 pane 的虚拟 id。
2. 虚拟 instance id 命名空间：`tmux:<target>:<pane-id>`（如 `tmux:local:%5`）。
   pane 的 attach/detach/credit/seq 游标**复用现有 op 原样**。
3. 新 op `resize`：`{"op":"resize","agent_id":"tmux:…","cols":N,"rows":M}`
   → `resize-pane`/`refresh-client -C`。仅 `.resizable` 能力的 pane 有意义，
   ACP pane 不需要。
4. 新 op `structure`：`{"op":"structure","verb":{…}}`，verb 与客户端
   `StructureVerb` 同构 → 翻译为 tmux 命令（split-window / kill-pane /
   select-pane / swap-pane / resize-pane / break-pane / join-pane /
   rename-session …）。**写路径走 daemon（DaemonAuthority），读路径与
   产品 A 完全一致**（getstate + 变更推送）。

## instance.go 的抽机

`agentInstance` 里两类东西缠在一起：
- **通用半身**（tmux 也要）：attached 多订阅集合、`_seq` 单调 stamp、
  eventlog（内存尾 + durable 段）、catch-up 点对点回放、credit 窗口、
  exit 广播。
- **ACP 半身**（tmux 不要）：JSON-RPC id 重写、permission/elicitation
  队列、initialize/session-result 缓存、turnActive 嗅探。

抽法：通用半身提为 `instanceCore`（组合，不是接口继承），`agentInstance`
和 `tmuxPane` 都持有它。**eventlog 语义差异**：ACP 记 JSON-RPC 行；tmux pane
记原始字节块（无行边界假设）——log 条目本就是 opaque bytes ✓。tmux pane 的
scrollback 回放上限用 `capture-pane -e` 兜底（超出 log 保留窗口时），
这正是「产品 B 跨尺寸 attach 保真天生就有」的来源。

## 结构镜像

- control client 开机跑 `list-sessions/-windows/-panes` 建快照
  （tmuxcm.StructureSnapshot），此后 `%layout-change`/`%window-*`/
  `%session-*` 增量维护。
- 镜像写入 statekv key `tmux/<target>/structure`，rev 单调。分数化
  LayoutTree 不进 daemon——daemon 存 tmux 自己的 layout 语言，客户端的
  TmuxAuthority 负责翻译展示（读的是 reading，改的走 verb，绝不客户端存权威）。

## 远程

target 抽象：`local` = 直接 exec `tmux -CC`；`ssh://user@host` = daemon 作
SSH 客户端 exec `ssh … -- tmux -CC`（解析仍在 Go 侧，手机永远不背解析器、
不管私钥）。v1 先 local，ssh target 留接口位。

## 测试路线

- tmuxcm：Swift 测试向量全量移植 + live round trip（本机真 tmux，私有
  `-L` socket，与 swift-tmux 的 live 套件同法）。
- host/tmux：live 测试为主——ensure→statekv 快照→split verb→%layout-change
  →镜像更新→attach pane→%output→seq 递增→credit 停读→capture-pane 兜底。
- 回归红线：acphost 现有 42 测试一个不许动语义（ACP 路径行为冻结）。

## 顺序

1. ✅ tmuxcm 移植
2. ✅ instanceCore 抽机 + acphost 42 测试不变绿
3. ✅ host/tmux：ensure + pane attach + %output→log→stdio 下行
4. ✅ structure op + statekv 镜像（`acphost/tmuxstructure.go`）
5. ✅ resize + credit + capture-pane 兜底
   - ✅ 5.5 会话级尺寸权威（viewport op + setSizePolicy verb + 镜像 sizing
     块，见文末章节与落地记录）
6. Mac 客户端 BentoTmuxPane（Ghostty 渲染基底回接）+ DaemonAuthority
7. B iOS 迁栈（用户已拍板要出）

### 步骤 4/5 落地记录（2026-07-29）

- `{"op":"structure","target":"local","verb":{"kind":…}}`，verb 与客户端
  StructureAuthority 词汇同构（字段 snake_case）。ack
  `{"op":"structureApplied","rev":N}`：daemon 在 verb 命令之后跑一次
  Barrier（同连接重新 list → 镜像发布完成才返回），所以 rev N 的镜像
  **已含 verb 效果**；失败/无忠实翻译一律 `structureFailed`。写路径仍只有
  mirrorTmuxStructure 一条。
- ~~**v1 拒绝的 verb**（一 target 一 session 的边界，不做静默近似）：
  `createSession`、`killSession`（会拆掉托管 control client）、
  `movePane(toSession)`~~ —— **该边界已死**，见文末「多 session +
  默认 socket」章节：三个 verb 全部实现。`reorderPanes` 仍只在
  "每 pane 独占一 window"（Parallel 形态）时有忠实翻译，否则拒绝。
- `renamePane` → `select-pane -T`（pane_title，冻结产品的 pane 标题即此）；
  tmux 对 title 无通知，靠 verb 自带的 Barrier 落镜像，外部改 title 要等
  下一次结构刷新才可见。`renameSession` ~~走 Client.RenameSession 专用
  路径~~ 现为普通 `rename-session -t name to`：刷新按 **$N id** 定址、
  当前名每轮从 fresh list-sessions 对账（见文末多 session 章节），
  rename 竞态从根上免疫，专用路径已删。
- 镜像扩了 per-pane reading：SnapshotWindow.Details（title/geometry/
  active/zoom）。**故意不含 pane_current_command**——进程内省会抖
  （sh→bash），抖动字段进变更检测就会铸出假 rev。%window-pane-changed
  现在解析并触发刷新（外部 select-pane 不再让 active 变陈旧）。
- `{"op":"resize","agent_id":"tmux:local:%N","cols":C,"rows":R}` →
  `resize-pane -x -y`，ack 同 structureApplied。**尺寸接缝**：v1 只做
  per-pane resize；controlling client size（冻结产品 prd-mac-client §2.3
  的 session-size 策略：window-size latest/manual + 会话级尺寸归属）留待
  后续——daemon 的 control client 恒报 200×50。
  （该接缝已由步骤 5.5 落地：viewport 声明 + setSizePolicy，见其落地记录。）
- capture-pane 兜底：pane 首次 attach 且 log 为空时，先用
  `capture-pane -p -J -e`（\n→\r\n）灌 log 再订阅 %output——seed 是
  **普通条目**（seq 从 1 起、一条一 unit，线上无任何"合成"标记）。
- credit：tmux pane 广播与 ACP 完全同一 per-session 窗口（instanceCore/
  session 复用），live 测试实测 stall 于 InitialWindow+一 chunk、credit
  后续传。pump 停读时 paneSubQueue（4096 chunk）仍是唯一缓冲，溢出仍丢
  （capture-pane repair 仍属后续步骤）。

## 步骤 5.5 ✅：会话级尺寸权威 —— prd §2.5 的 daemon 之家

冻结产品的三策略（跟随最新 / 以此设备为准 / 最小者）当年长在客户端 VM 上，
靠 `window-size` 选项 + `@bento_size_owner` 会话变量 + `%client-detached`
释放。**新架构下前提变了：手机和 Mac 不再是 tmux client（它们是 acphost
流），daemon 的 control client 是唯一真客户端** —— 所以 tmux 侧永远
`window-size latest` + 由 daemon 独占供尺寸，三策略的仲裁整体上移进 daemon：

- 设备声明视口：`{"op":"viewport","target":"local","cols":C,"rows":R}`
  （每条已建立的流一份，流关闭即撤销 —— 顶替 `%client-detached` 的角色）
- 会话策略：structure 动词新增 `setSizePolicy{policy: "latest"|"pinned"|
  "smallest", owner_stream?}`，落 daemon 内存 + statekv `sizing` 块
  `{policy, owner_device, cols, rows}`（镜像随 rev 走，UI 读它显示
  「由 Shang iPad Air 设定」这类归属）
- daemon 按策略求 governing size → `refresh-client -C WxH` → tmux 重排 →
  `%layout-change` → 镜像 —— 写路径仍只有一条
- pinned 的 owner 流断开 → 自动回落 latest（冻结产品的释放语义等价）

实现归属：host/tmux 加 governing-size 求解器（纯函数，好单测）+
acphost 的 viewport 记账。排在 H 需要 ⇧⌘R（Track Session Size）之前落地。

### 步骤 5.5 落地记录（2026-07-29）

- 求解器 = `tmuxhost.ResolveGoverningSize`（`host/tmux/sizing.go`，纯函数，
  表驱动单测穷举）：latest 按**声明顺序**取最新（重声明移到队尾）；
  smallest 是 cols/rows **各自独立**取最小（与 tmux 自己的 window-size
  smallest 同义）；pinned 跟 owner 的声明走，owner 声明不在（流已关）
  回落 latest；零声明 = 200×50 启动默认。未知 policy 按 latest 解——
  入口已校验，求解器不猜 0×0。
- **pinned 的 owner = 发 verb 的那条流**，线上不可指名他人（一台设备只能
  诚实地钉自己）——冻结产品用 tmux client name（tty）当身份、label 随行
  展示的同构翻译：流就是设备连接，`owner_device` 只是 UI 归属标签。
  没有 viewport 声明的流发 pinned 直接 structureFailed（"钉什么？"）。
  owner 流关闭 → policy 自动回 latest（%client-detached 释放语义），
  `revokeTmuxViewports` 挂在 session.Close 上。
- 记账在 acphost（`tmuxsizing.go`，sizingMu 独立叶锁）：viewport op 无
  ack（声明不是命令；镜像 sizing 块是读路径），setSizePolicy 走 verb 标准
  ack——`Client.SetSizing` 先在控制连接上排入 `refresh-client -C`、把块
  纳入结构**变更检测**（policy 换了但尺寸没变也要重发布），再 Barrier，
  所以 ack rev 的镜像必含新块。镜像块由 mirrorTmuxStructure 从 server
  态读出嵌入（`tmuxStructureState.Sizing`，additive）——写路径仍只有一条。
- policy/声明 = **daemon 内存态，故意不持久**：声明和 owner 都是流，流
  死于 daemon 重启，零声明世界的诚实解就是 latest@默认——与释放语义自洽。
- 顺带修掉的陈旧面：`%session-window-changed` 现在解析并触发刷新，
  `SnapshotWindow.Active`（additive omitempty）随镜像走——外部
  select-window 不再让 window-active 变陈旧（Swift 投影可停止"最小
  index 即 Parallel 窗"的猜测）。tmux pane 补上 pty pane 已有的
  exit-before-join 点对点交接（同一 mu 论证，见 ptypane.go）。
  AgentCounts 现在数 pty pane（daemon-mortal）、**不数** tmux pane
  （tmux server 活过 daemon 重启）——重启警告只报真会死的。
- 测试：求解器单测 + `tmuxsizing_live_test.go` 全程 live round-trip
  （声明→镜像块→list-clients/list-windows 实测 declared size；
  gotcha：tmux 3.7b 的 `#{client_height}` 求值为空，高度经 window 尺寸
  断言——refresh-client 的效果本身不受影响，已实测）。

## 多 session + 默认 socket（2026-07-29 落地）—— 一 target 一 session 边界之死

生产事故证明私有 socket 是平行宇宙：daemon 曾硬编码 `-L bento-acp`，
看不见用户默认 socket 上的真 tmux server —— 用户 attach「自己的」session
看到的是 daemon 私造的空壳双胞胎。同时 ps 里"同一条
`-CC new-session -A -s bento` 出现两个 pid（差 2）"被误读为双 control
client。两个问题一次修掉：

### socket 政策（现行）

- **local target 永远说默认 tmux server socket**（用户终端里 `tmux`
  用的同一个）。生产接线**没有**任何私有 socket 可配 ——
  `tmuxhost.Config` 的 SocketName 字段已删除。
- 唯一 override：环境变量 **`BENTO_TMUX_SOCKET`**（一个 `-L` socket
  名），只为测试/开发存在。所有 live 测试经它注入一次性私有 socket
  （`t.Setenv`），用户的真 server 神圣不可侵犯。`BENTO_TMUX` 继续只管
  二进制路径。
- 守卫测试 `TestSocketPolicyDefaultsToDefaultServer`（host/tmux/
  socket_test.go）：无 override 时 launch line **不得**含 `-L`——纯函数
  断言，不连任何 server；私有 socket 回潮 = 测试红。

### 「双 control client」真相（不是 race）

pids 60885+60887 同 argv 的解释：launch 单飞早已成立（Host.mu 横跨
existing-check 与 launchLocal），第二个进程是 **tmux server 本体** ——
无 server 时 -CC client fork server，server 走 daemon(3) **双 fork**
（中间 pid 死掉，所以差 2、PPID=1），而 macOS 的 setproctitle 是 no-op，
server 的 ps argv 保持 client 的原样。live 实测复现（client N、server
N+2、argv 逐字节相同）。新增 `TestLiveEnsureSingleFlight`（8 路并发
ensure → 同一 *Client、`list-clients` 恰好 1）把单飞钉死；数 control
client 永远用 `list-clients`，别信 ps。

### 多 session 模型

- **一 target 一 control client，session 任意多**。`EnsureLocal(name)`：
  无 client → launch（`new-session -A -s name`，单飞）；有 client →
  `Client.EnsureSession(name)`（client 级 ensureMu 单飞）：fresh
  `list-sessions` → 缺则 `new-session -d`（"duplicate session" 容忍 ——
  外部并发创建即目标态）→ 非当前则 `switch-client` → Barrier（ack 前
  镜像必含该 session）。
- **镜像列全 server**：refresh = `list-sessions` + 每 session 一对
  `list-windows`/`list-panes -s`（按 **$N id** 定址，rename 竞态免疫；
  中途消失的 session 跳过——它的 %sessions-changed 已排队下一轮）。
  当前 session 名每轮按 id 从 fresh listing 对账（顺带修掉了
  %session-renamed `$id name` 被整串当名字的老 bug——tmuxcm 现在
  拆 id，任意 session 的 rename 都能收到）。
- **statekv 快照形状**（key 不变 `tmux/<target>/structure`，additive；
  权威注释在 acphost/tmuxpane.go 的 tmuxStructureState 上）：

  ```json
  {"rev":12,"target":"local",
   "session":"bento",              // control client 当前 session（""=server 已空）
   "structure":{"windows":[...]},  // 当前 session 的快照（旧字段，= attached 行的别名）
   "sizing":{...},
   "sessions":[                    // 新增：全 server，list-sessions 序
     {"id":"$0","name":"bento","attached":true,"structure":{"windows":[...]}},
     {"id":"$4","name":"work","structure":{"windows":[...]}}]}
  ```

  旧解码器只认 rev/session/structure/sizing 照常工作；新读者优先
  `sessions`。`attached` 恰一个 true = %output 正在流的那个 session。
- **verb 路由**：session 字段 "" = 当前。`newPane -t 'name:'`、
  `reorderPanes`/`applyTiled` 按名列表；pane 定址 verb 用 server 全局
  pane id（selectPane 改 `list-panes -a` 全服查找）。新实现：
  `createSession`（new-session -d，不切 client——ensure 才是 attach 动
  作）、`renameSession -t name to`（任意 session）、`movePane` =
  `break-pane -d -t 'sess:'`（solo pane 连窗搬走、搬空的 session 死 ——
  tmux 3.7b 实测语义，忠实转达）、`killSession`：杀当前且有幸存者 →
  daemon 先 switch-client 再杀（client 存活）；杀**最后一个** session →
  整个 server 连 control client 一起下线（tmux 允许，我们也允许），
  Exec 回包先于 %exit（实测），WaitClosed 确认 refresher 已死后由
  applyKillSession 直接发布**空 server 镜像**（session ""、无
  sessions）——唯一一次 mirrorTmuxStructure 不从 refresher 调用，
  单写路径纪律靠"client 已死、无并发写者"成立。下一次 ensure 重新
  launch。
- **通知面**：%sessions-changed / %unlinked-window-add/close/renamed
  （tmuxcm 新解析）+ 既有 %session-*/%window-*/%layout-change 全部触发
  全服 re-list。**诚实盲区**：非 attached session 里纯几何变化（外部
  resize-pane，pane 数不变）3.7b 不发任何通知（-B subscription 的 `%*`
  实测也只覆盖 attached session），镜像要等下一个任意通知/verb barrier
  才追上——分格数变化（split/kill）有 %window-pane-changed 兜着。
- **%output 只流当前 session**（tmux 控制模式语义，实测）：ensure 即
  切换，产品路径「ensure → attach panes」天然订在流动的 session 上；
  跨 session 同时流多 pane 需要将来"每 session 一 client"的扩展——
  显式 defer。sizing（refresh-client -C）同理只治理 attached session
  的窗口。

### live 覆盖（2026-07-29）

- host/tmux：`TestLiveMultiSessionMirrorAndEnsure`（外部建 session 入
  镜、ensure 复用同 client 并切换、切换后 %output 流、外部 kill 出镜）、
  `TestLiveEnsureSingleFlight`。
- acphost：`TestLiveTmuxMultiSessionVerbsRoundTrip`（createSession →
  newPane 按名路由 → ensure 切 attached → splitPane 全局 id →
  renameSession 后台改名 → movePane 跨 session → killSession 当前带
  幸存者 → killSession 最后一个 = 空镜像 → re-ensure 重生），refused
  套件改为「只拒 malformed + tmux 自己拒的」。
