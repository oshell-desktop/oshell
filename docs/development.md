# 开发与测试

## 本机应用

需要现代 macOS、Swift 6 工具链、Xcode Command Line Tools 和 Python 3。依赖固定在 `Vendor/`。

```sh
bash scripts/build.sh
open dist/OShell.app
```

默认只构建当前 Mac 的原生架构，输出 `dist/OShell.app`，不生成 DMG、PKG 或其他架构的应用。编译缓存位于 `work/build/`。源码路径会映射为统一前缀，避免将构建者的主目录写入二进制。

正式 app 不编入 UI 测试、内存诊断或预览入口。兼容版发布交给 [GitHub Actions](releases.md)。

## 开发测试应用

```sh
bash scripts/build.sh --tests
python3 scripts/run-ui-tests.py --list
python3 scripts/run-ui-tests.py directory-picker-stress terminal-clock tab-bar-menu
python3 scripts/run-ui-tests.py resource-review
python3 scripts/run-ai-tests.py
python3 scripts/run-ui-tests.py auth-concurrency login-password-save proxy-catalog global-proxy
python3 scripts/run-ui-tests.py tab-window-merge tab-detach tab-reorder multi-window
python3 scripts/run-ui-tests.py --group sessions
```

测试应用单独输出到 `work/test-app/OShell.app`，缓存位于 `work/build-tests/`，不会覆盖正式 app。通用 UI 运行器会复制应用、分配独立 Bundle ID 和临时数据目录，结束时清理测试副本；结果写入 `validation/ui-*.json`。图片粘贴使用 `image-paste`、`paste-scroll`，同步状态使用 `sync-settings`、`directory-sync`、`toolbar-actions`；远端图片上传另运行 `run-sftp-reuse-tests.py`。可用 `--app` 指定其他带测试标记的应用。`tabs`、`sessions`、`memory` 分组替代原来重复的批量包装脚本。`stress` 输出性能采样，不代表所有负载下的性能保证。

测试入口必须显式指定独立的 `OSHELL_DATA_DIR`；正式应用会在读取数据前拒绝测试参数。不要将开发测试指向实际会话目录或真实服务器。UI 检查需要 macOS 图形会话。

资源回归 `resource-review` 验证 200 个标签的 1000 次无变化刷新复用菜单与图标、快捷键与未读状态正确更新、隐藏和最小化时钟停止计时器，以及同步对象销毁时注销计时器。输出的耗时仅代表该合成场景，不等于整个应用的性能提升比例。

会话范围与未修改 Desktop 的互通：`python3 scripts/test-session-sync-interop.py --desktop-source /path/to/oshell-desktop`。测试只读 Desktop 源码，用临时 Go overlay 注入合成回归，不修改对端项目。

核心检查：

```sh
binary_dir="$(swift build --scratch-path work/build/swift -c release --show-bin-path)"
"$binary_dir/OShellCoreChecks"
```

需要本机 SSH / FTP / WebDAV 测试服务的场景使用对应脚本：

```sh
python3 -m venv work/test-tools
work/test-tools/bin/pip install -r scripts/requirements-test.txt
work/test-tools/bin/python scripts/run-tab-actions-tests.py
work/test-tools/bin/python scripts/run-session-tests.py
work/test-tools/bin/python scripts/run-sftp-reuse-tests.py
work/test-tools/bin/python scripts/run-ssh-clone-tests.py
work/test-tools/bin/python scripts/run-local-tool-tests.py --connection-status-only
work/test-tools/bin/python scripts/run-webdav-tests.py
```

`run-ai-tests.py` 仅使用回环模拟模型服务及合成密钥，覆盖请求、上下文遮盖、图片、会话隔离、命令填入、取消、重定向拒绝及加密存储；不需要真实 API 密钥。

这些脚本默认使用测试应用和一次性本地账号。保存密码认证及明文不落盘检查统一由 `run-session-tests.py` 覆盖，移除了需手工启动固定端口服务的旧密码测试入口。更新、文件传输、代理、隧道和内存循环等专用脚本继续保留；它们与通用 UI 检查的测试服务需求不同。加密启动测试会自行生成临时样本，不依赖维护者工作目录中的文件。

确实需要单独调试 Intel 兼容 UI 时，可使用 `package-release.py --flavor legacy --apps-only --tests`，输出 `work/test-release/legacy/OShell.app`；测试应用禁止打包或发布。常规开发无需执行此步骤。

