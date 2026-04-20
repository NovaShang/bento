# 移动端 Terminal App · 产品设计文档(v0.2)

> 第二次整理。相较 v0.1,关键变化:引入语音/键盘模式系统、三状态机、Quick Keys 按需浮现、单指纯滚动、微信式语音模型。

---

## 一、产品定位

**一句话:** 一个 iOS/iPadOS 上的 SSH terminal,为触屏和移动场景重新设计,核心创新是 voice input、手势交互、画布式分屏,以及自动感知 pane 状态的智能交互层。

**三个核心卖点:**

1. **Voice Input**(微信式):按住 pane 录音,松开前的方向手势决定"发送 / 取消 / 转 shell 命令 / 仅输入"
2. **快速 TUI 响应**:Quick Keys 根据 pane 状态自动浮现,让 `y/n`、Enter、Esc 等高频按键点击可达
3. **画布分屏**:多 pane 在一张逻辑画布上,支持双指缩放平移,活跃/非活跃 pane 视觉区分

**目标用户:** 所有在 iPhone/iPad 上需要用 SSH 连远程服务器的开发者。vibe coder(并发用多个 AI coding agent)是高价值自然用户。

**与竞品的差异:**

| 维度 | Blink / Termius | Happy Coder | **本产品** |
|---|---|---|---|
| 通用 SSH terminal | ✓ | ✗ | ✓ |
| 触屏手势优化 | 一般 | N/A | **核心** |
| Voice input | ✗ | 简单版 | **微信式深度集成** |
| tmux control mode | ✗ | ✗ | **独家** |
| 画布多 pane | ✗ | ✗ | **独家** |
| pane 状态自动识别 | ✗ | 仅 agent 特定 | **通用三状态机** |

---

## 二、核心概念模型

### 2.1 术语

- **Host(主机)**:一个远端服务器配置
- **Workspace(工作区)**:对应一个 tmux session
- **Canvas(画布)**:对应一个 tmux window,有固定逻辑尺寸
- **Pane(面板)**:画布上的一个终端窗口,跑一个 shell/TUI
- **Viewport(视口)**:屏幕显示的画布区域

### 2.2 画布模型(核心创新)

传统 terminal 假设"终端必须填满屏幕"。本产品把这个假设拿掉:

**终端有自己的逻辑尺寸(画布),屏幕是窥探它的窗口(视口)。**

好处:

- 多设备 attach 同一 tmux 时不再尺寸冲突
- 活跃/非活跃 pane 字号差异用视觉 scale 实现,不需要真 resize
- 小屏幕显示多 pane 时用双指缩放平移导航
- iPhone/iPad/macOS 共享交互范式,只是视口大小不同

### 2.3 Pane 布局

保持 **tmux 语义**:新 pane 通过 `split-window` 创建,遵循二叉树森林。

画布提供**视觉自由**(缩放、平移、放大),不提供**布局自由**(任意摆放)。

### 2.4 模式系统(核心交互抽象)

逻辑上区分两种使用状态:

**🎤 语音模式**(默认场景:单手、不需要键盘)
- 单指用于滚动、语音、点击切换
- 双指用于画布导航

**⌨️ 键盘模式**(默认场景:双手、调用了键盘)
- 单指用于滚动、切换 + 弹键盘、文本选择
- 双指用于画布导航
- 键盘输入主导

**模式切换逻辑:**

- 键盘弹起 → 自动进入键盘模式
- 键盘收起 → **保持键盘模式**(只是键盘隐藏,避免频繁切换)
- 手动切换:顶部状态栏右侧的模式按钮(🎤/⌨️)
- **默认值**:Per-host 记住上次使用的模式。初次安装时若有物理键盘 → 键盘模式,否则 → 语音模式。

### 2.5 三状态机

每个 pane 在任何时刻处于以下三态之一:

| 状态 | 语义 | 视觉 | Quick Keys |
|---|---|---|---|
| **Working** | 程序在跑,不需要介入 | 中性(默认) | 不显示 |
| **Idle** | 空闲 / 超时无输出,可以介入但不紧急 | 略暗 | 不显示 |
| **Awaiting Input** | 明确等用户决定,必须回应 | 琥珀色背景 | 浮现在 pane 下方 |

