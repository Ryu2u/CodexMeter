# CodexMeter

CodexMeter 是一款原生 macOS 菜单栏应用，让你的 ChatGPT/Codex 用量限额一目
了然——无需 Codex CLI、无需终端、没有子进程。登录一次 ChatGPT 账号，菜单栏
即可显示 5 小时与每周额度的剩余情况。

源码构建版还支持可选的 DeepSeek 余额，实验性的 MiniMax 套餐额度与智谱 GLM
Coding 套餐额度连接，以及把全部已连接平台并列展示的弹窗紧凑总览。这些平台接入
与总览不包含在 1.6.3 发行版中。

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
- **菜单栏自动选择窗口**：Codex 与外部百分比额度优先显示返回的 5 小时窗口，
  其次周窗口；没有标准窗口时使用剩余比例最低的窗口。明确选择的窗口始终优先，
  金额余额的选择规则不变。
- 六种菜单栏样式：同心环、条形+百分比、百分比下方条形、双紧凑条形、仅
  百分比、仅进度条。
- 所有来源的菜单栏与弹窗百分比均四舍五入显示为整数，保留内部计算精度，金额格式不受影响。
- **弹窗总览（源码构建版，尚未发布）**——同时列出所有可见的 Codex 额度窗口与
  已启用的外部连接：Codex 在前，外部连接按保存顺序排列，各平台以分隔线区分。
  每个平台默认折叠，点击展开查看原有详情，展开状态不跨启动保留。折叠时显示
  一行小圆环：环中心为剩余百分比，环下为窗口名；金额、不限量与不可用项以文本
  展示，不画环。展开 Codex 后仍显示剩余额度/剩余时间双圆环、重置倒计时与消耗
  节奏指示。
- **下降闪烁**——额度下降时，仅变化的百分比数字变红并保持半秒，随后在
  两秒内平滑恢复；百分号保持原色。开启"减弱动态效果"时立即恢复颜色。
- **Codex 弹窗自定义**——显示或隐藏每个额度窗口，选择驱动菜单栏指示器的窗口。
  GPT-Reserve 周额度默认隐藏。隐藏的窗口仍会继续刷新。
- **刷新机制**——Codex 启动时、后台约每分钟一次刷新；已启用的外部连接各自每五
  分钟轮询。打开弹窗与手动刷新覆盖 Codex 与全部已启用连接。每个来源独立显示
  加载/错误/过期状态与更新时间；失败时保留该来源的上次快照，不影响其他来源，
  各来源避免重复请求。
- **登录时启动**、浅色/深色/跟随系统外观，以及英语 / 简体中文 / 繁體中文
  本地化。
- **可选平台连接**——源码构建版可连接 DeepSeek 余额、实验性 MiniMax 套餐额度与
  智谱 GLM Coding 套餐额度。弹窗总览同时保留 Codex 与全部已启用连接；顶部来源选择器
  仅控制菜单栏指示器，不筛选或重排总览。
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
3. CodexMeter 是纯菜单栏应用（无 Dock 图标）。打开弹窗，展开 **Codex** 项并选择
   **使用 ChatGPT 登录**，随后在浏览器中完成流程；也可在 设置 → 通用中登录。

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
- 轮换出的新刷新凭据会在使用新访问令牌**之前**写入钥匙串。写入失败时
  不删除旧条目，并在内存中保留新凭据；点击刷新会先重试保存，避免再次使用
  已被服务端轮换的旧令牌。新凭据尚未保存就退出应用，仍可能需要重新登录。
- 临时断网、超时、限流或 403 不清除尚未过期的访问令牌，网络恢复后可以
  重试。配额接口返回 401 时只使访问令牌失效，保留钥匙串中的刷新凭据。
- 只有 OpenAI 明确宣告刷新凭据作废（`invalid_grant` 等）时，应用才会进入
  重新登录状态。设置中的 **断开连接** 会删除已存储的凭据。
