# 会话历史设计 v2：协议直读，零自有存储

2026-07-20。v1（daemon 飞行记录仪）经讨论**废弃**：用户价值锚定在"能续上"——不能 resume 的死记录不值得为其承担双写、一致性与保留策略的复杂度。v2 = 协议原生直读，agent 存储是唯一事实源。

## 0. 需求（修订后）

- 有一个统一的地方能看到历史会话，并能按**当前目录**过滤；
- 点开历史 = 续上会话（看与续是同一动作）；
- "不丢"不追求绝对：历史窗口 = 各 agent 自己的保留策略。

## 1. 机制

- **列清单**：`session/list`（sessionCapabilities.list 门控，游标分页，元数据含 id/cwd/title/lastUpdate；spec: agentclientprotocol.com/protocol/session-list）。
- **看+续**：`session/load` —— agent 把整段历史以标准 `session/update` 流回放（现有聊天渲染管线直接吃），落地即活跃、可继续输入。
- **元数据保鲜**：`session_info_update` 通知（标题变化等），列表免轮询。

## 2. daemon：一个查询 op

- 新控制操作 `agentsessions {presetID?, cwd?, cursor?}`：
  - 有现役实例的 agent → 走现有连接调 `session/list`；
  - 无现役实例 → 按 preset 短暂拉起 agent（initialize→list→退出）；结果合并分页回传。
  - 结果不落盘；daemon 内存短 TTL 缓存即可（非事实源）。
- Mac 本地 acp.sock / 手机 relay 密封流复用既有信道。

## 3. UI：历史面板

- **入口**：Mac session 菜单 "History…" + ⌘P palette 源；iOS host 页 History 标签。
- **列表**：跨 agent 聚合，时间倒序：标题 + agent 图标 + cwd 尾段 + 相对时间；现役会话标 live（点击跳对应 pane）。过滤器：目录（精确/子树）、agent、关键词（对 list 元数据过滤；不做全文——没有本地内容可搜）。
- **打开 = 续聊**：点条目 → 在该 cwd 新建 pane（或复用现役 pane）→ `loadSession` 回放渲染，直接可继续对话。没有"只读回放"形态。

## 4. 当前目录视图

`session/list` 元数据自带 cwd → 纯过滤器，三个入口：
- pane 标题栏右键 "History in this folder"；
- 新建 pane 流程（选定目录后）列该目录最近 3 条可续会话（对标 CC `/resume` 体验）；
- palette 路径片段过滤。

## 5. 接受的代价（明示）

1. **历史窗口 = agent 保留策略**：如 CC 默认 `cleanupPeriodDays=30`；想留久由用户在 agent 侧调大——保留控制权与存储同侧，无一致性问题。
2. **能力门控**：不声明 `session/list` 的 agent 无历史可见（与 Zed 同门槛）。实施第一步 = 实测 claude-code-acp / opencode / codex-acp / gemini 的 sessionCapabilities 声明，决定实际覆盖面。
3. 列表需要 agent 进程应答（无实例时短暂拉起）；面板打开有秒级延迟，靠 TTL 缓存缓解。

## 6. 将来可加回的钩子

面板数据源做成接口。若"重要对话被 GC"成为真实痛点，可追加**可选**归档源（daemon tee 或 CC transcript 读取，v1 设计存档于 git 历史 d934406），不需重新设计面板。

## 7. 里程碑

- **V1**：能力实测（四家 agent 的 sessionCapabilities）+ daemon `agentsessions` op + Go 测试。
- **V2**：双端历史面板 + 打开即续聊 + live 标记。
- **V3**：目录三入口。