三个状态**互斥且穷尽**,是整个视觉和交互的核心组织原则。

---

## 三、交互设计

### 3.1 两种模式下的完整手势表

#### 语音模式

| 手势 | 行为 |
|---|---|
| 单指按下立刻拖动 | 滚动 pane 历史 |
| 单指按住不动 >200ms | 触觉反馈 + 进入录音 |
| 录音中,手指保持不动 | 实时转写 + 方向提示悬浮在 pane 上 |
| **录音后直接松开(无方向)** | 转写注入 pane,不发送 |
| **录音后上推松开** | 转写 + `\n` 注入(发送) |
| **录音后左或右推松开** | 转写 → LLM 转 shell command → 注入并发送 |
| **录音后下推松开** | 取消 |
| 单指快速点击(<200ms,无拖动) | 切换活跃 pane(不弹键盘) |
| 单指双击 pane 里文字 | 选词 + 手柄调整选区 |
| 双指捏合 | 画布缩放 |
| 双指拖动 | 画布平移 |
| 双击空白区 | 画布"适应屏幕" |
| 点击 pane 标题栏 ⛶ 图标 | 进入 focus 模式 |
| 点击 Quick Keys 按钮 | 发送对应按键给该 pane |

#### 键盘模式

| 手势 | 行为 |
|---|---|
| 单指按下立刻拖动 | 滚动 pane 历史 |
| 单指快速点击 | 切换活跃 pane + 弹出键盘 |
| 单指点击屏幕空白区 | 收起键盘(模式保持键盘模式) |
| 单指双击 pane 里文字 | 选词 + 手柄调整选区 |
| 键盘输入 | 输入到活跃 pane |
| 键盘工具栏特殊键 | 发送对应按键 |
| 双指捏合 | 画布缩放 |
| 双指拖动 | 画布平移 |
| 双击空白区 | 画布"适应屏幕" |
| 点击 pane 标题栏 ⛶ 图标 | 进入 focus 模式 |
| 点击 Quick Keys 按钮 | 发送对应按键给该 pane |

#### 两模式共享的

- 双指手势(画布导航)
- UI 按钮操作(focus、分屏、菜单)
- Quick Keys 按钮
- 模式切换按钮(顶部状态栏右侧)

### 3.2 Voice Input(微信式)详细

**录音阶段:**
- 用户按住 pane 超过 200ms 触发
- 触觉反馈告知"可以说话了"(light impact haptic)
- pane 边框高亮(明确目标)
- pane 上或手指附近浮现悬浮层,含:
  - 实时转写文字
  - 四方向提示(↑ 发送 / ← → AI shell / ↓ 取消 / 松开 仅输入)
  - 手指滑向某方向时对应提示高亮 + 微振动

**手指位置就是录音目标** —— 保留"按哪个 pane 对哪个 pane 说话"的空间直觉。

**结束阶段:**
松开前手指的方向决定:
- 无方向(直接松开)→ 转写注入,不发送
- 上推 → 转写 + `\n`(发送)
- 左或右推 → 转写发给 LLM,返回 shell command,注入并发送
- 下推 → 取消

**滚动和录音的关系:**

- 按下立刻移动 → 滚动
- 手指停住不动 → 滚动停止,200ms 计时开始
- 停住 200ms → 振动 + 进入录音
- 两个行为**自然过渡,不冲突**——滚动没有副作用(只是视觉滚动了),用户想切换意图只需停住手指

**语音识别引擎:**
- 默认 Apple SFSpeechRecognizer(本地、免费、低延迟、中英混合好)
- Settings 可切换到 Whisper(用户自带 OpenAI API key 或本地 endpoint)

**LLM 转 shell command:**
- MVP 只支持用户自带 API key
- 默认把 pane 最后 50 行作为上下文发给 LLM(脱敏规则待定)
- 首次启用弹窗告知"终端内容会发给你配置的 LLM 服务"
- Settings 提供上下文行数、prompt 模板自定义、脱敏开关

### 3.3 Quick Keys(状态感知的快捷按键)

**何时浮现:**