## 更新 README 截图

使用隔离测试应用生成真实界面的示例图片，不连接服务器、不使用个人会话。执行 `python3 scripts/run-ui-tests.py readme-screenshots terminal-chrome` 后，从 `validation/` 中选取 `readme-sessions.png`、`readme-files.png`、`terminal-chrome-split-review.png` 及 `terminal-chrome-empty-0-dark-review.png`，检查内容和布局后更新 `docs/images/` 对应图片。终端输出和文件列表均为固定演示数据；不要用个人工作窗口的截图替换。

设置六宫格使用 `python3 scripts/run-ui-tests.py readme-settings` 生成，输出为 `validation/readme-settings-grid.png`，核对后更新 `docs/images/settings-overview.png`。只采集设置页内容，示例配置不保存；终端预览使用独立绘图上下文，避免截图中文字发生偏移。

## 清理构建历史

```sh
python3 scripts/clean-local-builds.py
python3 scripts/clean-local-builds.py --apply
```

第一条只列出目标；第二条执行清理。保留当前本机架构的正式 `dist/OShell.app`、源码、Git、依赖及工具环境、发布密钥和最后一次检查摘要。旧构建、测试副本、安装包、过期工作记录和生成缓存会被删除。清理前验证 app 签名与架构，拒绝删除受 Git 跟踪的文件；同时检查进程与已加载的执行文件、框架，跳过仍在使用的副本。若无法确认已加载文件，会保留重命名后的旧 App 副本。清理后再次核对 app 内容。`work/`、`dist/` 和 `validation/` 是开发产物目录，不用于存放个人会话数据。

清理不会变更系统中已安装的 OShell 或 `~/Library/Application Support/OShell`。之后重新编译会重建缓存。

## 项目结构

- `Sources/OShell/`：原生界面、终端、文件管理、更新与同步。
- `Sources/OShell/TestSupport/`：显式测试构建才启用的 UI 回归和诊断实现。
- `Sources/OShellCore/`：配置、密码保护、协议参数和数据模型。
- 其他 `Sources/OShell*/`：认证、代理和外部启动辅助程序。
- `Tests/OShellCoreTests/`：核心行为检查。
- `scripts/`：构建、隔离测试、源码检查和发布工具。
- `shell-integration/`：可选的远端 Shell 集成。
- `Vendor/`：固定依赖、上游源码和许可证，不能当作构建历史删除。

## 提交前

```sh
python3 scripts/check-public-source.py --working-tree
python3 scripts/check-public-source.py --index
python3 scripts/check-public-source.py --history main
python3 scripts/check-public-source.py --app dist/OShell.app
```

同时人工检查 `git diff --cached`。不要提交真实会话、密码、密钥、令牌、机器日志或未脱敏截图。第三方版权署名保持原样；变更说明放在 `CHANGELOG.md`，调试记录留在忽略的本地目录中。

