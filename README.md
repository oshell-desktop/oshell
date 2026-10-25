# OShell

<img src="Assets/Brand/OShell-icon.png" alt="OShell 图标" width="112">

原生 macOS SSH 客户端，使用 Swift、AppKit 和 SwiftTerm 构建。支持多会话管理、可拖动分屏和文件传输，不依赖浏览器运行时。

## 适合的工作场景

- **开发调试**：本地终端与多个远程环境并排显示，搜索日志、切换会话，按任务组织标签和分屏。
- **日常运维**：通过共享代理和多级 SSH 跳板连接服务器，按会话或分组发送命令，浏览和传输文件。
- **多台 Mac 共用会话**：通过 iCloud / 自定义同步目录或 WebDAV 共享加密会话数据，每台设备保留自己的字体、主题和快捷键。

## 功能

| 功能 | 支持内容 |
| --- | --- |
| AI 助手 | 故障分析、持续终端任务（三档权限、空闲确认、按钮/Ctrl+C/双击 Esc 接管、发送记录审阅）、命令编写/解释、Markdown 回复、同一对话自动上下文、可配置 Token 窗口与阈值摘要压缩、数据发送授权、图片与文本附件、命令卡片、本机加密历史与历史续聊；可配置多渠道、多模型并在对话中切换；支持四种原生/兼容协议及 Kimi Code、DeepSeek、MiniMax、GLM 预设 |
| 会话管理 | 目录树、搜索过滤、多选连接和删除、直接重命名、复制会话、⌘C / ⌘V 复制粘贴配置；导入 SecureCRT / Xshell 会话 |
| 左侧会话栏 | 显示 / 隐藏、全部展开 / 收缩，以及与会话管理共用的右键操作；默认 ⌘⇧B 切换显示，可自定义 |
| 快捷链接 | `/Links` 同时容纳实际会话和快捷引用；一键添加当前会话，拖动排序或移入目录 |
| 标签与布局 | 标签悬浮信息逐项复制、多窗口、标签排序、各标签栏独立编号、自定义分组及显示 / 隐藏、嵌套分屏、水平 / 垂直 / 瓷砖排列和专注模式 |
| SSH 与代理 | 密码、私钥、SSH Agent、集中管理的共享代理、最多 8 级代理链、SSH 跳板、端口转发和保持活动；并发连接的认证请求排队处理 |
| 连接复用 | 同一会话重复打开时避免重复占用隧道端口；SFTP 可复用已认证的 SSH 连接 |
| 快速操作 | 快速命令、按当前会话 / 分组 / 指定分组 / 本窗口发送、同步输入、终端搜索、多行粘贴预览及复制去除首尾空白；图片可保存本机或上传 SSH 后粘贴路径，支持记住及恢复提醒 |
| 本地工具提示符 | `OShell >` 支持行编辑、命令历史、Ctrl+A / E、Ctrl+R 搜索和命令名补全；完整 Shell 使用本地终端 |
| 文件管理 | SFTP、FTP、SCP，类型图标、权限及用户 / 组、动态传输限速、当前文件标签的上传下载记录；另支持 rz/sz |
| 断点续传 | SFTP 普通文件可暂停、继续或失败重试；恢复前校验源文件及已传片段 |
| 外观与输入 | 界面深浅主题与终端配色独立设置、系统字体及内置 Cascadia Code / DejaVu Sans Mono、彩色 Emoji 与宽字符选项、关键词 / 正则高亮、可配置悬浮本地时钟 |
| 密码与同步 | 主密码加密、可选本机 Touch ID 解锁、仅本机使用的加密密码保存；共享会话必须启用主密码 |
| 更新与诊断 | GitHub Releases 签名更新、顶部更新入口、同步状态图标、本地同步日志与冲突确认 |