当 pane 状态变为 **awaiting_input** 时,Quick Keys 自动浮现在该 pane 下方(紧贴底部边框内侧,半透明背景 + 清晰按键)。

**显示哪些按键:**

根据匹配到的 profile 决定。内置 profile(MVP 3-5 个):

- **Claude Code**:[Y] [N] [Enter] [Esc] [↑] [↓]
- **Codex / 其它 AI agent**:类似 Claude Code
- **通用 shell**([y/N] 类 prompt):[Y] [N] [Enter]
- **Vim**(normal mode):[Esc] [:] [/] [hjkl]
- **Git interactive**:[Y] [N] [Enter] [Esc]

**消失条件:**

- 用户点了某个 Quick Key → 发送后立刻消失
- pane 状态离开 awaiting_input(有新输出、状态变 working 或 idle)→ 淡出消失
- 切换活跃 pane 不影响其它 pane 的 Quick Keys(各自独立管理)
- 长时间无操作不消失(prompt 可能等几分钟)

**多 pane 同时 awaiting 的处理:**

- 活跃 pane 的 Quick Keys 完整显示
- 非活跃 pane 的 Quick Keys 先用小徽章提示,点击 pane 切到活跃后展开为完整按键
- 避免多个 pane 同时显示完整按键导致屏幕混乱

**点 Quick Key 不改变活跃 pane:**

类似 iOS 通知中心点回复按钮——操作完成,焦点保持原位。

### 3.4 三状态机详细

**识别机制(按优先级):**

1. Hook 协议(v2,暂不做)
2. Title 匹配(tmux `pane title` 或 terminal OSC title)
3. 输出内容正则匹配(pane 最后 N 行)
4. tmux silence 监测(无输出 > 阈值 = idle)
5. 兜底 = working

**配置:**

- 每个 pane 根据当前运行的程序(`pane_current_command`)自动匹配 profile
- 用户可在 pane 菜单里手动改 profile
- **MVP 只提供内置 profile,用户自定义 profile 放 v2**

**视觉:**

- Working:pane 背景同主题底色
- Idle:略暗一档(叠 5% 黑色)
- Awaiting Input:琥珀色半透明背景叠层
- 活跃 pane 的状态色更饱和,非活跃 pane 略弱
- Settings 里用户可分别改三个状态的背景色(深色/浅色主题分别配置)

**触达用户的提示:**

- **App 前台**:视觉(背景色 + Quick Keys)+ 轻触觉(selection haptic)
- **App 后台或锁屏**:Live Activity 更新(锁屏 / 灵动岛显示 awaiting 状态),可点击直达 pane
- **不发推送通知**——推送会中断用户,awaiting 不是紧急状态
- **节流**:同一 pane 重复 awaiting 不重复振动,多 pane 短时间先后 awaiting 合并一次

**用户控制:**

- 触觉、Live Activity 可分别在 Settings 里关闭

### 3.5 画布交互

**缩放:**
- 双指捏合
- 范围:20% - 300%
- 纯物理缩放,字号跟着变,不做"概览模式"(不值得)
- 缩放实现:视觉 scale,tmux 列宽不变,TUI 不重绘(零闪烁)

**平移:**
- 双指拖动
- 适应屏幕:双击空白区一键回到"画布填满视口"

**画布默认尺寸:**

- 新建 workspace:默认跟随设备(iPhone 竖屏 ~40×80、iPad 横屏 ~100×40)
- 新建界面有小入口选预设("标准终端 80×24" / "大画布 120×40" / "超大画布 200×50" / "自定义")
- Attach 现有 session:画布尺寸 = tmux 现有尺寸,视口以"适应屏幕"初始显示

**多设备 attach 策略:**

- 默认创建 grouped session(`tmux new-session -t xxx -s xxx-mobile`)
- 手机布局独立,共享底层 window/pane
- 连接时可选三个选项:手机专属视图(推荐)/ 共享桌面布局 / 全新 session

### 3.6 活跃 / 非活跃 pane 视觉

- 活跃 pane:100% 缩放(舒适字号)+ 边框高亮 + 轻阴影
- 非活跃 pane:较小缩放(比如 40-60%,视觉 scale 实现)+ 边框暗色 + 降低不透明度
- 切换活跃仅改 CSS scale,不触发 tmux resize

