# 开发与测试

## 本机应用

需要现代 macOS、Swift 6 工具链、Xcode Command Line Tools 和 Python 3。依赖固定在 `Vendor/`。

```sh
bash scripts/build.sh
open dist/OShell.app
```

默认只构建当前 Mac 的原生架构，输出 `dist/OShell.app`，不生成 DMG、PKG 或其他架构的应用。编译缓存位于 `work/build/`。源码路径会映射为统一前缀，避免将构建者的主目录写入二进制。

正式 app 不编入 UI 测试、内存诊断或预览入口。兼容版发布交给 [GitHub Actions](releases.md)。

安装包仅复制运行所需文件，不包含仓库文档和测试脚本。五个辅助程序仅通过命令行或 IPC 提供接口，Release 链接时隐藏动态导出符号，便于移除未引用代码；主应用保留原有链接策略。Sparkle 头文件和模块描述保留在编译用 XCFramework 中，嵌入运行包时去除。字体、许可证、运行时更新组件和集成测试使用的 Ed25519 签名工具须保留。

## 开发测试应用

```sh
bash scripts/build.sh --tests
python3 scripts/run-ui-tests.py --list
python3 scripts/run-ui-tests.py directory-picker-stress terminal-clock tab-bar-menu
python3 scripts/run-ui-tests.py resource-review
python3 scripts/run-ui-tests.py agent-control
python3 scripts/run-ui-tests.py auth-concurrency login-password-save proxy-catalog global-proxy
python3 scripts/run-ui-tests.py tab-window-merge tab-detach tab-reorder multi-window
python3 scripts/run-ui-tests.py --group sessions
```

测试应用单独输出到 `work/test-app/OShell.app`，缓存位于 `work/build-tests/`，不会覆盖正式 app。通用 UI 运行器会复制应用、分配独立 Bundle ID 和临时数据目录，结束时清理测试副本；结果写入 `validation/ui-*.json`。图片粘贴使用 `image-paste`、`paste-scroll`，同步状态使用 `sync-settings`、`directory-sync`、`toolbar-actions`；远端图片上传另运行 `run-sftp-reuse-tests.py`。可用 `--app` 指定其他带测试标记的应用。`tabs`、`sessions`、`memory` 分组替代原来重复的批量包装脚本。`stress` 输出性能采样，不代表所有负载下的性能保证。

测试入口必须显式指定独立的 `OSHELL_DATA_DIR`；正式应用会在读取数据前拒绝测试参数。不要将开发测试指向实际会话目录或真实服务器。UI 检查需要 macOS 图形会话。

资源回归 `resource-review` 验证 200 个标签的 1000 次无变化刷新复用菜单与图标、快捷键与未读状态正确更新、隐藏和最小化时钟停止计时器，以及同步对象销毁时注销计时器。输出的耗时仅代表该合成场景，不等于整个应用的性能提升比例。

SSH 内存采样需要安装 Paramiko。运行 `python3 scripts/run-memory-cycles.py ssh-memory --sessions 1 --lines 0 --visible --capture-vm`，用独立测试应用和本机临时 SSH 服务测量单连接开销；省略数量参数则执行三轮、每轮 16 个会话和每会话 3200 行输出。`--editor` 会在连接稳定后打开并取消新建会话窗口，`--fullscreen` 使用系统全屏。报告位于 `validation/`，包含约 10 毫秒间隔的物理占用与 RSS、阶段堆统计、可见性、Metal 呈现帧数，以及会话对象和子进程释放检查。`--visible` 要求解锁桌面并观察到可见窗口；Metal 模式还必须在每轮观察到真实呈现帧（阶段结束时的遮挡状态不抹去已经呈现的帧）。锁屏或遮挡下的采样不能代替可见绘制验证；场景通过也不代表不存在瞬时峰值。`--capture-vm` 仅对隔离测试进程生成内存分类摘要，不读取真实配置或凭据。

Agent 资源回归：`python3 scripts/run-ui-tests.py agent-resources --timeout 300` 生成 128 MiB 合成审计输出，完整扫描三次，检查堆增长、文件描述符和队列上限；另外进行三轮快速切换与关闭回放窗口，验证终端、定时器、扫描任务及面板所选会话的释放。`python3 scripts/test-agent-resources.py` 连接停滞的本机 Unix 测试服务，验证 MCP SDK 消费输入队列后仍受最多 8 个在途请求约束，正常响应释放配额。两者均不使用个人配置、真实主机或模型服务。

