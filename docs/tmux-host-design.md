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

1. tmuxcm 移植（进行中，子代理）
2. instanceCore 抽机 + acphost 42 测试不变绿
3. host/tmux：ensure + pane attach + %output→log→stdio 下行
4. structure op + statekv 镜像
5. resize + credit + capture-pane 兜底
6. Mac 客户端 BentoTmuxPane（Ghostty 渲染基底回接）+ DaemonAuthority
7. B iOS 迁栈（用户已拍板要出）