### 3.7 Pane 标题栏(UI 按钮)

每个 pane 顶部一条 24pt 标题栏:

- **左侧**:pane title + 当前状态指示
- **右侧**:放大图标 ⛶(点击进入 focus),更多菜单 ⋯(含关闭 / 重命名 / 分屏 / 改 profile)

标题栏自身不承担手势(不做"长按标题栏"之类),避免学习成本。

### 3.8 Focus 模式

- 点击 ⛶ 图标进入
- pane 占满视口,其它 pane 隐藏
- 屏幕顶部出现"⛶ 退出 focus"细条,点击退出
- 双指捏合(画布缩放)也自然退回全局视图

### 3.9 文本选择

- 双击 pane 里的文字 = 选词(两模式通用)
- 选词后屏幕出现两个手柄(起点/终点),拖动调整
- 浮出操作条:复制 / 全选 / 矩形模式 / 取消
- 复制后进 iOS 系统剪贴板 + 振动 + toast 提示
- 手柄拖到 pane 边缘自动触发滚动 scrollback

### 3.10 滚动行为

**单指纯滚动是不可妥协的底层假设。**

- 单指按下立刻移动 → 滚动(零延迟,iOS 标准体验)
- 跟所有其它手势通过"是否立刻移动"区分
- 滚动期间 pane 进入 tmux copy-mode(客户端透明处理,用户无感)
- 滚动到底部自动恢复跟随最新输出
- 多 pane 场景:各 pane 滚动状态独立

### 3.11 模式切换 UI

**顶部全局状态栏布局:**

```
[☰ menu] [current host · workspace]                [🎤/⌨️] [⚙]
```

- 左侧:hamburger menu(主机列表、tmux window 列表、Settings)
- 中间:当前主机名 + workspace 名
- 右侧:模式切换按钮(🎤/⌨️)、其它全局控制

**切换反馈(UI 细节 v2 细化):**

- 图标切换动画
- 触觉 selection 反馈
- 语音→键盘:自动弹键盘
- 键盘→语音:自动收键盘

---

## 四、连接和基础设施

### 4.1 主界面

主机列表(卡片/列表 UI)。每张卡片:
- 主机名 / 别名
- 用户名 + 地址
- 在线状态 + 最近连接时间

点击进入该主机的 terminal。右上角"+"添加主机。

### 4.2 网络传输

- MVP 默认 SSH,添加主机时可勾选 mosh
- 连接断线提供手动重连按钮,不做自动重连
- tmux session 持久化已经解决"断线重连后状态丢失"的大部分场景

### 4.3 SSH 密钥

- 支持导入私钥文件 + App 内生成新密钥对
- 存 iOS Keychain(Face ID / Touch ID)
- 公钥可导出
- Secure Enclave 放 v2

### 4.4 tmux 集成

- 用 tmux control mode(`tmux -CC`)
- 客户端 UI 直接对应 tmux 真实状态
- 首次连接检测远端 tmux,无则提示安装
- 对用户完全透明(用户不需要知道"tmux"这个词)

---

## 五、视觉 / 字体 / 配色

### 5.1 字体

- 内置 3-5 种编程字体:SF Mono / JetBrains Mono / Fira Code / Menlo
- 预打包 Nerd Font patched 变体(支持 Powerline / git / 文件图标)
- 用户自定义字体放 v2

### 5.2 配色主题

- 内置 5-8 套经典主题:Dracula / Solarized Dark+Light / Gruvbox / Tokyo Night / Nord / One Dark / Monokai
- 支持导入 iTerm2 `.itermcolors` 文件(继承整个 iTerm2 主题生态)
- App 内主题可视化编辑器放 v2

### 5.3 键盘工具栏

- iOS Input Accessory View,系统键盘上方
- 键盘收起时一起消失
- 默认:Esc / Tab / Ctrl / ↑↓←→ / `|` / `/` / `~` / `-`
- Ctrl 粘滞键
- 长按看按键变体
- Settings 可自定义

### 5.4 tmux window 暴露