README 描述当前源码能力，安装包的实际功能以对应 [Release](https://github.com/oshell-desktop/oshell/releases) 和 [变更日志](CHANGELOG.md) 为准。

### 标签跨窗口迁移

将标签标题拖到另一个 OShell 窗口的内容区域即可合并；拖到标签栏的插入标记处可指定位置。空窗口和分组区域也可接收。整个标签及其中的分屏、连接和输出历史一起迁移，无需重新登录。

- 拖到所有 OShell 窗口外的空白处可创建新窗口；Esc 取消拖动。
- 移走最后一个会话标签后，原窗口自动关闭。
- 原窗口的文件管理窗口会转交目标窗口，已有连接和传输继续运行。

### 多设备同步

在“设置 → 多设备同步”中先选择一种方式：

1. **同步目录**：选择 iCloud Drive 或其他各设备可访问的文件夹，共享文件为 `configuration.json`。
2. **WebDAV**：填写 HTTP 或 HTTPS 父目录地址、账号及密码（建议 HTTPS）。自动复用或创建其下的 `oshell/`，共享文件为 `oshell-vault.json`。例如填写 `https://example.com/my_data_dir/`，默认使用 `my_data_dir/oshell/oshell-vault.json`；父目录须已存在且账号有创建目录及读写权限。旧目录中已有直接存放的同步文件时继续使用原位置，不自动搬迁。

HTTP 连接会明文传输 WebDAV 账号密码；同步文件仍由主密码加密。建议仅在可信网络使用 HTTP，HTTPS 保留证书校验。

**默认只同步会话资料**（会话、目录、快捷链接、代理及加密密码）。可另外勾选客户端设置与高亮规则、快速命令、默认会话属性；未勾选类别保留各端现状。同步策略仅本机保存，支持自动/手动、启动检查、定时检查、修改后同步与失败重试。同步目录和 WebDAV 二选一；各设备使用相同主密码，程序始终使用独立的本地工作副本，离线时仍可使用和编辑会话。

顶部同步图标以圆环显示正在同步，点击可立即同步、查看阶段进度、取消本次操作或进入配置。首次接入已有数据需要确认；真实双端冲突由用户选择保留版本，不按时间直接覆盖。详情见 [多设备同步使用说明](docs/usage.md#icloud自定义同步目录与-webdav)。

共享格式与 oshell-desktop 保持兼容。OShell 对未勾选类别保留远端字段且不应用到本机；勾选的类别使用同一 v2 格式同步。对端的范围选择行为取决于其版本。未自动选择 WebDAV 子目录的客户端，应填写实际的 `…/oshell/` 地址。参见 [配置兼容协议](docs/configuration-protocol.md)。

### 文件传输的使用范围

SFTP 断点续传限当前运行期间、同一文件标签中的普通文件；目录、FTP、SCP 暂不支持续传。关闭标签或退出程序后不能自动恢复断点。传输记录保存在内存，不参与同步。详见 [使用指南](docs/usage.md#文件管理传输记录)。

## 界面预览

以下为 OShell 实际界面的功能示例，使用虚构会话、示例文件和终端输出，不包含真实连接信息。截图布局可能与最新开发版本略有不同。

### 首页与快速入口

从首页新建 SSH 会话或打开本地终端，顶部工具栏集中提供会话、文件、分屏及搜索入口。

![OShell 首页：品牌图标、快捷入口与顶部工具栏](docs/images/welcome.png)

### 多会话与分屏

在同一窗口中查看开发日志与运维输出，配合标签切换、拖动分屏和底部快速发送栏操作。

![OShell 终端分屏：同时查看应用开发与运行日志](docs/images/terminal-split.png)

### 会话管理

按目录管理 SSH、SFTP 和 FTP 会话，支持搜索、多选连接、直接改名和行尾快捷编辑。

![OShell 会话管理：目录分类、连接信息和行尾编辑按钮](docs/images/session-management.png)

### 文件管理

浏览远程文件，查看类型、大小、权限及所属用户和组，并为每个文件标签设置传输速率。

![OShell 文件管理：文件类型、权限、用户组和传输限速](docs/images/file-manager.png)

### 设置一览

常规、主题与配色、快捷键、文字显示、本地时钟和安全六个页面，集中展示 OShell 的个性化设置。点击图片可查看大图。

[![OShell 设置六宫格：常规、配色、快捷键、文字、时钟和安全](docs/images/settings-overview.png)](docs/images/settings-overview.png)

## 系统要求与安装

| 构建 | 运行系统 | 架构 |
| --- | --- | --- |
| Apple Silicon 版 | macOS 13 或更新版本 | arm64 |
| Intel 兼容版 | macOS 10.13 或更新版本 | x86_64（amd64） |

macOS 10.13 是兼容构建目标，仍需真实旧系统上的进一步验证。具体安装包、签名和公证状态以对应 Release 说明为准。

后续 Release 只编译并发布上述两种 DMG，不再生成旧名称 `macOS13-x86_64` 兼容副本；已有 Release 保持原样。依赖旧文件名的 Intel 客户端需手动安装一次 macOS 10.13 Intel 包，之后使用统一更新通道。支持当前包名的客户端仍可通过 `arnolixi/oshell` 或 `oshell-desktop/oshell` 检查更新。

从 [GitHub Releases](https://github.com/oshell-desktop/oshell/releases) 选择适合系统和架构的 DMG，将应用拖入 Applications。升级前退出应用，再覆盖安装。没有已发布安装包时，可以从源码构建。

## 从源码构建

需要现代 macOS、Swift 6 工具链和 Xcode Command Line Tools。终端组件、更新框架和传输辅助程序的固定版本依赖位于 `Vendor/`。

```sh
OSHELL_ALLOW_ADHOC=1 bash scripts/build.sh
open dist/OShell.app
```

默认只生成当前 Mac 架构的正式 app，不包含开发测试入口；其他系统的安装包由 GitHub Actions 构建。构建无需访问维护者的签名私钥，也无需使用真实服务器或会话配置。发布签名、跨架构构建和测试步骤见下方文档。

## 文档

- [使用指南](docs/usage.md)
- [SecureCRT / Xshell 会话导入教程](docs/session-import.md)
- [其他终端会话转换指南（借助 AI 开发脚本）](docs/session-conversion.md)
- [Shell 集成](shell-integration/README.md)
- [开发与测试](docs/development.md)
- [构建与发布更新](docs/releases.md)
- [安全说明](SECURITY.md)
- [贡献指南](CONTRIBUTING.md)
- [变更日志](CHANGELOG.md)

## 许可证

OShell 原创代码及项目资源采用 [GNU GPL 第 3 版](LICENSE)（`GPL-3.0-only`），不提供任何担保。第三方组件保留各自的版权和许可条款，见 [第三方声明](THIRD_PARTY_NOTICES.txt)。
