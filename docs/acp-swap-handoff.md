# ACP swap 交接状态（新 session 从这里开始）

## 一句话

从终端版做 ACP 底层替换，第一次尝试（`acp-native` 分支）**方法错了**：重写了整个 app UI，
破坏了"无损"。改用**从 main 出发的外科式 swap**（此分支 `acp-native-v2`）。

## 三份必读文档（本目录）

1. `acp-swap-plan.md` — 执行规则：禁改清单 + 唯一 3 处接缝 + 顺序。
2. `acp-divergence-audit.md` — 旧版每处交互的 file:line 基准（验收用）。
3. 本文件 — 分支/状态/复用。

## 分支与 worktree

- `main`（/Users/nova/code/speakterm）：原版终端版，**唯一 UI 真相源**。
- `acp-native-v2`（本 worktree）：从 main 拉出，**执行 swap 的地方**。当前只加了 3 个 docs。
- `acp-native`（.claude/worktrees/acp-native，locked）：**错误的重写版，不 ship**。保留仅为
  复用其底层：`acpkit/`（ACP 协议库，30 测试过）、`desktop/internal/acphost/`（daemon agent
  托管：spawn/attach/detach/list/readfile + X25519+ChaCha20 加密 + credit 流控，Go 测试+e2e 过）、
  `desktop/cmd/acpvectors` + crypto 跨实现向量。其 mac 语音恢复（MacVoiceController 逐字从 main
  恢复）证明这些文件本就不该重写——直接从 main 用即可。
  - 该分支有 3 个未提交文件（activation-policy WIP，编译中途），无价值，可丢弃。

## 复用清单（从 acp-native 搬"底层"，绝不搬 UI）

- `acpkit/` 整包 → 加进 v2 的 Package/项目依赖。
- `desktop/internal/acphost/` + `hostidentity/`（从旧 sshserver 抽出的 host key/authorized_keys）
  + `desktop/cmd/bento-daemon` 的 acphost 接线 + `bento` CLI 的 doctor（列 ACP agents）。
- `relay/`：帧格式不变（version 0x01），payload 由 SSH 换成 acphost 加密流。旧分支 docs/relay-protocol.md 已更新。
- ACP agent 预设（10 家，registry 校准过，2026-07-19）：opencode `opencode acp`、
  claude `claude-agent-acp`（包 @agentclientprotocol/claude-agent-acp）、gemini `gemini --acp`、
  codex `codex-acp`（@agentclientprotocol/codex-acp）、copilot `copilot --acp`、qwen `qwen --acp`、
  goose `goose acp`、cursor `cursor-agent acp`、kimi `kimi acp`、amp `amp-acp`。

## 唯一允许改的 3 处接缝（细节见 plan）

1. pane 内容：`GhosttyTerminalSurface`(满足 `TerminalSurface` 协议) → 新 `AgentChatSurface`
   满足同协议；tiled host 外壳（标题栏/拖拽/zoom/布局/分隔条）**不动**，只换里面填的视图。
   ACP 聊天视图内容（streaming markdown、tool-call 卡、diff、plan、权限）可参考 acp-native 的
   `bento-agent-core/UI/*`，但**外层 chrome 一律用 main 的 tiled host**。
2. 后端操作层：`TerminalViewModel` 发 tmux 命令处（split/new-window/new-session/break/join/
   capture-pane/send-keys）→ ACP 会话操作，**保持 @Published 集合形状**（windows/panes/
   sessionPanes/paneStates 不变），原版所有绑定视图零改动。session→window→pane 由本地/daemon
   agent 会话存储提供。`TerminalTransport`/`swift-tmux` 退役。
3. 状态：`StateDetectionService`/`AgentStatusRules` 截屏 → ACP turn 生命周期喂 `paneStates`；
   `PaneState` 调色板/消费方不动。

## ACP 协议要点（省得重查）

- ndJSON JSON-RPC over stdio，protocolVersion 1。方法 initialize/authenticate/session.new|load|
  prompt|cancel|set_mode|set_model；反向 session/update(notification)、session/request_permission、
  fs/*、terminal/*。session/update 判别式：user/agent/thought message_chunk、tool_call、
  tool_call_update、plan、available_commands_update、current_mode_update。stopReason：end_turn/
  max_tokens/max_turn_requests/refusal/cancelled。**解码必须宽容**（opencode 发 usage_update 等非
  spec 更新 + 额外字段）。实测：opencode acp + OpenRouter z-ai/glm-5.2 通。
- 验证工具：acpkit 的 `acp-probe` CLI（`acp-probe --cwd DIR -- opencode acp`）。
  OPENROUTER_API_KEY 走环境变量，**绝不提交**。opencode.json 放 cwd 设 model。

## 未决/待验证

- iOS↔Mac relay 全链路 e2e（需 daemon 跑 + 用户配对）。
- 用户显式新增需求（非原版）：mac 默认跟随 system tint、设置可选全局强调色 → 此功能保留。