- 放在 hamburger menu 或下拉菜单里
- 叫"工作区"或"标签页"(具体命名上线前定)
- 新手打开 app 只看到一个画布,不需要理解 window 概念

---

## 六、反馈和触达

### 6.1 触觉(iOS Haptic Engine)

- 录音开始:light impact
- 方向越过阈值:selection
- 发送成功:success
- 取消:warning 或无
- Settings 一键关闭

不做声音反馈(使用场景多在公共场合)。

### 6.2 Live Activity

- 每个 awaiting_input 状态的 pane 在锁屏/灵动岛显示
- 合并多个 pane 为"X 个 pane 等待输入"
- 点击直达对应 pane
- 不发推送通知

### 6.3 Onboarding

首次启动显示**可跳过的手势卡片**:

- 卡片 1:按住说话 + 方向结束手势(微信式语音模型)
- 卡片 2:单指滚动 + 双击选词
- 卡片 3:双指缩放平移画布
- 卡片 4:模式切换(🎤 / ⌨️)
- 卡片 5:Quick Keys 自动浮现

用短视频/GIF 演示。可跳过,Settings 里永远能找到"手势说明"页面。

---

## 七、商业化

**MVP 阶段完全免费。**

- 重心:产品打磨、用户积累、口碑验证
- 一年后或到用户数里程碑再决定收费方案
- 免费期内自担:开发时间 + App Store 年费 + 可能的服务器成本

**功能分层(提前想清楚,不急实施):**

- 永久免费:SSH、tmux 集成、分屏、基础 voice、基础三状态识别、内置主题
- 未来可付费:iTerm2 主题导入、Whisper 语音、LLM 集成、iCloud 同步、Hook 协议、自定义 profile、Apple Watch 端、多设备同步

---

## 八、MVP 范围

### 必做

**连接基础:**
- SSH 连接 + 密钥管理(Keychain)
- tmux control mode 集成
- 主机列表 UI
- 键盘工具栏、字体(含 Nerd Font)、主题(含 iTerm2 导入)

**模式系统:**
- 语音 / 键盘两模式
- Per-host 记住上次模式
- 顶部状态栏模式切换按钮
- 键盘弹起自动进入键盘模式

**三大卖点:**
- Voice input(微信式):按住录音 + 四方向结束手势 + LLM 转 shell
- Quick Keys:基于三状态机自动浮现,内置 3-5 个 profile
- 画布分屏:双指缩放平移,适应屏幕,focus 模式,活跃字号差异

**三状态机:**
- Title 监测 + 输出匹配 + tmux silence
- 内置 profile:Claude Code / Codex / 通用 shell / vim / git interactive
- 背景色用户可配置

**其它:**
- 单指纯滚动(基础保障)
- 文本选择(双击选词 + 手柄)
- tmux window 菜单化暴露
- 多设备 attach 默认 grouped session
- Live Activity(awaiting 状态同步到锁屏/灵动岛)
- Onboarding 卡片
- 触觉反馈

### 不做(v2+)

- mosh 自动选择 / 自动重连
- 用户自定义 Quick Keys profile / 状态识别规则
- Hook 协议(发布规范让 agent 接入)
- Whisper 语音升级
- App 内主题可视化编辑器
- 用户导入自定义字体
- Apple Watch 端
- macOS Catalyst 版
- iCloud 配置同步
- SFTP 文件传输
- Secure Enclave 密钥

### 永远不做

- Claude Code 专用解析或 UI(保持通用 terminal 定位)
- 内容理解 / 状态卡片(home view 类)
- 绑定任何特定 AI agent 生态
- Android 版(至少前两年)

---

## 九、待决策 / 未深入

MVP 不阻塞,后续迭代再定:

- 后台连接保活策略
- 错误处理 UI(连接失败、认证失败、网络错误)
- iCloud 配置同步
- 多语言支持(先中英文)
- 技术栈:SwiftUI vs UIKit / terminal 渲染引擎
- TestFlight 种子用户招募
- App Store 发布素材
- tmux window 具体命名("工作区" vs "标签页")
- iPad + 物理键盘 / Apple Pencil / 触控板的特殊优化

---

## 十、所有决策记录

