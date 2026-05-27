# Bento Mac/CLI Client · 产品设计文档 (v0.1)

> 把 Bento 从"高级 iOS tmux 客户端"扩展为"小白也能并行指挥多个 coding agent"的控制平面。Mac 菜单栏 + 跨平台 CLI + 公网跳板 SSH 代理。

---

## 一、产品定位

**一句话：** vibe coder 在自己的 Mac/Linux 机器上以"会话 + Agent"为单位组织工作，菜单栏/CLI 管理本地 tmux 会话与 coding agent，公网跳板让 iOS 端无需配置网络即可远控。

**核心承诺：**

1. **Agent prep wizard**：选目录 → 选 agent (Claude Code / Codex / Aider…) → 选 N 个 pane → 自动开好 tmux + 各自起 agent，不需要懂 shell 或 tmux 命令
2. **菜单栏会话面板**：实时看到所有 tmux session、各 pane 的 agent 名/状态/最近输出，点击跳转到系统终端
3. **零配置远程接入**：Mac/Linux 端注册到 Bento relay，iOS 端凭账号自动连通，无需用户懂端口转发 / VPN
4. **tmux 配置一键化**：自动写好 `.tmux.conf`（鼠标支持、合理 prefix、状态行美化），把"装上就好用"作为最低门槛

**目标用户：**

| 画像 | 现状 | Bento Mac 解法 |
|---|---|---|
| **A. Power user** (会 SSH、自有 VPS、用 tmux) | iOS 单独装即可 | 可选择不装 Mac 客户端 |
| **B. Vibe coder 新手** (会 Cursor / Claude Code GUI、不懂 tmux 不懂网络) | 想并行多 agent 但只会一个个开窗口 | **Mac 客户端是主入口**，iOS 是远控扩展 |
| **C. Headless dev** (在云 GPU 主机上跑 agent) | SSH 进去手动 tmux | 装 daemon + CLI，从任意设备远控 |

**与竞品差异：**

| 维度 | iTerm2 + tmux | Warp | Cursor | **Bento Mac** |
|---|---|---|---|---|
| 终端会话持久化 | ✓ (要会 tmux) | 部分 | ✗ | ✓ (零配置) |
| 图形化 pane 操作 | ✗ | ✓ | ✗ | ✓ |
| Agent prep wizard | ✗ | ✗ | ✗ | **独家** |
| 多 agent 并行调度视图 | ✗ | 弱 | 弱 | **独家** |
| 远程移动控制 | ✗ | ✗ | ✗ | **独家 (iOS 端)** |
| 跨平台 (Mac/Linux/WSL) | iTerm 仅 Mac | 仅 Mac | 三平台 | **三平台** |

---

## 二、架构

### 2.1 共享 CLI 核心 + Mac 菜单栏壳

```
                         ┌────────────────────────────┐
                         │     bento-daemon       │   ← Go binary, 跨平台
                         │  (Mac / Linux / WSL)       │
                         │                            │
                         │  • Relay 注册客户端         │
                         │  • tmux session inventory  │
                         │  • Agent launcher engine   │
                         │  • Local API (Unix sock)   │
                         └──────┬────────────┬────────┘
                                │            │
              ┌─────────────────┘            └──────────────────┐
              │                                                  │
   ┌──────────▼──────────┐                          ┌────────────▼─────────┐
   │   bento CLI     │                          │   Bento.app      │
   │   (cross-platform)  │                          │   (macOS menubar)    │
   │                     │                          │                      │
   │   • session ls/up   │                          │   • NSStatusItem     │
   │   • agent up/down   │                          │   • Agent wizard GUI │
   │   • relay status    │                          │   • Session 列表面板   │
   └─────────────────────┘                          └──────────────────────┘

                                  ▲
                                  │ SSH over relay (reverse tunnel)
                                  │
                         ┌────────┴────────┐
                         │  Bento iOS  │  (existing app)
                         └─────────────────┘
```

**关键选择：daemon 用 Go 写。** 单二进制部署、跨编译 Mac/Linux/WSL 平凡、系统编程符合语言强项、`runtime/os` 写 daemon 不痛苦。Swift on Linux 不成熟，Rust 迭代慢，都不合适。

### 2.2 公网跳板（不是真正 NAT 穿透）

