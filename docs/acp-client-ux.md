# ACP client UX：差距分析与实施计划

2026-07-19。目标（用户原话）：支持 ACP 的所有在本产品场景中有用的特性，并在 UI 上提供好的交互。
本文档 = 现状盘点 × ACP v1 规范对照 → 优先级排序的实施清单。执行纪律：每项 build+测试绿即单独 commit。

## 1. 现状结论（三路探查汇总）

协议层（acpkit）覆盖已经很全：initialize/authenticate/session-new-load-prompt-cancel/set_mode/set_model、
session/update 全部类型化（含 plan、available_commands、current_mode）、tool call 全字段
（kind/status/content/diff/terminal/locations/rawInput/rawOutput）、5 类内容块、权限、fs+terminal
入站分发。VM（AgentSessionViewModel）已把 modes/models/availableCommands/usage 接进状态。

**但 UI 一概没露出。** 差距集中在四层：

| 层 | 缺口 |
|---|---|
| Composer | slash 命令、mode 切换、model 切换、usage 全无 UI；turn 中 Enter 静默丢失；纯文本-only（无图片/附件/@文件） |
| 卡片 | tool card 不显示 rawInput/rawOutput；terminal 内容块被丢；权限卡不显示 diff/locations（"我在批准什么"信息不足） |
| 生命周期 | auth 需登录的 agent 直接 failed 裸报错（authenticate 零调用点）；stderr 被吞；stop reason 异常值无提示 |
| 会话管理 | MCP servers 恒传 []；默认 agent 无设置 UI；client fs/terminal 能力恒 false（未实现） |

## 2. 规范对照要点（ACP v1，agentclientprotocol.com）

- session/update 十种：user/agent/thought chunk、tool_call(+update)、plan、available_commands_update、
  current_mode_update、config_option_update、usage_update（tokens used/size + cost）。
- 权限四类选项 kind：allow_once/allow_always/reject_once/reject_always；取消 turn 必须以 cancelled 应答挂起权限（已做对）。
- stop reasons：end_turn/max_tokens/max_turn_requests/refusal/cancelled。
- 客户端能力：fs.readTextFile/writeTextFile、terminal（嵌入式终端 = tool call 的 terminal 内容块引用 client 建的 terminalId）。
- promptCapabilities：image/audio/embeddedContext 决定用户消息可带什么内容块。
- 较新增量（部分 agent 未实现）：session/list、session/resume、session/set_config_option（模型/推理档等以
  config options 表达）、usage_update 进正文规范。

## 3. 实施清单（按杠杆排序）

P1（纯 UI，数据已在 VM 流动，最高杠杆）
1. Composer 能力条：`/` 命令自动补全弹层（含 hint、键盘导航）；mode chip、model chip（Menu）；usage 读数。
2. 消息排队：turn 中发送→队列 chips（可删），finishTurn 自动 flush；Enter 不再静默。

P2（信息密度）
3. Tool card：rawInput/rawOutput 折叠段（JSON 美化）；terminal 内容块占位渲染。
4. 权限卡升级：diff 预览（批准编辑场景 toolCall.content 常带 diff）、locations、kind 图标、mac 键盘快捷键。

P3（硬死胡同修复）
5. Auth 流程：捕获 -32000 → phase=.authRequired(methods)，认证卡（方法列表→authenticate→重试建会话），
   失败给 per-preset 登录指引（claude /login 等）+ Retry。
6. Stop-reason 提示（refusal/max_tokens/max_turn_requests）+ stderr 环形缓冲（agent 死亡时展示尾部日志）。

P4（Prompt 富内容）
7. 图片附件：mac 粘贴/拖拽，iOS PhotosPicker；按 promptCapabilities.image 门控；transcript 渲染 image 内容块。

P5（会话管理）
8. 默认 agent 设置 UI（acp_default_agent 已有 key 无写入口）。
9. MCP servers 透传配置（per-preset）。— 本轮若时间不够则出设计不出码

明确不做（本轮），已记为后续：
- client terminal 能力：正确落点是 hybrid-workbench 的 daemon pty（iOS 端 client 在错误的机器上执行命令）。
- fs read/write 能力：无编辑器缓冲可提供。
- @文件 mention：依赖 cwd 索引联动，单独一轮。
- audio 内容块。
- iOS 文件预览接线：AgentChatVC 的 acpOpenFile 仍为 nil。需要给 AcpHostTransport 实现 FilePreviewSource
  （stat/read/listTree ← daemon readfile/listdir ops，stat 需 daemon 增一个 op 或由 readfile 推断），
  然后 AgentChatVC 走 TerminalContainerVC 同款 FilePreviewSheet。mac 端已可用（preview dock 注入）。
- MCP servers 透传：协议与 newSession/loadSession 参数已就绪，恒传 []。建议形态：per-preset 的
  mcpServers JSON（Settings 或 wizard 高级区），存 UserDefaults，spawn 时并入。
- 权限"always allow"目前只透传 optionId（记忆在 agent 侧）；客户端本地 allow 规则（per-tool/session YOLO）待产品定夺。

## 4. 进度

- [x] P1.1 Composer 能力条（slash 补全面板 ↑↓/tab/⏎ 键盘导航；mode/model chip Menu；usage 读数）
- [x] P1.2 消息排队（turn 中 ⏎ 入队 chips；完成自动按序 flush；cancel 后驻留、点按补发/×删除）
- [x] P2.3 Tool card raw I/O（Input/Output 折叠 JSON 段，冗余输出去重；terminal 内容块占位行）
- [x] P2.4 权限卡升级（diff 预览、locations 链接、kind 图标、Details 原始参数、⌘⏎ 允许/⌘⌫ 拒绝）
- [x] P3.5 Auth 流程（authRequired phase 驻留连接；认证卡=方法按钮+loginHint 可复制+Retry；琥珀灯/通知联动）
- [x] P3.6 Stop-reason 提示（max_tokens/max_turn_requests/refusal 显式 notice）+ stderr 尾部 50 行随 agent 死亡 notice 可展开
- [x] P4.7 图片附件（promptCapabilities.image 门控；mac 回形针 NSOpenPanel + ⌘V 粘贴，iOS PhotosPicker；
  ImageIO 降采样 ≤1568px JPEG；用户/agent 消息行渲染缩略图；随排队消息一起入队）
- [x] P5.8 默认 agent 设置（mac Settings General「Agents」段 + iOS 设置页，写 acp_default_agent）
- [x] 附加：iOS accessory 键盘聊天语义化（Esc=中断 / Enter=发送 / 不再注入 ESC 序列）；双平台硬键盘 Esc=中断 turn