正式构建使用固定代码签名证书，配置与备份方法见 [发布指南](releases.md#固定代码签名身份)。无维护者签名私钥时，个人开发构建可显式设置 `OSHELL_ALLOW_ADHOC=1`；测试构建默认使用独立的 ad-hoc 身份。

AI 发送授权验证：`bash scripts/build.sh --tests` 后执行 `python3 scripts/run-ai-tests.py`。测试服务仅监听回环地址，使用合成身份/证据/图片；接收端核对实际字节的 SHA-256 与授权快照一致，并验证默认不带元数据/历史/旧图片、字段选择、派生资料撤回、跨任务/目标/模型/凭据变更失效、取消、单次使用和显式重试。`validation/ui-ai-assistant.json` 与 `validation/ai-transport.json` 是本机报告，不包含真实服务密钥或终端资料。

四种模型协议由 `AIProtocol.swift` 负责纯数据转换，联网仅允许 `AISendAuthorization` 许可通过的 `AIClient`。`AIProtocolTest.swift` 和同一回环测试服务器验证各协议的鉴权、正文、图片及多段响应，默认历史排除、选择与撤回，以及拒绝/截断/工具调用/限流/重定向/取消。Responses 不回传服务端 ID，Gemini 地址中的模型必须与授权模型一致。无真实供应商密钥时，不得宣称已通过线上服务联调。

经用户授权后，可运行 `python3 scripts/run-ai-live-test.py --endpoint http://127.0.0.1:8787/v1 --model <授权模型>` 验证真实服务；密钥由隐藏输入读取，只经匿名管道送入测试 App 内存，不写入配置、参数或报告。使用安装了 `paramiko` 的 Python 并加 `--ssh`，还会启动一次性回环 SSH 服务。该测试只发送合成问题，覆盖无终端提问、Chat Completions / Responses 回复、真实本地 PTY 与 SSH 命令卡填入，以及取消、状态变化、不回车和不广播；不执行模型返回的命令。结果为 `validation/ui-ai-live.json`。它是显式选择的本机联调工具，不加入 CI，不读取用户 AI 配置。

渠道预设由 `AIProviderPreset.swift` 提供本机配置与兼容参数，`AIProviderPresetTest.swift` 验证预设切换清空旧密钥、同一预设与自定义编辑保留、v1/v2 迁移及 v3 加密存储、输出上限授权失效、真实客户端标识、服务端拒绝后不回退。回环接收端逐渠道核对密钥归属和 max_tokens；不得用其他工具的 User-Agent 伪装 OShell，也不把本机测试当成套餐客户端授权或真实供应商联调。

AI Markdown 使用本机 AppKit / TextKit 渲染，不使用 WebView 或 HTML 导入器，不加载远程图片；仅接受用户主动点击的 HTTP/HTTPS 链接。`AIMarkdownTest.swift` 随 `run-ai-tests.py` 检查排版、表格、窄面板、代码原文和围栏边界，并由真实助手界面验证命令卡、授权与回复顺序。发布仍需保留 macOS 10.13 的编译兼容性。

`AIHistoryContinuationTest.swift` 覆盖真实 v1 加密文件读取、v2 文字来源和依赖恢复、图片与派生回答剔除、撤回／清空的持久化、独立续聊切换及 UI 授权。`run-ai-tests.py` 在回环服务端额外核对续聊默认不重发历史、选中资料才发送、清空后不再发送，并继续逐请求比较授权摘要。AI 历史 v2 是本机格式，不是共享配置 v2。

多渠道 AI 配置使用本机加密 settings v4，读取旧 v1/v2/v3 时使用稳定的兼容渠道／模型标识，保存设置时迁移。`AIModelCatalog.swift` 按渠道与模型 UUID 解析单一路由，请求对象拒绝未解析的完整目录，不携带其他渠道密钥。`AIModelCatalogTest.swift` 经原生设置页、对话选择器及回环服务验证新增／删除／默认模型、并发编辑保护、密钥与接口隔离、选择切换后的授权失效、历史恢复及配置删除后拒绝自动回退；历史和回复仅记录选择标识或模型名称，不复制服务密钥。

AI 预算默认输出 131,072 Token、上下文 524,288 字符，上下文最大 1,048,576 字符；已有模型预算保持不变。`AIBudgetTest.swift` 随 `run-ai-tests.py` 验证上下限、旧配置迁移、中文字符计数、512K／1M 完整请求冻结及超限拒绝。原生设置页回归覆盖恢复默认预算仅修改当前模型、应用前不落盘；回环接收端验证四种协议的输出参数与授权字节一致，模型发现回归验证新导入模型的预算。测试使用合成内容，不需要真实供应商密钥。

模型发现由 `AIModelDiscovery.swift` 执行独立 GET，不读取任何会话对象。路由和格式依据 [OpenAI Docs models.list](https://developers.openai.com/api/reference/resources/models/methods/list)、[Anthropic Models](https://platform.claude.com/docs/en/api/models/list) 和 [Gemini models.list](https://ai.google.dev/api/models)；继续使用所选协议既有的鉴权版本，不猜测第三方网关的备用入口。只接受同一列表地址的分页游标，拒绝重定向，限制响应大小、页数和总耗时。`python3 scripts/run-ai-discovery-tests.py` 验证请求仅含当前渠道鉴权、GET 无请求体、分页、错误、取消及原生选择导入。显式授权的回环真实服务可用 `scripts/run-ai-live-test.py --endpoint <URL> --model <ID> --models-only` 只读验证；密钥仍从隐藏输入经匿名管道传入，不保存。

AI 流式回复由 `AIStreamDecoder.swift` 按字节解析 SSE，覆盖 UTF-8 跨包、CRLF、心跳、结束标记和协议错误；忽略内部思考和签名。授权快照包含 stream 参数及 Gemini 的实际流式地址。`AIStreamDecoderTest.swift` 验证四种协议、异常终止和分段敏感内容遮盖；`run-ai-tests.py` 回环服务分批输出 SSE，验证完整回复前已有增量文字及即时等待卡片，并保留 JSON 响应兼容回归。未完成的文字不产生命令卡或可重发历史，完整校验后才保存。协议依据 [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses)、[Anthropic streaming](https://platform.claude.com/docs/en/build-with-claude/streaming)、[Gemini streamGenerateContent](https://ai.google.dev/api/generate-content#method-models.streamgeneratecontent)。

只读排查通过 `AIDiagnostics.swift` 的固定枚举模板执行，模型文本不能成为 shell 参数；授权绑定终端 ID / stamp、SSHConnectionGroup、对话与解析后的模型设置。`scripts/run-ai-diagnostics-tests.py` 使用一次性回环 Paramiko 服务（只回合成结果、不执行 shell）与合成模型 HTTP，验证真实 OpenSSH 仅一次认证、无额外 exec 通道、命令经原 PTY 输入、默认不增加执行前等待（加 --execution-wait 验证每条命令等待 8 秒）、用户输入后不再自动回车、执行结果经二次授权才进入 HTTP。测试同时拒绝未知 ID、shell 注入和超额计划；模型和服务响应均视为不可信资料。

`AITerminalQuery.swift` 通过 `SSHConnectionLease` 复用原认证传输，使用 fail-closed 的 OpenSSH multiplex exec 通道执行固定只读模板。输入为 null，stdout/stderr 分开限量读取，并等待双流 EOF 与进程退出后采用结果；超时/取消仅终止本次 ssh 客户进程。查询不再读写交互 PTY，也不注入 printf 边界标记。`AIExecutionView` 在原标签页展示命令、输出和退出码，远端数据仅作为 NSTextView 文本展示，不执行终端控制序列。任务绑定原连接、模型和对话；原终端的人工输入触发接管，其他标签输入或应用失焦不影响任务。

服务排查命令依据 [systemctl show](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html) 与 [journalctl](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html)，仅构造固定的属性和日志过滤选项。`AIReadOnlyQuery.automaticQueries` 从当前问题确定自动范围，范围外查询需确认；执行解析要求整个查询列表是授权集合的子集（先检查整批再执行）。`run-ai-diagnostics-tests.py --services` 通过真实 OpenSSH PTY 验证服务状态和指定日志文件模板、双层 Shell 参数引用、可选倒计时、取消接管及结果审阅；模拟服务不执行真实系统命令。

本机 `scripts/build.sh` 在目标目录旁的临时目录完整组装、签名和检查 App，再替换整个 bundle，不再原地截断正在映射的可执行文件。`install-local-app.py` 检测到目标 App/辅助进程运行时，将新版本发布到独立 `OShell-preview-*.app` 路径；构建输出给出实际路径。生成失败保留 staging 便于排查，发布失败回滚原 App。`test-install-local-app.py` 验证运行中目录保留、旧文件句柄内容不被覆盖及失败回滚。历史窗口关闭专项：`run-ui-tests.py ai-history-close` 覆盖取消、Esc、⌘W、搜索/预览焦点、重复打开关闭及视图释放。

`SSHClientLocale` 为本机 SSH 提供 `LC_CTYPE=UTF-8`，在私有临时配置中加载原用户/系统配置或显式 `-F` 配置，最后应用 `SendEnv -LANG -LANGUAGE -LC_*`。仅把移除规则放在命令行会被后读入的默认配置重新追加，无法防止 locale 转发。原 `SSHEnvironment.remoteClient` 继续用于清理继承变量，共享配置格式不变。`SSHClientLocaleTest` 用真实 `ssh -G` 检查别名、账号、端口和非 locale 转发保留；`run-ssh-clone-tests.py` 增加中文认证 Banner 和原样八进制文本断言，同时验证服务端未收到语言变量、克隆仅一次认证。依据 [OpenSSH UTF-8 输出处理](https://github.com/openssh/openssh-portable/blob/master/utf8.c) 和 [SendEnv 文档](https://man.openbsd.org/ssh_config#SendEnv)。

`run-ui-tests.py terminal-interrupt` 使用无用户插件的本地 zsh 和临时原始输入接收程序，测量 Ctrl+C 按键处理与 PTY 回包耗时；同时用加密的未知版本 AI 设置验证快捷键查找只访问内存、不反复读取解密。窗口事件和菜单安装不直接调用 `AISettings.load()`；启动及设置更新时刷新 AI 配置缓存。测试不修改用户 shell 配置，也不把组件耗时当成所有输入法、桌面事件与远端网络场景的端到端保证。

直接发送仍构造不可变 `AIRequest` 并消费单次 token，授权来源为用户点击发送或仍有效的只读任务；“更多 → 选择额外资料并发送”保留可选精细选择。`AISendReceipt` 只保存已清理的资料清单、图片摘要、接收方和请求摘要/结果，不持有请求 settings/API 密钥。历史 v3 兼容读取 v1/v2；旧版遇到 v3 会拒绝覆盖。审阅是面板内只读视图，不触发网络，不抢占终端窗口焦点。

平铺输入焦点由 WorkspaceController 在布局重建前清空旧终端 responder、重建后恢复当前选中终端；正文点击只更新选中元数据，不在 becomeFirstResponder 回调中重建视图。WorkspaceWindow 在交接前拒绝隐藏、已移走或已关闭终端，保留原 responder；命令栏/AI 输入框焦点不由布局重建强行替换。`run-ui-tests.py tiled-input terminal-focus quicksend-focus arrangement-scroll` 覆盖三组六标签、重建、点击、文字与 readline 控制键、真实 PTY 路由、命令栏焦点及滚动。

AI 排查任务自行订阅绑定对话的模型结果，自动续查不依赖正在展示的 AI 面板。发送许可固定在原对话、原终端和原模型；切换界面不会改变发送目标。TerminalPane 的任务级输入回调覆盖模型思考阶段和命令执行阶段，只有实际进入该终端的人工/托管输入触发暂停。`run-ai-diagnostics-tests.py --background` 验证切换标签、其他标签输入和应用失焦后仍在原连接完成查询；原终端接管仍撤销待执行命令。

同一 AI 对话的普通发送通过 `conversationDraft(settings:)` 选入近期已授权上下文，按接口/协议/鉴权身份绑定接收方；换渠道或恢复历史需明确确认。原始 `sendDraft()` 保持资料候选与单次授权边界，自动排查仍使用任务专用资料清单。历史回答保留依赖用于传递撤销；已授权但因预算省略的旧资料不会阻止近期回答进入上下文。`run-ai-context-tests.py` 使用无记忆回环模型核验十轮实际请求、角色、跨会话隔离、渠道确认、撤销/清空，并覆盖四类协议的长上下文截取。

### 窗口切回后的输入延迟诊断

`python3 scripts/run-ui-tests.py activation-latency` 使用独立数据目录和 24 个空白标签，验证无关窗口/隐藏标签不触发光标刷新，并记录原生窗口切回前后的按键派发耗时。设置 `OSHELL_ACTIVATION_METAL=1` 可覆盖 Metal 路径。此测试不包含真实跨应用输入法切换、SSH 网络和远端回显，不能单独作为实际 SSH 卡顿已消失的证明。

`python3 scripts/run-ui-tests.py fullscreen-activation` 需要已解锁的 macOS 桌面，使用临时应用、24 个标签、本机 PTY 的 cat 回显及一个独立文本框应用，执行三轮原生全屏跨应用切换，分别记录激活、模拟鼠标点击、首键派发、收到回显、绘制及主线程停顿耗时。`OSHELL_ACTIVATION_METAL=1` 覆盖 Metal。测试包含真实应用焦点交接，但输入事件为合成 ASCII，不覆盖人工输入法组词或 SSH 回显；锁屏导致无法进入全屏时不能视为产品回归。两份临时应用退出或超时后都会清理，不关闭用户正在使用的 OShell。`sync-settings` 使用合成加密 WebDAV 配置验证激活同步立即返回、凭据解密在后台执行、准备期间取消不产生过期失败；`multi-window` 验证返回同一工作区不重建菜单项目，切换工作区仍正确绑定动作。共享信封、凭据格式和同步合并协议未改变。

诊断构建可通过环境变量 `OSHELL_INPUT_LATENCY=1` 启用慢输入记录；只有按键排队或派发耗时达到 50 毫秒时才写入统一日志，subsystem 为 `app.oshell`、category 为 `InputLatency`。记录只有排队时长、派发时长和距离窗口激活的时间，不包含按键、文字、主机或凭据。排队慢但派发快通常指向主线程此前被其他任务占用；派发本身慢则需采样输入处理路径。需要继续定位 GPU 时，可同时启用现有 `SWIFTTERM_PROFILE=1`，观察 Metal.CurrentDrawable、Metal.RenderPass 和 Metal.BuildDrawData 的 signpost。

焦点通知仅订阅终端当前所属窗口；移除或移动终端时重新绑定。不可见终端不排队 Metal 焦点重绘，也不进入 drawable 获取路径；窗口重新可见时由已有生命周期通知恢复绘制。

### 全局代理回归

全局策略测试运行在独立数据目录，验证开关与设置入口、覆盖/恢复会话代理、代理链、共享序列化不变、损坏/缺失配置拒绝连接。以下网络测试只使用临时本机服务器和合成凭据；Python 环境需要 Paramiko。GUI 端到端用例请依次运行，避免多个测试应用争抢前台窗口。

```sh
python3 scripts/test-proxy.py work/test-app/OShell.app/Contents/Helpers/OShellProxy
work/file-tests-venv/bin/python scripts/run-proxy-chain-tests.py
OSHELL_TEST_GLOBAL_PROXY=1 work/file-tests-venv/bin/python scripts/run-file-tests.py
OSHELL_TEST_GLOBAL_PROXY=1 work/file-tests-venv/bin/python scripts/run-sftp-reuse-tests.py
```

全局代理网络 fixture 会统计实际 SOCKS5 连接；独立 SFTP/SCP 传输必须经过代理，终端、文件管理及 SCP 复用场景必须只建立一次代理连接和一次 SSH 认证。共享配置仍须按 `AGENTS.md` 执行真实 Swift/Go 往返测试。

### AI 权限、接管及上下文压缩回归

`AIPermissionMode` 从旧 `autoApproveReadOnly` 向三档权限兼容迁移；执行前仍调用 `validateExecution`，模型不能自行升级权限。`AIStopGesture` 只接受 Ctrl+C 或 500ms 内两次 Esc，普通输入不进入 AI 占用的 PTY。停止记录中断状态并取消模型流，原会话 ID、历史来源和上下文授权保留，执行许可不继承。

`AIContextCompaction` 使用每模型 Token 预算与百分比阈值，分批压缩已授权文字并保留近期记录。摘要独立保存来源 ID 与接收方，原始资料不替换；撤销来源后摘要及派生回答失效。自动任务也通过此上下文路径发送。失败、取消、目标或设置代际变化时不应用摘要。

运行 `bash scripts/build.sh --tests`、`python3 scripts/run-ai-compaction-tests.py`、`python3 scripts/run-ai-context-tests.py`、`python3 scripts/run-ai-tests.py`；新回归用四种协议的回环模型验证压缩前后实际 HTTP 内容、接收方隔离、撤销、失败及取消。另用安装了 Paramiko 的 Python 执行 `scripts/run-ai-diagnostics-tests.py`，覆盖原 PTY 空闲确认、逐条审批、查询/变更自动审批与明确接管。所有数据为合成数据，测试不连接真实 AI 服务或用户 SSH 主机。

AI 终端输出采集使用增量字节状态机，OSC 在首个 BEL 或 ST 结束符停止，CSI 和其他控制字符串独立处理；分包或 UTF-8 字节边界不能改变正文，原始 PTY 数据仍原样传入终端。`AITerminalCaptureTest` 覆盖结束符组合和每个分包位置。使用安装了 Paramiko 的 Python 运行 `scripts/run-ai-diagnostics-tests.py --osc-st` 验证原 PTY 输出经真实 HTTP 到达模型，`--echo-only` 验证只收到回显时点名失败查询、暂停后续命令和模型请求，不计入证据。资源查询空正文也暂停并标明可能为空结果或采集异常；文件读取、日志检索和文件变更允许空输出，但明确记录不确定性，不伪造退出码或推断没有匹配项。