当系统全屏 Space 隐藏了普通测试窗口时，可用 `OSHELL_MEMORY_PANEL=1` 运行同一脚本，在独立浮动面板中测量连接与编辑组件；报告会标记 `testWindow: panel`，不能把它当成系统全屏验证。比较优化前后时须使用相同窗口类型、尺寸和缩放，并同时检查呈现帧数及对象释放结果。纯色背景使用图层颜色避免整面位图绘制，但背景组件的节省不能直接当作整个 SSH 流程的峰值降幅。

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
work/test-tools/bin/python scripts/run-host-key-tests.py
work/test-tools/bin/python scripts/run-sftp-reuse-tests.py
work/test-tools/bin/python scripts/run-ssh-clone-tests.py
work/test-tools/bin/python scripts/run-local-tool-tests.py --connection-status-only
work/test-tools/bin/python scripts/run-webdav-tests.py
```

这些脚本默认使用测试应用和一次性本地账号。保存密码认证及明文不落盘检查统一由 `run-session-tests.py` 覆盖，移除了需手工启动固定端口服务的旧密码测试入口。更新、文件传输、代理、隧道和内存循环等专用脚本继续保留；它们与通用 UI 检查的测试服务需求不同。加密启动测试会自行生成临时样本，不依赖维护者工作目录中的文件。

需要单独调试 Intel UI 时，可使用 `package-release.py --flavor amd64 --apps-only --tests`，输出 `work/test-release/amd64/OShell.app`；测试应用禁止打包或发布。常规开发无需执行此步骤。

## 更新 README 截图

使用隔离测试应用生成真实界面的示例图片，不连接服务器、不使用个人会话。执行 `python3 scripts/run-ui-tests.py readme-screenshots terminal-chrome` 后，从 `validation/` 中选取 `readme-sessions.png`、`readme-files.png`、`terminal-chrome-split-review.png` 及 `terminal-chrome-empty-0-dark-review.png`，检查内容和布局后更新 `docs/images/` 对应图片。终端输出和文件列表均为固定演示数据；不要用个人工作窗口的截图替换。

设置六宫格使用 `python3 scripts/run-ui-tests.py readme-settings` 生成，输出为 `validation/readme-settings-grid.png`，核对后更新 `docs/images/settings-overview.png`。只采集设置页内容，示例配置不保存；终端预览使用独立绘图上下文，避免截图中文字发生偏移。

## 清理构建历史

```sh
python3 scripts/clean-local-builds.py
python3 scripts/clean-local-builds.py --apply
# 可重复 --keep，保留尚需验收的产物或当前测试应用
python3 scripts/clean-local-builds.py --apply --keep dist/fullscreen-acceptance --keep work/test-app/OShell.app
```

第一条只列出目标；第二条执行清理。保留当前本机架构的正式 `dist/OShell.app`、源码、Git、依赖及工具环境、发布密钥和最后一次检查摘要。旧构建、测试副本、安装包、过期工作记录和生成缓存会被删除。清理前验证 app 签名与架构，拒绝删除受 Git 跟踪的文件；同时检查进程与已加载的执行文件、框架，跳过仍在使用的副本。若无法确认已加载文件，会保留重命名后的旧 App 副本。清理后再次核对 app 内容。`work/`、`dist/` 和 `validation/` 是开发产物目录，不用于存放个人会话数据。

清理不会变更系统中已安装的 OShell 或 `~/Library/Application Support/OShell`。之后重新编译会重建缓存。`--keep` 支持项目内文件或目录；保留某个应用时，其同目录的旧副本仍可清理。验收 DMG 和有价值的诊断证据应分别列入保留名单。

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

本机 `scripts/build.sh` 在目标目录旁的临时目录完整组装、签名和检查 App，再替换整个 bundle，不再原地截断正在映射的可执行文件。`install-local-app.py` 检测到目标 App/辅助进程运行时，将新版本发布到独立 `OShell-preview-*.app` 路径；构建输出给出实际路径。生成失败保留 staging 便于排查，发布失败回滚原 App。`test-install-local-app.py` 验证运行中目录保留、旧文件句柄内容不被覆盖及失败回滚。

`SSHClientLocale` 为本机 SSH 提供 `LC_CTYPE=UTF-8`，在私有临时配置中加载原用户/系统配置或显式 `-F` 配置，最后应用 `SendEnv -LANG -LANGUAGE -LC_*`。仅把移除规则放在命令行会被后读入的默认配置重新追加，无法防止 locale 转发。原 `SSHEnvironment.remoteClient` 继续用于清理继承变量，共享配置格式不变。`SSHClientLocaleTest` 用真实 `ssh -G` 检查别名、账号、端口和非 locale 转发保留；`run-ssh-clone-tests.py` 增加中文认证 Banner 和原样八进制文本断言，同时验证服务端未收到语言变量、克隆仅一次认证。依据 [OpenSSH UTF-8 输出处理](https://github.com/openssh/openssh-portable/blob/master/utf8.c) 和 [SendEnv 文档](https://man.openbsd.org/ssh_config#SendEnv)。

`run-ui-tests.py terminal-interrupt` 使用无用户插件的本地 zsh 和临时原始输入接收程序，测量 Ctrl+C 按键处理与 PTY 回包耗时；同时验证 Agent 快捷键查找只访问内存，不在按键事件中执行磁盘 I/O。测试不修改用户 shell 配置，也不把组件耗时当成所有输入法、桌面事件与远端网络场景的端到端保证。

平铺输入焦点由 WorkspaceController 在布局重建前清空旧终端 responder、重建后恢复当前选中终端；正文点击只更新选中元数据，不在 becomeFirstResponder 回调中重建视图。WorkspaceWindow 在交接前拒绝隐藏、已移走或已关闭终端，保留原 responder；命令栏/Agent 面板焦点不由布局重建强行替换。`run-ui-tests.py tiled-input terminal-focus quicksend-focus arrangement-scroll` 覆盖三组六标签、重建、点击、文字与 readline 控制键、真实 PTY 路由、命令栏焦点及滚动。

### 窗口切回后的输入延迟诊断

`python3 scripts/run-ui-tests.py activation-latency` 使用独立数据目录和 24 个空白标签，验证无关窗口/隐藏标签不触发光标刷新，并记录原生窗口切回前后的按键派发耗时。设置 `OSHELL_ACTIVATION_METAL=1` 可覆盖 Metal 路径。此测试不包含真实跨应用输入法切换、SSH 网络和远端回显，不能单独作为实际 SSH 卡顿已消失的证明。

`python3 scripts/run-ui-tests.py fullscreen-activation` 需要已解锁的 macOS 桌面，使用临时应用、24 个标签、本机 PTY 的 cat 回显及一个独立文本框应用，优先放到内屏，执行三轮保留工具栏的普通原生全屏跨应用切换（不能用隐藏工具栏的专注全屏替代），并检查两种入口使用相同的窗口呈现策略，分别记录激活、模拟鼠标点击、首键派发、收到回显、绘制及主线程停顿耗时。`OSHELL_ACTIVATION_METAL=1` 覆盖 Metal。测试包含真实应用焦点交接，但输入事件为合成 ASCII，不覆盖人工输入法组词或 SSH 回显；锁屏导致无法进入全屏时不能视为产品回归。两份临时应用退出或超时后都会清理，不关闭用户正在使用的 OShell。`sync-settings` 使用合成加密 WebDAV 配置验证激活同步立即返回、凭据解密在后台执行、准备期间取消不产生过期失败；`multi-window` 验证返回同一工作区不重建菜单项目，切换工作区仍正确绑定动作。共享信封、凭据格式和同步合并协议未改变。

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

### 全屏窗口状态管理

系统全屏和专注全屏在 `WorkspaceWindow.toggleFullScreen` 调用 `super` 之前准备相同的原生窗口呈现；`willEnter` 提供幂等兜底。窗口快照只捕获一次，进入失败或退出后恢复原样。普通全屏保留工具栏、快捷链接栏及系统窗口按钮；专注模式单独控制应用内容。重复通知不会重复写入未改变的样式，状态不写入共享配置。

`fullscreen-activation` 覆盖进入前准备、失败回滚、普通全屏输入/回显、退出尺寸恢复、随后进入和退出专注模式以及本地进程连续性。回显检查跨越终端换行；时间指标明确标为应用绘制完成，不能当作物理屏幕显示延迟。全屏测试启动前检查桌面锁定状态，锁屏时直接报告环境阻断，不启动无效场景。

已移除临时 A–F 布局菜单、输入采样分支、人工诊断开关和强制画面提交实验。保留标准自动回归和既有只记录时长的统一日志。当前验收候选及其验证状态见 `validation/fullscreen-acceptance-report.json`；候选包不代表已经完成实机视觉验收。


## Agent 回归

`bash scripts/build.sh --tests` 后运行 `python3 scripts/run-ui-tests.py agent-control`。测试通过随应用分发的 SDK STDIO 服务和真实本地 PTY 验证授权隔离、幂等、审批失效、接管及加密审计，使用一次性配置与合成凭据。模拟客户端标识不等于真实 Codex/OpenCode 端到端验收，真实客户端联调应独立记录。核心检查增加了认证分块损坏、截断、密钥隔离、未封口、查询策略与跨字节脱敏回归。

参见 [协议与存储](agent-control.md)。共享配置协议未加入 Agent 设置；所有配对与审计数据留在各应用独立的本机目录。

`run-host-key-tests.py` 使用一次性主机密钥和本机 Paramiko SSH 服务，验证真实 OpenSSH 密钥变化诊断、新旧指纹弹窗、取消不写盘、确认后重连及新密钥信任确认；同时检查散列记录、同一行多个主机、其他 IP/端口、默认端口、IPv6、吊销规则和确认期间文件变化。仅操作临时 known_hosts。

后台标签内存对比：`OSHELL_MEMORY_PANEL=1 work/file-tests-venv/bin/python scripts/run-memory-cycles.py <label> --sessions 4 --lines 3200 --visible --background-tabs`。先保存修改前测试应用，通过 `OSHELL_MEMORY_BINARY` 指定其可执行文件，再与新测试应用运行相同参数。测试含三轮真实 SSH、逐标签显示、后台日志与输入回显、重显及平铺；记录物理内存、Metal 显示表面数量和关闭后资源释放。优化版可加 `OSHELL_MEMORY_EXPECT_RELEASE=1` 检查后台仅保留可见表面，且连接仍运行时完成回收。此面板测试不是原生系统全屏验收，锁屏或未呈现 Metal 帧时不能作为显示内存结果。

排版缓存检查：`python3 scripts/test-text-shaping-cache.py` 直接编译 SwiftTerm 实际缓存实现，不依赖可见窗口。四份缓存分别接收三轮不同文本，再进行共 40 万次重复访问，检查容量上限、Unicode 字形位置/索引的一致性及暖机后的堆增长；可用 `--source` 指向保存的旧实现做同负载比较。这是 CoreText 缓存测试，不替代真实 Metal 显示和长时间运行验收。

长时间静置测试在上述固定标签场景增加 `--idle-seconds 3600`，每轮保留原会话且不发送测试命令一小时（三轮共三小时），每 30 秒记录堆、物理占用与渲染对象数量。长测将外部进程采样频率降为每秒一次，避免诊断记录自身无限膨胀；测试窗口需保持可见，不能用锁屏数据推断前台绘制无泄漏。

双会话全屏内存对照：`work/file-tests-venv/bin/python scripts/run-memory-cycles.py two-ssh-fullscreen --rounds 1 --sessions 2 --lines 0 --background-tabs --idle-seconds 60 --fullscreen --capture-vm`。全屏测试默认保留测试窗口所在显示器，也可用 `--display-index N` 指定 NSScreen 索引并核验目标屏幕；报告包含窗口尺寸、缩放、交换表面像素尺寸及缓冲数量。`OSHELL_MEMORY_DRAWABLE_COUNT=3` 仅在测试构建中恢复三缓冲进行同二进制对照，正式实现默认双缓冲。比较时要求显示器、分辨率、可见性和负载一致，分别记录静置占用与切换峰值；遮挡或未成功重绘的运行不能作为可见绘制验收。初次访问和恢复后的呈现检查使用独立名称，后一次通过不能覆盖先前失败；可见测试的每个静置采样也必须可见。`--capture-vm` 在静置 30 秒阶段另采集分类摘要，使用至少 60 秒静置以留出采样时间。

最小化资源回归：`work/file-tests-venv/bin/python scripts/run-memory-cycles.py minimized-ssh --rounds 1 --sessions 2 --lines 3200 --background-tabs --minimize --visible`。仅用于普通窗口，验证最小化后显示表面释放、SSH 保持连接，恢复时呈现新帧且输入、历史和日志完整。排版缓存每个渲染器保留至多 2048 条，并对文本、字形数组和条目开销采用 4 MiB 计账预算；该预算不代表 CoreText 或整个进程的内存硬上限。`test-text-shaping-cache.py` 验证计账上限、超预算长行仍可排版、淘汰与清空后的 Unicode 一致性及实际堆占用。

光标空闲回归：`python3 scripts/run-ui-tests.py metal-cursor` 验证实际原生光标像素、六种样式、动画透明度变化、宽字符移动、隐藏/恢复和失焦外框，并要求闪烁期间 Metal 帧数不增加。macOS Metal 使用独立光标层；空闲 SSH 测试默认启用闪烁光标，可加 `--steady-cursor` 做常亮对照。内存比较应等待静置 30 秒后采样，并确认窗口持续可见、有焦点；整个 60 秒静置测试连同建连、恢复检查约需 90 秒，测试窗口关闭前不要切换 Space。

大屏切换对照：`work/file-tests-venv/bin/python scripts/run-memory-cycles.py large-screen --rounds 1 --sessions 2 --lines 3200 --background-tabs --geometry-cycles 3 --switch-count 20 --visible --capture-vm`。默认保留测试窗口所在显示器；如需指定，先确认当前 NSScreen 索引再加 `--display-index N`。普通窗口起步，重复原生全屏、快速标签切换和退出全屏；每阶段静置 8 秒，记录物理内存、堆、CPU 时间、Metal 设备分配量、回收次数及请求切换到呈现新帧的延迟。基线用 `OSHELL_MEMORY_BINARY` 指向保存的旧测试应用。两次运行必须使用同一显示器、分辨率和负载，并保持测试窗口前台可见。锁屏时脚本拒绝启动；全屏动画未完成、窗口遮挡或失焦的运行不能替代此验收。呈现时间包含应用调用和轮询开销，不等于物理屏幕响应时间；Metal 分配量也不能直接从进程物理占用中相减来推算系统合成器的开销。

无窗口回收检查：构建测试版后运行 `python3 scripts/test-idle-reclaimer.py`。它链接实际 SwiftTerm 和空闲回收实现，验证忙碌延后、突发请求合并、取消、生命周期及主循环响应；可在锁屏时执行，但不证明全屏内存收益或 GPU/切换性能。

Metal 行缓存检查：`python3 scripts/test-metal-row-cache.py --expect-trim --output validation/row-cache.json`。脚本在临时包中编译实际 SwiftTerm 源码，检查持久行缓存释放 CPU 中间数组后，命中时仍复用相同 GPU 缓冲，且重建前后的缓冲数据一致；覆盖 1×/2× 栅格化、Unicode、内联图片、滚动、备用屏幕、尺寸变化、渲染模式往返及表面恢复。可用 `--renderer-source` 指定保存的旧渲染器文件做同负载对照，并省略旧版本不支持的 `--expect-trim`。结果记录双会话 CPU 数组有效载荷、堆使用量和暖缓存构建耗时；该组件测试不呈现窗口，不代表原生全屏或整个进程的内存节省。

专注模式静置重绘检查：测试版构建后运行 `python3 scripts/run-ui-tests.py focus-repaint`。使用临时本地 PTY 和仅响应 SIGWINCH 的备用屏幕程序，切换专注全屏、全心专注及退出，不发送交互输入；核对程序收到的行列数、最终 drawable 像素尺寸及新帧呈现。同步输出检查在 BSU 与 ESU 之间主动请求 Metal 绘制，要求不提交半帧，且 ESU 和既有超时均可恢复呈现。此项需要前台可见窗口；合成程序通过不代表特定版本的远程 OpenCode 已完成视觉验收。

全局代理前置回归：`run-ui-tests.py global-proxy proxy-catalog` 验证全局开关、原配置不变及每跳凭据归属；核心检查覆盖五种协议的 25 种组合、重叠前缀、逆序/回绕、8 级限制及旧跳板字段。`work/file-tests-venv/bin/python scripts/run-proxy-chain-tests.py` 使用实际核心解析器组合全局与会话链，再通过正式 OShellProxy 执行本机 SOCKS4/4A/5、HTTP CONNECT、SSH 密码/私钥混合链。相同 UUID，或无保存密码且除 UUID 外完全相同的连接/认证定义，视为同一跳；同地址不同账号或凭据不会自动合并。测试不连接真实服务器。