- 后台读写钥匙串不会弹授权框；授权或存储失败会显示钥匙串错误并暂停自动
  重试，点击刷新后才允许请求系统授权。
- 额度仅用于展示：背后没有本地用量数据库、历史记录、令牌统计、通知或
  导出链路。
- OAuth 与额度接口为未公开的实验性接口，可能随时变更。

CodexMeter 不会抓取 ChatGPT 网页，也绝不读取 Codex 认证文件（如 CLI 的
`auth.json`）。

### 菜单栏指示器

Codex 与外部百分比额度均按窗口时长优先显示 **5 小时窗口**，其次回退到
**周窗口**；没有标准窗口时才使用剩余比例最低的窗口。明确选定的窗口会持久
保留，即使其他窗口变得更低也不会被替换；金额余额的自动选择不变。

### 外部平台连接（源码构建版）

设置 → 平台与连接 中添加 DeepSeek、MiniMax 或智谱，输入自己的凭据并明确选择区域。
弹窗总览始终显示 Codex 与所有已启用连接：Codex 在前，外部连接按保存顺序排列；
同一平台的多个连接分别显示，停用的连接不显示，每项可展开查看原有详情。顶部来源
选择器只决定菜单栏指示器使用的来源，不筛选或重排总览。每项显示自己的状态与更新时间；
失败或过期会保留该项的上次快照，不影响其他来源。外部连接沿用每五分钟独立轮询；
手动刷新同时请求 Codex 与全部已启用连接。修改密钥或区域会生成新的连接身份并清除
其显示快照；重命名则不会。