```
Mac (run daemon)                                 iOS
   │                                              │
   │  ssh -R 0:localhost:22  ──┐         ┌──── ssh user@relay -p NNNN
   │                            ▼         ▼
   │                       ┌─────────────────┐
   │                       │  Relay (Go svc) │
   │                       │  • TCP socket   │
   │                       │  • 配对 sessions │
   │                       │  • 多区域部署    │
   │                       └─────────────────┘
```

- **协议：** 标准 SSH 反向隧道，没有自研协议。daemon 是 `ssh -R` 的 wrapper + 重试 + 心跳
- **后端：** Go HTTP + raw TCP，5 美金/月 VPS × {US/EU/CN}三个区域。注册/查找/计费走 HTTP，数据流走 raw TCP
- **认证：** 账号系统暂用 [Nova Auth](https://auth.novashang.com) OIDC（用户已有），不自建。Mac/iOS 客户端 OIDC 登录后拿 token，daemon 拿 token 注册到 relay
- **付费理由：** 免费层 = 一个 host + 单区域 + 限流；付费 = 多 host + 自动选择最近区域 + 优先带宽

### 2.3 Agent launcher 抽象

用户在 GUI/CLI 里定义"工作场景"：

```yaml
# ~/bento/agents/auth-refactor.yml
name: Auth Refactor
session: auth-work          # 对应 tmux 会话名
panes:
  - dir: ~/code/myapp
    branch: feature/auth-v2
    agent: claude-code
    instructions: "Refactor the JWT auth module to use the new key rotation API"
  - dir: ~/code/myapp
    branch: main
    agent: claude-code
    instructions: "Watch for tests passing, run linter when files change"
  - dir: ~/code/myapp
    agent: shell             # 留一个手工 pane
```

CLI `bento agent up auth-refactor` → daemon 创建 tmux session、各 pane `cd` 到目标目录、checkout 分支、起对应 agent 进程并把 instructions 注入。

GUI wizard 就是给这个 YAML 做表单。

---

## 三、v1 功能范围

### 必须有

1. **`bento-daemon`** (Mac/Linux/WSL Go binary)
   - 命令：`start`、`stop`、`status`、`relay-register`
   - tmux session inventory (`tmux ls` + 解析)
   - Agent launcher 执行引擎
   - Unix socket API (本地 RPC)
2. **`bento` CLI** (跨平台)
   - `session ls`, `session inspect`, `session kill`
   - `agent up <spec>`, `agent down <name>`, `agent template <name>` (生成 YAML 模板)
   - `relay status`, `relay reconnect`
3. **Bento.app** (Mac 菜单栏)
   - NSStatusItem，下拉显示所有 sessions + 状态
   - Agent prep wizard (GUI 表单 → 写 YAML → 调 CLI)
   - tmux 配置一键化按钮（写 `~/.tmux.conf`，注意保留用户原配置）
   - 点击 session → 调起系统 Terminal 并 `tmux attach`
4. **Relay 服务** (Go)
   - 单区域 MVP，后续扩多区域
   - OIDC token 验证（接 Nova Auth）
   - 反向隧道配对
5. **iOS app 集成 relay 客户端**
   - 在现有 host 列表里多一个"My Computers"段落，列出账号下的 daemons
   - 点击即通过 relay 连入，省掉手动配 IP/端口

### 不做（v1 非目标）

- Mac 端自己渲染终端（继续依赖系统 Terminal / iTerm2 / iPad-on-Mac）
- Mac 端语音输入（Wispr Flow / Superwhisper 等已经够好）
- 原生 Windows（仅 WSL 子系统下支持，因为 Windows 原生 tmux 不支持 control mode）
- 自研 NAT 穿透 / WireGuard 网状网络（用 SSH 反向隧道足够）
- Agent 输出的图形化时序图、token 计费视图等高级仪表盘
- Mac 客户端自带 agent runtime（用户得自己装 Claude Code/Codex/Aider 等 CLI 工具）

### Future（v2+ 候选）

- Web UI 版本（让没装 Mac 客户端的用户也能从浏览器看 session）
- Agent 模板市场（社区分享 YAML 配置）
- Multi-Mac 编排（同一账号下多台机器协调跑 agent）
- 自建 P2P 隧道（绕过 relay，降低 hop 延迟，对中国大陆用户尤其重要）

---

## 四、用户故事

**Story 1 — vibe coder 首次上手 (5 分钟)**

1. 在 bento.novashang.com 注册账号 + 下载 Mac app
2. 打开 app → 提示登录 → OIDC 跳转到 auth.novashang.com → 回来
3. App 弹出引导："要不要帮你优化 tmux 配置？" → 点是 → 配置写入
4. 引导："要不要试试 agent wizard？" → 选目录 (~/code/myapp) → agent (Claude Code) → 2 个 pane → 点"启动"
5. 菜单栏出现 1 个 session、2 个 pane，状态为 Running
6. 点击 session → 系统 Terminal 弹出 tmux 视图，两个 Claude Code 在跑
7. 出门时打开 iPhone 上的 Bento，看到 "My Computers" → 自动连入，能看到两个 agent 的实时状态

**Story 2 — Linux server 上跑 agent，从 Mac 远控**

1. 用户在云上租了一台 Linux GPU 机器
2. `curl -fsSL get.bento.novashang.com | sh` → 装 daemon + CLI
3. `bento login` → 浏览器 OIDC → 返回 token
4. `bento relay-register` → daemon 连上 relay 注册成功
5. 用户在本地 Mac 上打开 Bento.app → "My Computers" 里多了一台 Linux box
6. 点开 → wizard 配 agent → 远程 tmux + agent 起来，结果通过 Mac/iOS 都能看到

**Story 3 — Power user iOS 直连（不用 Mac 客户端）**

1. 用户在 iOS app 加 host：`vps.mydomain.com:22`，用 key 认证
2. 直接走标准 SSH 进去，跟当前体验完全一样
3. 不接触 relay、不需要装 Mac 客户端

---

## 五、Open Questions

1. **Relay 计费粒度：** 按 host 数？按流量？按时长？建议按 host 数（清晰、可预测、对用户友好）
2. **Agent runtime 检测：** 用户没装 Claude Code 怎么办？wizard 是检测并提示安装，还是不管直接 `claude` 命令报 not found？建议预检测
3. **YAML 模板格式版本管理：** 加 `version: 1` 字段以备将来改造，但 v1 不实现迁移逻辑
4. **Linux 发行：** apt/yum 包 vs 单一 install.sh 脚本？前者正经但是慢，后者快但用户体验差。建议 install.sh + Homebrew (Mac/Linux 都能用)，后续补 apt
5. **Mac 发行：** Mac App Store (审核 + 沙盒约束) vs 直接 .dmg + Sparkle 更新 + notarize。建议先 .dmg，跨过 App Store 审核摩擦快速迭代
6. **WSL 检测：** daemon 启动时检测 `WSL_DISTRO_NAME` 环境变量；不在 WSL 的 Windows 直接 abort 并提示
7. **现有 tmux 配置冲突：** 用户已有 `.tmux.conf`，我们怎么改？建议 source 出来 + 在末尾追加 `source-file ~/.tmux.conf.bento`，新配置写在新文件里，可一键还原

---

## 六、里程碑（建议顺序）

| M | 内容 | 目的 | 估时 |
|---|---|---|---|
| **M1** | `bento-daemon` MVP + `bento` CLI + 本地 agent launcher | 验证"YAML → 活 pane" 的核心抽象到底好不好用，先在自己 Mac 跑通 | 2-3 周 |
| **M2** | Relay 单区域 + OIDC 接入 | 验证反向隧道方案，让 daemon 能从外部访问到 | 1-2 周 |
| **M3** | Bento.app (Mac 菜单栏) GUI | 把 wizard 和 session 列表做出来 | 3-4 周 |
| **M4** | iOS app 接入 relay 列出 "My Computers" | 闭环 vibe coder → iOS 远控的体验 | 1 周 |
| **M5** | Linux 安装脚本 + Homebrew + Mac .dmg 签名 | 公开发布 | 1-2 周 |

总计约 **8-12 周**，按一个人全职估。中间任何一个里程碑都可以单独让 alpha 用户试用，不必走完才能拿到反馈。

**最具信息量的下一步：** 不要从 Mac UI 开始。从 M1 的 CLI 跑通"YAML 配置 → 起 3 个 Claude Code 各干各的"开始，在自己机器上自己用，验证抽象。Mac 菜单栏只是这套引擎的 GUI 壳，没有引擎之前的 GUI 都是空的。
