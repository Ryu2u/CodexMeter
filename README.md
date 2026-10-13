# CodexMeter

CodexMeter 是一款原生 macOS 菜单栏应用，让你的 ChatGPT/Codex 用量限额一目
了然——无需 Codex CLI、无需终端、没有子进程。登录一次 ChatGPT 账号，菜单栏
即可显示 5 小时与每周额度的剩余情况。

源码构建版还支持可选的 DeepSeek 余额，以及实验性的 MiniMax 套餐额度与
智谱 GLM Coding 套餐额度连接。这些平台接入不包含在 1.6.3 发行版中。

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![Version](https://img.shields.io/badge/version-1.6.3-blue)

> [!NOTE]
> CodexMeter 是非官方社区项目，与 OpenAI 无关联，也未获得其认可。

## 预览

### 菜单栏弹窗

<p align="center">
  <img src="docs/images/codexmeter-menu-bar-popover.png" width="380" alt="CodexMeter 菜单栏弹窗，展示带重置倒计时和详细进度条的额度窗口">
</p>

### 弹窗自定义

<p align="center">
  <img src="docs/images/codexmeter-popover-customization.png" width="560" alt="CodexMeter 弹窗自定义窗口，包含额度窗口可见性与菜单栏指示器控制">
</p>

## 功能特性

- **ChatGPT 直接登录**——通过应用内的设备码流程完成登录，无需安装或运行
  任何其他软件。
- **菜单栏指示器**，双同心进度环：
  - 外环：剩余额度；
  - 内环：重置前的剩余时间。
- **菜单栏自动选择窗口**：账号返回 5 小时窗口时优先显示它，否则显示周
  窗口，仅在未知套餐结构下退回最受约束的窗口。在设置中明确选择的窗口
  始终优先。
- 六种菜单栏样式：同心环、条形+百分比、百分比下方条形、双紧凑条形、仅
  百分比、仅进度条。
- **弹窗**列出返回的每个额度窗口，包含剩余额度/剩余时间双进度条、重置
  倒计时与消耗节奏（正常/偏快）指示。
- **下降闪烁**——额度下降时，仅变化的百分比数字变红并保持半秒，随后在
  两秒内平滑恢复；百分号保持原色。开启"减弱动态效果"时立即恢复颜色。
- **弹窗自定义**——显示或隐藏每个额度窗口，选择驱动菜单栏指示器的窗口。
  GPT-Reserve 周额度默认隐藏。隐藏的窗口仍会继续刷新。
- **刷新机制**——启动时、后台约每分钟一次、弹窗打开时以及手动刷新。刷新
  失败时保留上次快照并标记为可能过期；请求不会重叠。
- **登录时启动**、浅色/深色/跟随系统外观，以及英语 / 简体中文 / 繁體中文
  本地化。
- **可选平台连接**——DeepSeek 余额、实验性 MiniMax 套餐额度与智谱 GLM
  Coding 套餐额度，在弹窗顶部选择后替代 Codex 显示。
- **开发者选项**——实时菜单栏外观调节（带预览）、确定性额度状态预设、
  自定义额度/时间滑块、JSON 配置导出，以及一键恢复默认外观。

## 快速开始

### 环境要求

- macOS 13 或更高版本。
- 支持 Codex 的 ChatGPT 账号。
- 从源码构建时需要支持本项目的 Xcode。
- 可选平台连接需要对应平台的 API 密钥。

### 构建运行

```bash
git clone https://github.com/Ryu2u/CodexMeter.git
cd CodexMeter
open CodexMeter.xcodeproj
```

1. 选择 `CodexMeter` scheme，目标设备选 **My Mac**。
2. 按 **Run** 运行。
3. CodexMeter 是纯菜单栏应用（无 Dock 图标）。打开弹窗，选择
   **使用 ChatGPT 登录**，然后在浏览器中完成流程。

### 下载安装

从 [GitHub Releases](https://github.com/Ryu2u/CodexMeter/releases) 下载
`CodexMeter-1.6.3.dmg`，拖入"应用程序"文件夹。安装包为 ad-hoc 签名且未经
公证，macOS 可能拦截首次启动：右键点击应用选择 **打开** 并确认一次即可。

当前源码已移除内置更新。需要升级时，请到 GitHub Releases 查看已发布版本，
手动下载安装包，退出 CodexMeter 后替换旧应用。

## 工作原理

### Codex 直接登录

CodexMeter 只有一个 Codex 来源：明确的设备码登录。

1. 应用向 OpenAI 请求设备码，并自动打开浏览器进入
   `auth.openai.com/codex/device`，验证码已同时复制到剪贴板。
2. 使用 ChatGPT 账号登录并确认验证码。
3. CodexMeter 用授权码换取令牌，开始轮询官方客户端使用的同一 `wham/usage`
   额度接口——后台约每分钟一次，弹窗打开与手动刷新时也会请求。

凭据处理：

- 仅持久化刷新凭据，保存在 CodexMeter 自己的钥匙串项中
  （`com.codexmeter.codex-oauth.v1`，仅限本机访问）。
- 访问令牌只存在于内存中，绝不落盘。
- 轮换出的新刷新凭据会在使用新访问令牌**之前**持久化，因此轮换中断也不
  会导致登录失效。
- 只有 OpenAI 明确宣告凭据作废（`invalid_grant` 等）时，应用才会丢弃凭据
  并回到登录状态；代理拦截等原因造成的 401/403 会保留凭据，关闭代理或
  切换节点后刷新即可恢复。设置中的 **断开连接** 会删除已存储的凭据。
- 额度仅用于展示：背后没有本地用量数据库、历史记录、令牌统计、通知或
  导出链路。
- OAuth 与额度接口为未公开的实验性接口，可能随时变更。

CodexMeter 不会抓取 ChatGPT 网页，也绝不读取 Codex 认证文件（如 CLI 的
`auth.json`）。

### 菜单栏指示器

自动选择优先显示 **5 小时窗口**（账号返回时），其次回退到 **周窗口**，
仅在未知额度结构下使用最受约束的窗口。你可以在 设置 → 菜单栏与弹窗 中
固定任意返回的窗口；该选择会持久保留，即使其他窗口变得更低也不会被替换。

### 外部平台连接（源码构建版）

设置 → 平台与连接 中添加 DeepSeek、MiniMax 或智谱，输入用户自己的凭据并
明确选择区域。在弹窗顶部选择某个连接后，将替代 Codex 视图；未选择时显示
Codex。已启用的连接每五分钟独立轮询，也支持手动刷新。修改密钥或区域会
生成新的连接身份并清除其显示快照；重命名则不会。

- **DeepSeek** 使用官方 `GET /user/balance` 接口（api.deepseek.com）。余额
  按币种分列，以金额形式展示，不会虚构额度百分比或重置时间。
- **MiniMax** 为实验性支持。其 `GET /v1/token_plan/remains` 适配器遵循
  固定版本的 MiniMax 官方 CLI 契约（以适配器源码内固定值为准），中国区
  使用 api.minimax.cn，国际区使用 api.minimax.io。周加成可能使等效
  百分比超过 100%，因此进度与节奏按当前套餐的归一化容量计算。缺失字段
  显示为"不可用"，绝不当作零。该适配器有测试覆盖，但尚未经真实账号验证。
- **智谱** 为实验性支持，展示 GLM Coding 套餐的 5 小时与每周额度窗口
  （credits 总量、剩余、重置时间）。它使用 bigmodel.cn 控制台接口（未公开，
  可能随网站改版变动），凭据是从浏览器复制的登录 JWT——在 bigmodel.cn
  登录后，从请求的 `Authorization` 头或 `bigmodel_token_production` Cookie
  中复制整段 JWT 粘贴为凭据；这不是开放平台的 API Key。会话失效后额度会
  显示需要重新认证，重新复制一次新 JWT 即可。

外部凭据仅保存在 CodexMeter 自己的钥匙串命名空间中；自动读取不会
触发钥匙串授权弹窗。任何推理流量都不会经过 CodexMeter。

## 设置

菜单栏 **设置** 入口打开一个可调大小的窗口，包含：

| 分类 | 内容 |
| --- | --- |
| 通用 | 语言、外观、登录时启动、Codex 账户（登录/断开连接） |
| 平台与连接 | DeepSeek / MiniMax / 智谱凭据与区域 |
| 菜单栏与弹窗 | 菜单栏样式、各额度窗口可见性、指示器来源窗口 |
| 开发者 | 外观调节、额度预览预设 |
| 关于 | 版本号、构建号、仓库、隐私、许可证 |

## 隐私与安全

- Codex 额度在明确的设备码登录后，通过 HTTPS 从 `wham/usage` 读取，使用
  禁用重定向的临时 URL 会话、20 秒超时和 512 KiB 响应上限。
- CodexMeter 不读取 Codex 认证文件，不抓取 ChatGPT 网页。
- 仅 OAuth 刷新凭据会被持久化，存放在 CodexMeter 自己的钥匙串项中。访问
  令牌只保留在内存中；断开连接即删除凭据。
- 不保留本地用量数据库，应用只存储用户偏好设置。
- 外部连接的 API 密钥保存在 CodexMeter 自己的钥匙串命名空间中。
- 错误信息为本地编写的文案，绝不显示可能包含隐私数据的原始服务器错误或
  系统异常详情。
- 绝不记录账号邮箱、令牌或原始认证响应。
- 无任何自主分析或追踪。

App Sandbox 目前因历史原因（已移除的 App Server 子进程）保持禁用，可在
未来 Mac App Store 发行前重新评估。

## 已知限制

- 直接登录使用未公开的 OpenAI OAuth 与额度接口；接口变更可能导致失效。
- 安装包为 ad-hoc 签名，更换或重新构建应用后，系统可能在首次读取登录凭据时
  要求输入开机密码授权钥匙串访问，点"始终允许"或重新登录即可。
- 平台适配器仅有测试覆盖，尚未在真实 DeepSeek 或 MiniMax 账号上验证。
- 登录时启动功能需使用签名构建进行测试。
- 可下载的 DMG 为 ad-hoc 签名且未经公证，首次启动可能需要右键 → **打开**。

## 开发

从终端构建：

```bash
xcodebuild \
  -project CodexMeter.xcodeproj \
  -scheme CodexMeter \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

运行核心单元测试：

```bash
swift test
git diff --check
```

若 `xcode-select` 指向的是 Command Line Tools 而非完整 Xcode，请在执行
上述命令前设置 `DEVELOPER_DIR`。

纯额度计算、OAuth 协议、平台适配器与弹窗配置位于 `CodexMeter/Core`。
`Package.swift` 仅将该目录暴露给 Swift Package Manager，使核心逻辑独立于
macOS UI 进行测试。完整架构与验证清单见 [AGENTS.md](AGENTS.md)。

### 发布安装包

构建 Release 应用后，签名并严格验证应用包：

```bash
Scripts/sign_ad_hoc_release.sh /path/to/CodexMeter.app
```

用校验过的应用制作 DMG，并上传到对应的 GitHub Release。

## 参与贡献

欢迎提交 Issue 和 Pull Request。提交变更前请执行：

```bash
swift test
git diff --check
```

涉及菜单栏或弹窗的改动还需要 UI 冒烟测试：启动一个签名应用实例，点击
状态栏图标，确认弹窗能打开且控件可响应。

## 许可证

CodexMeter 基于 [MIT 许可证](LICENSE) 发布。

## 免责声明

Codex 和 OpenAI 是 OpenAI 的商标。本项目是一个独立工具，上游实验性接口
变更时可能停止工作。
