# Bento 产品文档索引

一个仓库，两个产品，同一个场景：并行跑一堆 AI coding agent。

## 产品 A · Bento（ACP 原生，面向任何人）

零技能门槛的多端 agent 工作台。ACP 协议为主，CLI agent 经适配器接入，
Mac daemon 托管进程 + iOS 端到端加密伴侣。

- 架构总图：[architecture.md](architecture.md)
- ACP 客户端 UX（slash/mode/权限卡/附件/transcript）：[acp-client-ux.md](acp-client-ux.md)
- Relay 协议纪律：[relay-protocol.md](relay-protocol.md)

## 产品 B · Bento Term（tmux 后端，面向专业/半专业开发者）

**为 AI Agents 场景做的 tmux 前端**——不是通用终端模拟器。tmux 作后端
换取全保真 TUI 与服务器端结构权威。

- 移动端 PRD（page/viewport 模型、尺寸权威三策略、手势表）：[prd-bento-term.md](prd-bento-term.md)
- Mac 客户端 PRD（窗口即 page、handoff、Tiles）：[prd-mac-client.md](prd-mac-client.md)

## 合并期间的账本

- 外壳特性认领台账：[merge-claims.md](merge-claims.md)