按讨论顺序,共 32 个产品决策。加粗的是影响架构的关键决策。

**初始定位:**
1. 左右滑都发 shell command,区分只为人体工学
2. LLM MVP 只支持自带 API key
3. tmux window 暴露但藏在菜单里

**第一批细节:**
4. 分屏数量不限制
5. Onboarding 用可跳过的手势卡片
6. 实时转写浮层在 pane 上或手指附近
7. 语音识别默认 Apple SR,可配置 Whisper
8. LLM 默认包含 pane 最后 N 行上下文
9. 长按阈值 200ms
10. 触觉反馈为主,不做声音

**连接和视觉:**
11. 主界面是主机列表卡片,非 shell 式
12. SSH 密钥导入+生成,存 Keychain
13. 网络 MVP 默认 SSH,用户可选 mosh
14. 字体内置多种 + Nerd Font 支持
15. 配色内置多套 + iTerm2 主题导入
16. 键盘工具栏作为 Input Accessory View
17. 商业化免费一年再定

**架构级决策:**
18. **画布模型**:终端有逻辑尺寸,屏幕是视口
19. Pane 布局保持 tmux 语义(二叉树)
20. 画布默认跟随设备,新建时可选更大
21. 画布缩放纯物理,不做概览模式
22. 多设备 attach 默认创建 grouped session
23. 双击选词,不做长按选词
24. Focus 模式用 UI 按钮,不做手势

**模式系统(重大架构):**
25. **引入语音 / 键盘两种模式**
26. 打开 workspace 默认 = 上次退出时的模式(per-host)
27. 键盘收起保持键盘模式(不自动切回语音)
28. 语音模式下双击选词也生效(两模式一致)
29. 模式切换按钮在顶部状态栏右侧

**语音模型校正:**
30. **Voice input 改为微信式**:按住录音 + 松开前方向手势,不是持续滑动
31. **单指纯滚动**:任何单指立刻拖动都是滚动,跟录音不冲突(因为录音要求手指不动 200ms)
32. 按键手势(原短滑发↑↓)取消,重新定位为"快速响应 TUI"

**Quick Keys 和状态机:**
33. Quick Keys 按需浮现在 awaiting pane 下方(不是常驻底部条)
34. **三状态机**:Working / Idle / Awaiting Input
35. 识别机制 MVP:Title + 输出匹配 + tmux silence,3-5 个内置 profile
36. 三状态背景色用户可配置
37. Awaiting 提示:振动 + Live Activity,不发推送

---

## 附录 A:跟 v0.1 的主要差异

如果你看过 v0.1,这些地方变了:

- **引入模式系统**:v0.1 没有,所有手势挤在单指里
- **引入三状态机**:v0.1 只有 title 监测,现在是完整状态模型
- **Quick Keys 变成按需浮现**:v0.1 的"按键手势"(短滑发键)被取消,取而代之是智能浮现的 Quick Keys
- **Voice 交互模型校正**:v0.1 我理解成"按住 + 方向滑动",实际是"按住录音 + 松开前方向",像微信
- **单指拖动 = 滚动**成为硬约束:v0.1 没专门讨论滚动,假设跟桌面一样
- **活跃字号切换改为视觉 scale**:v0.1 是"真 resize",画布模型确立后自然改
- **Live Activity 加入**:v0.1 没提
- **选词改为两模式通用**:v0.1 倾向键盘模式独占

## 附录 B:仍需要你留意的推测

文档里几处是我顺着逻辑推的,不一定严格是你亲自拍板的。回看时请留意:

- 三状态的具体视觉强度(我给的"略暗 / 琥珀色"是推荐默认,你只说了"用户可配置")
- Quick Keys 多 pane 同时 awaiting 时"非活跃 pane 显示小徽章"(我的推测,可能你想全都展开)
- Live Activity 的"合并多 pane 显示"(我的建议,但 Live Activity 本身技术限制可能影响)
- Profile 具体哪些(5 个是我列的,Claude Code + Codex + shell + vim + git)
- 模式切换按钮图标(🎤 和 ⌨️ 是占位,实际可能用 SF Symbols)

这些地方你有不同想法随时说。