- **DeepSeek** 使用官方 `GET /user/balance` 接口（api.deepseek.com）。余额
  按币种分列，以金额形式展示，不会虚构额度百分比或重置时间。
  展开该连接后，详情另有本地峰谷时间进度条与倒计时：按北京时间，周一至周五
  `09:00–12:00`、`14:00–18:00` 为峰时，其余、周末（含调休上班）与法定
  节假日为谷时，依据 [DeepSeek 官方规则](https://api-docs.deepseek.com/zh-cn/quick_start/pricing/)。
  两条进度均以当前连续时段开始为基准，表示距各自下次开始的剩余等待时间；
  保留余额金额，不将时间当作额度，且不额外查询网络。
  日历目前覆盖 2026 年，法定日期依据
  [政府答复](https://www.jinan.gov.cn/col/col118356/art/2026/art_5c0f206d9dc945faa30f68f8e811be7e.html)，
  并与 [年度放假安排](https://www.beijing.gov.cn/zhengce/zhengcefagui/202511/t20251104_4258873.html)
  区分。官方未明确调休放假的工作日是否属谷时，相关峰时及未覆盖年度的
  工作日峰时显示待确认，倒计时不越过未知时段；需按年更新日历。
- **MiniMax** 为实验性支持。其 `GET /v1/token_plan/remains` 适配器遵循
  固定版本的 MiniMax 官方 CLI 契约（以适配器源码内固定值为准），中国区
  使用 api.minimax.cn，国际区使用 api.minimax.io。周加成可能使等效
  百分比超过 100%，因此进度与节奏按当前套餐的归一化容量计算。缺失字段
  显示为"不可用"，绝不当作零。该适配器有测试覆盖，但尚未经真实账号验证。
- **智谱** 为实验性支持，展示 GLM Coding 套餐的 5 小时与每周额度窗口。
  额度用剩余百分比与进度条呈现，按返回的剩余量与总量计算，不显示积分数值；
  保留剩余时间、使用节奏与重置倒计时。它使用 bigmodel.cn 控制台接口（未公开，
  可能随网站改版变动），凭据是从浏览器复制的登录 JWT——在 bigmodel.cn
  登录后，从请求的 `Authorization` 头或 `bigmodel_token_production` Cookie
  中复制整段 JWT 粘贴为凭据；这不是开放平台的 API Key。团队套餐的额度只在
  组织上下文中可见（且可能挂在非默认组织下，比如他人团队的席位），因此每次
  刷新会枚举账号的组织逐个探测，再回退个人套餐；个人账号无需组织。会话
  失效后额度会显示需要重新认证，重新复制一次新 JWT 即可。智谱界面不展示
  内部验收进度提示；示例数据、过期数据与查询错误仍有明确提示。

外部凭据仅保存在 CodexMeter 自己的钥匙串命名空间中；自动读取不会
触发钥匙串授权弹窗。任何推理流量都不会经过 CodexMeter。

## 设置

菜单栏 **设置** 入口打开一个可调大小的窗口，包含：

| 分类 | 内容 |
| --- | --- |
| 通用 | 语言、外观、登录时启动、Codex 账户（登录/断开连接） |
| 平台与连接 | DeepSeek / MiniMax / 智谱凭据与区域 |
| 菜单栏与弹窗 | 百分比额度来源的菜单栏样式、Codex 窗口可见性、指示器来源与布局预览（DeepSeek 余额以金额展示） |
| 开发者 | 外观调节、额度预览预设 |
| 关于 | 版本号、构建号、仓库、隐私、许可证 |

主弹窗以紧凑总览同时展示 Codex 与所有已启用外部连接（源码构建版功能，尚未发布），
折叠时各项显示小圆环摘要，展开可查看原有详情；顶部来源选择器只决定菜单栏指示器的
来源。通用平台页面按所选平台说明凭据与查询行为；ChatGPT 登录和账户说明仅用于
Codex 来源，应用品牌仍为 CodexMeter。

## 隐私与安全

- Codex 额度在明确的设备码登录后，通过 HTTPS 从 `wham/usage` 读取，使用
  禁用重定向的临时 URL 会话、20 秒超时和 512 KiB 响应上限。
- CodexMeter 不读取 Codex 认证文件，不抓取 ChatGPT 网页。
- 仅 OAuth 刷新凭据会被持久化，存放在 CodexMeter 自己的钥匙串项中。访问
  令牌只保留在内存中；断开连接即删除凭据。
- 不保留本地用量数据库，应用保存用户偏好与连接元数据。
- 外部连接的 API 密钥和会话凭据保存在 CodexMeter 自己的钥匙串命名空间中。
- 错误信息为本地编写的文案，绝不显示可能包含隐私数据的原始服务器错误或
  系统异常详情。
- 绝不记录账号邮箱、令牌或原始认证响应。
- 无任何自主分析或追踪。

App Sandbox 目前因历史原因（已移除的 App Server 子进程）保持禁用，可在
未来 Mac App Store 发行前重新评估。

## 已知限制

- 直接登录使用未公开的 OpenAI OAuth 与额度接口；接口变更可能导致失效。
- 从历史 ad-hoc 本地构建切换到固定签名 Debug 版时，系统首次读取已有登录凭据仍可能要求钥匙串授权；旧 ad-hoc 授权不保证自动迁移。
- 平台适配器仅有测试覆盖，尚未在真实 DeepSeek 或 MiniMax 账号上验证。
- 登录时启动功能需使用签名构建进行测试。
- 可下载的 DMG 为 ad-hoc 签名且未经公证，首次启动可能需要右键 → **打开**。

## 开发

从终端执行正常的签名 Debug 构建（需要可用的本地 Apple Development 证书）：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project CodexMeter.xcodeproj \
  -scheme CodexMeter \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

仓库中的 Debug 签名固定为本机证书（SHA-1 指纹：
`C5E2E0C2B85E27B5799A32884A10F3F700EE70BF`），并非随项目提供的通用证书；
其他贡献者需在本地 Xcode 签名设置中选择自己的 team 与证书。证书不可用时，
签名构建应明确失败，不会回退为可运行的 ad-hoc 构建。

仅需检查编译时，可显式关闭签名；该产物不能当作日常运行版本，也不能用于
界面或登录时启动测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
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
