# 会话历史设计 v3：元数据目录，内容不存

2026-07-20。演进：v1 全量飞行记录仪（内容双写，废弃——价值锚定在可续性）→ v2 协议直读零存储（废弃——面板依赖现场拉 agent 问 list：慢、能力门控、agent 侧状态决定可见性）→ **v3 = 存"有哪些会话"（名称/id/上次操作时间/目录），不存内容**。

## 0. 分工

| 关注点 | 归属 |
|---|---|
| 有哪些会话、在哪个目录、最后活跃 | **我们的目录（catalog）**——秒开、离线可用、不依赖 agent 能力 |
| 对话内容与续聊状态 | **agent 自己的存储**，经 `session/load` 回放+续聊 |
| 保留时长 | agent 侧策略（如 CC `cleanupPeriodDays`）；目录条目指向已 GC 的会话 → load 失败 → 标"已过期"（良性失配，自愈） |

## 1. 数据模型

CatalogEntry：`{acpSessionID, title, presetID, cwd, createdAt, lastActive, expired?: Bool}`
- **来源**：pane 记录的"毕业"——Close Pane / Kill Session 时不丢弃 acpSessionID，转存目录（agent 进程死≠内容死，仍可 respawn+load 续）；
- **title**：首条 prompt 截断起底，`session_info_update` 到达时更新；**lastActive**：回合结束时间戳；
- **显式删除**：仅从历史 UI 发起（只删目录条目，agent 侧内容不动）。

## 2. 存储与同步

- daemon statekv 单独 key `"history-catalog"`（与 workspace 结构分离，避免高频互扰）；
- 客户端在会话创建/回合结束/标题变化时 upsert；adopt 远端目录时**按 sessionID 并集合并、lastActive 取新**（避免 last-write-wins 丢条目；条目粒度合并是平凡的）；
- 本地 UserDefaults 镜像作离线缓存（同 workspace blob 模式）。
- 量级：每条几十字节 × 数百会话，statekv 无压力。

## 3. UI：历史面板

- **入口**：Mac session 菜单 "History…" + ⌘P palette 源；iOS host 页 History 标签。
- **列表**：读目录，秒开。行 = 标题 + agent 图标 + cwd 尾段 + 相对时间 + 徽章（live=现役 pane，点击跳转；expired=已过期灰显）。过滤：目录（精确/子树）、agent、标题关键词。
- **打开 = 续聊**：点条目 → 在原 cwd 建 pane、预填 acpSessionID → 走**现成的** respawn+`loadSession` 通路（回放渲染 + 直接可输入）。load 失败 → 标 expired，提示内容已被 agent 清理。

## 4. 当前目录视图

目录按 cwd 过滤，三入口：pane 标题栏右键 "History in this folder"；新建 pane 选定目录后列该目录最近 3 条可续会话（对标 CC `/resume`）；palette 路径片段。

## 5. `session/list` 的角色：对账与导入（可选增强，后置）

- **对账**：对声明 list 能力的 agent 后台核对——目录条目不在 agent 清单里 → 预标 expired（免得用户点开才发现）；
- **导入**：agent 清单里有而目录没有的（场外会话）→ 并入目录（provenance 徽章）。
- 面板不依赖此路径；不声明 list 的 agent 仍有"经 Bento 跑过的全部会话"。

## 6. 实现状态（2026-07-20，V1-V3 已落地：9d835e8 / 34ef290 / e092c2c）

全部三批完成，双端构建绿 + 131+90 测试全绿。与设计的偏离（如实）：
- lastActive 在回合完成后的活动事件也会刷新（读作"上次操作时间"，比严格回合结束略宽）；
- expired 判定粗粒度：load 的任何 agent 侧 RPC 错误（排除传输错误）即标记——ACP 无标准 "session not found" 错误码，TODO 已注）；
- **无墓碑**：目录删除在多设备并集合并下可能复活（单 Mac 无影响；若成痛点加 tombstone 字段）；
- 目录面板的"最近 3 条"做在 NSOpenPanel 内部随导航实时更新（modal 确认即关，面板内是可行形态）；
- ⌘P History 源 matchText=标题+cwd（路径片段过滤随批 2 落地）；iOS = host 页内联 3 条 + "All History…" sheet。
V4（session/list 对账导入）未做，按计划后置。真实续聊/面板视觉待用户两端实测。

## 7. 里程碑

- **V1 目录**：CatalogEntry + statekv key + 并集合并 + pane 关闭转存 + 单元测试（合并/过期标记/毕业路径）。
- **V2 面板**：双端历史 UI + 打开即续聊 + live/expired 徽章。
- **V3 目录入口**：cwd 三入口。
- **V4（可选）**：session/list 对账+导入；四家 agent sessionCapabilities 实测随此项做。
