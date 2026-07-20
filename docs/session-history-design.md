# 会话历史设计：daemon 飞行记录仪 + 统一历史面板

2026-07-20。需求（用户原话）：**会话记录不会丢；有一个统一的地方能看到一切历史；也能看到当前目录下的会话历史。**

## 0. 核心设计判断

**记录点选在 daemon，不在客户端。** 理由：

1. **daemon 是所有对话的必经之路**——acphost 已经代理每个 agent 的 ACP ndJSON 流（做 id 重写/权限重放/sessionId 嗅探），在这里做 tee 是零侵入的旁路；
2. **daemon 是常驻方**——手机/Mac app 随时退出，daemon 一直在；客户端记账必然有窗口丢数据；
3. **天然多设备**——历史落在 daemon，手机和 Mac 看到同一份，不需要同步协议；
4. 符合既有架构原则：daemon 拥有持久化，客户端只渲染。

对比 Zed：Zed 是客户端索引 + 依赖 agent `loadSession` 回放，且只见过自己创建的会话。我们的 daemon 记录仪独立于 agent 的存储实现，格式统一，agent 换存储/删存储都不丢——这就是"不会丢"的保证来源。

## 1. 数据层：会话日志（journal）

- **位置**：`$BENTO_HOME/history/<acpSessionID>.jsonl`，append-only。
- **内容**：该会话的对话相关 JSON-RPC 消息**原样逐行落盘**（`session/prompt`、`session/update`、`session/request_permission` 及其结果、`session/cancel`），每行包一层信封：`{ts, dir: "c2a"|"a2c", msg: <原始 JSON-RPC>}`。原样存 = 最大保真 + 前向兼容（schema 就是 ACP 协议本身，和 CC transcript 的哲学一致）。
- **元信息**：文件首行 meta 记录 `{acpSessionID, agent(presetID/command), cwd, createdAt, title?, workspaceSession?, paneID?}`；title 后续可由首条 prompt 截断生成，daemon 收到即补写一行 meta-update。
- **索引**：daemon 启动时扫 `history/` 建内存索引（几百个文件量级，毫秒级）；运行中增量维护。不引数据库。
- **写入策略**：逐消息 append，OS 缓冲 + 周期 flush；崩溃最多丢尾部几条（与 CC 同级别）。
- **保留策略**：默认**永不删除**（纯文本很小）；陈年会话 gzip 轮转；显式删除只能从历史 UI 发起（破坏性操作，确认后 daemon 删文件）。
- **生命周期解耦**：Close Pane / Kill Session 只解除活跃绑定，**journal 不动**——不需要单独的"归档"概念，journal 就是归档。

## 2. 协议：两个新控制操作（acphost control 0x01）

- `historylist {cwd?, agent?, query?, limit, offset}` → 索引分页：`[{acpSessionID, title, agent, cwd, createdAt, lastActive, live: bool(现役实例?), paneRef?}]`。`cwd` 过滤支持精确与子树前缀两档。
- `historyread {acpSessionID, fromByte?}` → 分块回传 journal（尾部增量续读用 fromByte）；现役会话可持续 tail。
- Mac 本地走 acp.sock 明文，远程走 relay 密封流——隐私由既有信道保证（journal 含代码/密钥，绝不出密封信道）。
- statekv **不装**历史（太大）；只走这两个 op。

## 3. UI 层：统一历史面板

**入口**
- Mac：session 按钮菜单加 "History…"；⌘P palette 新增 history 源（直接搜标题/cwd）。
- iOS：host 页加 History 标签（与会话选择器并列）。

**列表**：按时间倒序，每行 = 标题 + agent 图标 + cwd 尾段 + 相对时间 + 状态徽章（`live`=现役，点击跳到对应 pane；否则"可续"/"仅回放"）。过滤器：目录（见 §4）、agent、关键词（v1 = daemon 端对 journal 的朴素全文扫描，量级可控；后续再上索引）。

**查看**：点击 → 只读回放视图——journal 里的 `session/update` 走**现有 AgentChatView 的同一条解码/渲染管线**（它们本来就是同一格式），零新渲染代码。

**续聊（Continue）**：回放视图底部 "Continue in new pane" → 在原 cwd 建 pane，带 `acpSessionID` 走既有 respawn+`loadSession` 通路（agent 声明 loadSession 才可续，与 Zed 同门槛；不支持的只读回放仍在——**这是比 Zed 强的点：不可续也看得到**）。

## 4. 当前目录视图

同一索引 + `cwd` 过滤，三个入口：
- pane 标题栏右键 → "History in this folder"（取该 pane 的 cwd 预填过滤器）；
- 新建 pane 流程（目录面板确认后）列出该目录**最近 3 条**可续会话——"在这继续上次的活"一步直达，对标 CC `/resume` 的体验；
- palette 输入路径片段直接过滤。

## 5. 场外会话与回填（后置）

**协议优先**：ACP 已有 `session/list`（sessionCapabilities.list 门控，游标分页，返回 id/cwd/title/lastUpdate；agentclientprotocol.com/protocol/session-list）。daemon 可短暂拉起 agent → list → 并入 `historylist`（provenance 徽章="agent 存储"）→ Continue 走 `loadSession`。

**journal 回填**：对功能上线前的旧会话/场外会话，用 `session/load` 的全量回放一次性抓进 journal——"不丢"追溯到历史存量。注意：list 只见 agent 存储里还活着的会话（会被 GC），所以它是**导入通道**；journal 仍是唯一持久层。

**CC transcript 文件适配器降为兜底**：覆盖不声明 list 的 agent、agent 已卸载、免拉进程浏览三种场景（JSONL 结构已解剖，见 hybrid-workbench-design.md §7）。
- ⚠️ 开放问题：各目标 agent 对 sessionCapabilities.list 的实际采用度需实测；claude-code-acp 的 ACP sessionId 与 CC 自身 sessionId 的映射需实测；Bento 内跑的会话在 journal 与 agent 存储两边出现，按 sessionId 去重（映射不明前用 cwd+时间窗启发式）。

## 6. 已知缺口（如实记录）

- **daemon 之外的进程不被记录**：Mac 罕见的 in-process fallback launcher 不经 daemon——v1 接受此缺口（Adaptive launcher 默认优先 daemon）；后续可加客户端上报 op。
- 崩溃尾部丢失（≤秒级缓冲）；
- 全文搜索 v1 是朴素扫描。

## 7. 里程碑

- **H1 记录仪**（先发——从此刻起不再丢任何记录）：daemon tee + meta/索引 + 两个控制 op + Go 测试（记录/轮转/list/read/尾部续读）。
- **H2 统一面板**：双端 History UI + 只读回放（复用 chat 渲染管线）+ Continue。
- **H3 目录视图**：三个 cwd 入口。
- **H4 场外会话**：CC transcript 适配器 + 去重 + provenance 徽章。
