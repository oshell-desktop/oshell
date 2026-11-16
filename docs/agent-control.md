# MCP 控制中心：本机 Agent 控制与审计

OShell 不调用模型。外部 Agent 经随应用分发的 `Contents/Helpers/OShell-MCP` 访问用户授权的现有终端。

```mermaid
flowchart LR
  A[本机 Codex / OpenCode] -->|STDIO MCP| B[OShell-MCP]
  B -->|独立 Unix Socket / 同 UID / 配对凭据| C[授权与执行协调器]
  C -->|持久化意图后输入| D[现有 PTY 与终端窗口]
  D --> E[加密审计]
  E --> F[无 PTY 只读回放]
```

官方 Swift MCP SDK 固定为 0.12.1，STDIO 传输限制消息大小与积压，并忽略本服务未实现的 experimental 能力（SDK 此版本将该字段限定为字符串字典，现代客户端可能传入嵌套 JSON），全部依赖版本记入 Package.resolved；swift-log 1.6.4、swift-collections 1.2.1 另设精确约束，以兼容发布工具链 Swift 6.1。协议版本由 SDK 与客户端协商。服务默认关闭；复制接入配置不修改 Codex 或 OpenCode 的现有文件。不开放 TCP 端口，也不复用外部新建连接接口。

### 升级与本地通道恢复

客户端与 `OShell-MCP` 之间的 STDIO、辅助程序与主程序之间的 Unix Socket 是两条独立通道。主程序退出或服务暂时不可用不会结束辅助程序；服务恢复后，后续请求自动连接原 Socket，使用已有配对凭据，不需要重新配对。服务和会话授权仍须由用户开启；主程序重启、SSH 重连不会自动恢复旧会话授权。

辅助程序发现空闲连接已关闭，会在发送新请求前重新连接。`sessions_list`、`session_state` 和 `operation_read` 遇到通信断开时，等待 250 ms 后最多重试一次；无后台轮询。权限错误、无效协议数据不重试。执行、停止等请求发送后失去回复，结果视为未知，不自动重发；先查询状态或已有操作 ID，需要恢复提交时沿用原幂等键。`session_exec` 已取得操作 ID 后若读取失败，会保留原收据并返回 `read_error` 和 `next_action=read_output`，便于继续读取。取消等待不会触发重连重试。

本地安装使用 `scripts/install-local-app.py` 整包改名替换。主程序或其他辅助程序仍运行时保留原应用，另存预览版本；只有 `OShell-MCP` 运行时可更新标准路径，**不要为安装而终止该进程**。该辅助程序静态链接项目代码和 SDK，不读取应用包资源；安装不会原地覆盖其可执行文件，旧映射由内核维持到进程退出，新客户端启动新版辅助程序。此策略不等于热更新现有进程：旧辅助程序继续提供旧版工具定义，客户端重新建立 MCP 连接后才加载新版功能。

若旧辅助程序已被终止，客户端持有的 STDIO 已关闭（`Transport closed`），OShell 无法替客户端重建管道；这一次仍需由客户端重新建立 MCP 连接。这里的安装保障针对上述本地安装脚本，不能保证外部安装器或客户端主动杀进程时保留连接。

Codex 提供 `config/mcpServer/reload` 来触发客户端重建连接，但本机定向实验确认重复工具调用和状态查询并不等于重载。该接口作用于已配置的 MCP 服务，不能无条件在每次查询失败时全局触发。版本、复现脚本与自动恢复接入边界见 [Codex MCP 连接恢复](mcp-client-recovery.md)。诊断原生通道时，优先验证当前聊天的工具调用；独立客户端查询成功不能作为原通道恢复的证据。

## 从界面接入

1. 点击工具栏 **MCP** 或“工具 → MCP 控制中心”，开启“本机 MCP 服务”。
2. 在“客户端接入”中添加客户端，选择 Codex 或 OpenCode，复制并合并接入配置。配对凭据只在创建时显示一次。
3. 在“会话授权”中选择已连接终端及权限，确认 Bash/Zsh 空闲后点击“确认空闲并授权接入”。OShell 自动准备临时 Shell 钩子，不再单独要求确认集成。已授权或仍在存档的终端不会重复出现在新授权列表中。
4. 终端页面和会话卡片持续显示“MCP 客户端：名称 接入中”。任务结束后继续等待下一项任务；客户端短暂断开时保留授权并等待重连，人工输入在任务间隙也不会插入。
5. 点击“终止接入”、双击 Esc 或按 Ctrl+C 撤销接入并恢复人工输入；Ctrl+C 同时传入终端。SSH 连接和外部聊天保留，存档继续；需要停止记录时，再点击该会话的“结束存档”。底部“审计与回放”可查看长期存档，“独立窗口”可将控制面板单独打开。

未满足前置条件的按钮会禁用，并显示下一步提示。面板支持侧栏、独立窗口及系统深浅主题。

日常接入可直接右键终端标签 → **交给 Agent…**，确认目标会话、客户端和权限后授权；默认选中上次成功授权的客户端，权限默认“帮我批准”。取消不会建立授权，也不会改变其他标签。服务未开启、尚未配对、会话已授权或仍在存档时，入口会定位到控制中心继续处理，保留已有配对及授权流程。

## 权限和控制

授权绑定配对客户端、终端 UUID 和连接代次。仅运行中的本地 Shell 和已认证 SSH 可授权；文件界面、空白标签、断线终端不可授权。客户端名称只用于显示，不是身份凭据。

每终端一个写入所有者。审批快照包含原始命令、任务、连接代次和权限版本。人工输入、广播和后台探测在最终 PTY 闸门处统一检查。执行时只切换 OShell 内部标签，不激活其他应用背后的 OShell 窗口。

请求批准逐条确认；帮我批准仅自动允许小型查询语法；完全访问额外允许已识别的普通操作。除下述有限的字面参数外，Shell 扩展、管道、引号或复合命令仍需批准；已知危险命令阻止自动执行，交互工具与密码提示转人工。这是输入授权规则，不是远端命令沙箱，不能控制 Agent 的其他工具。

常见诊断新增 `free` 单次查询（如 `free -h`）及 `docker ps`。容器查询只接受明确列出的只读参数：`-a/--all`、`-q/--quiet`、`--no-trunc`、`-n/--last`（1–1000）、`-f/--filter`（id/name/status）和 `--format`。格式支持 `json`、Docker 固定字段占位符及空格/制表符/换行分隔，例如 `docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}'`；不接受任意模板函数。未知参数、全局远端连接选项、循环刷新、变量展开、命令替换、重定向和引号拼接不会自动放行。Python/Shell 脚本仍需批准，“请求批准”权限仍逐条审批。

临时 Bash/Zsh 集成使用随机令牌和 Shell 的执行/提示符钩子报告开始、结束和退出码。首次授权先发送短引导命令；子 Shell 保存 TTY 设置、关闭回显并发出带本次令牌的 `load` 请求，OShell 验证授权和连接后才发送初始化数据。数据以 Base64 编码，按小于 canonical 输入上限的 `: 数据` 空操作行分帧，每帧都需收到带令牌和顺序号的请求才发送，避免慢速 SSH 和 TTY 队列溢出。数据在内存中拼接，收到结束标记且解码成功才执行；不会作为交互命令写入 Shell 历史。子 Shell 在正常结束、读取超时或可捕获中断时恢复原 TTY 设置，父 Shell 的 trap 保持不变；加载仅依赖 Bash/Zsh、stty 和 base64；迟到的数据即使落到 Bash/Zsh 提示符也只是空操作。同一 Shell 中再次接入复用带版本号的钩子，仅更新令牌，不重复传送脚本。

终端仅折叠已逐字核对的引导命令回显，并由接入状态栏提示“正在准备 Shell”；意外输出原样显示，匹配失败或超时会释放暂存内容。原始输入、输出及独立的 `integration_payload` 事件仍完整加密存档。引导命令本身遵循原 Shell 的历史策略，不删除历史、不改启动文件、不落地远端脚本、不建立新的 SSH exec 通道。

后续单行命令原样输入，不再拼接 `printf … eval … printf`；多行命令使用当前 Shell 的花括号组，作为一个操作报告完成，`cd` 和变量等状态仍保留。Bash 4.4+ 使用 PS0，较早版本使用未被占用的 DEBUG 钩子；Zsh 使用 preexec/precmd。保留已有提示符钩子；不支持的 Shell 或钩子配置会明确暂停接入。

集成不改启动文件、不安装远端服务、不改变历史记录策略；临时钩子随当前 Shell 进程结束消失。标记不是对恶意远端主机的证明。静默和提示符匹配不作为执行成功依据；30 秒未确认开始、30 分钟未结束、交互界面、主机上下文变化或审计失败转人工处理，不自动重发。处理后可在面板确认空闲并重新接入；连接结束或重连使旧授权失效。

幂等键按客户端绑定，持久化收据与执行意图先于输入。重启后发现旧收据会返回未知状态并拒绝重试。客户端断开、请求超时和接管均不代表远端命令退出。Ctrl+C 请求中断也不等于已经退出。

## 工具与快捷执行

原有七个工具及默认返回格式继续兼容。新增 `session_exec` 作为普通命令的快捷入口：在已授权且 Shell 就绪的会话中，自动创建并结束内部任务，沿用原有审批、幂等和审计；不创建终端、不自动重连、不抢占已有任务。

| 工具 | 输入与结果 |
| --- | --- |
| sessions_list | 只返回当前客户端获得授权且仍连接的终端；附 can_exec、task_id、current_operation、approval，便于发现正在处理的操作 |
| session_exec | session_id、generation、command、idempotency_key；默认等待最多 1000 ms 后返回精简输出及 operation/task ID。可选 view=text、tail_lines、contains；长命令或待审批命令用 operation_read 继续读取 |
| session_state | session_id；连接代次、持续控制状态 occupied、单次任务状态 task_active、Shell 就绪状态；附 can_exec、task_id、current_operation、approval。include_screen 默认 true 保留原来的有界屏幕（最多 16 KiB），false 时不生成也不返回 screen |
| task_start | session_id、generation；任务 ID 与 ready / initializing_shell；准备中通过 session_state 等待 shell_ready |
| command_submit | task_id、command、idempotency_key；立即返回操作 ID、审批/持久化状态 |
| operation_read | operation_id、cursor、limit；默认保持原来的 Base64 与可选正文格式。可选 wait_ms（0–10000，默认 0）、wait_for（output / completion / approval）、format（legacy / compact）、view（raw / text）。next_cursor 始终按原始 PTY 字节计数；默认 16 KiB、最大 64 KiB |
| task_end | 只能正常结束没有待完成操作的任务；接入授权、Shell 就绪状态、连接与存档保留 |
| task_stop | 停止本任务的后续输入并保留接入授权；interrupt=true 才对本任务当前命令请求 Ctrl+C，未收到完成反馈前不能插入新任务 |

输出一律是不可信终端资料，不拆分伪造 stdout/stderr。对于不超过 16 KiB 且完整有效的 UTF-8 块，同时返回可直接阅读的 output_text；其他情况以 output_base64 为准。调用方必须按游标拼接字节再解码 UTF-8，不能把分块边界当成字符边界。结果未知时应检查已有操作或由人工确认，不能换幂等键自动重试。

上述双格式说明适用于默认 `legacy`。`session_exec` 默认使用 `compact`：最大 64 KiB 的有效 UTF-8 块优先只返回 `output_text`；无效或被字节游标切开的 UTF-8，以及 JSON 转义后超过 IPC 预算的控制字符密集块，返回 `output_base64`。`encoding` 标识实际格式，完整原始数据仍在加密审计中。`has_more` 表示当前快照还有未读输出；`completed` 仅在已确认命令结束且审计完成时为 true，是否成功仍以 `operation.exit_code` 为准。`next_action` 为 `read_output`、`approve_in_oshell`、`inspect_in_oshell` 或 `none`。

`approval` 在待审批时返回原因（`permission_requires_approval` / `outside_automatic_policy`）、提交时的权限和操作提示，其余状态为 null。`can_exec` 仅在当前授权可用、Shell 就绪且无现存任务时为 true；待审批不再被误报为 Shell 就绪。上下文丢失后，可从会话的 `current_operation.operation_id` 继续读取；这些发现字段不转移任务所有权，不放宽跨客户端或跨连接的控制权限，也不返回命令正文。

快捷调用示例：先从 `sessions_list` 取得会话 ID 与 generation，再调用 `session_exec` 并为这次命令提供唯一幂等键。返回 `approve_in_oshell` 时由用户在控制中心批准；返回 `read_output` 时，将 `operation.operation_id` 和 `next_cursor` 传给 `operation_read`，使用 `format=compact, wait_ms=10000` 等待新增输出。需要等待命令结束可设 `wait_for=completion`；超时只返回当前状态，不会终止或重发命令。执行中可用返回的 `task_id` 调用原有 `task_stop`。等待读取使用独立通道，不占用停止任务的控制通道。

### 净化输出与按需读取

普通查询可以选择 `view=text`，默认采用 compact 返回格式。此视图只读取匹配本次 Shell 令牌的 start/end 标记之间的正文，去掉命令回显、提示符、ANSI/OSC/DCS 控制序列，将 CRLF/CR 归一为换行。它是文本记录，不模拟全屏 TUI、光标移动或退格重绘；需要保真内容时继续使用默认 `view=raw`。正文尚未开始或结束时，`body_started` / `body_ended` 会明确标识，不按提示符猜测完成状态。

Zsh 默认 PROMPT_SP 占位装饰会出现在 precmd/结束标记之前，仅在完整匹配该装饰且紧随本次结束标记时折叠它；相似的普通输出不删除。自定义 Shell 钩子在标记之间打印的内容仍属于该视图，不通过文本猜测删去。

净化前后的 `next_cursor` 都指向原始 PTY 字节位置，可以切换视图；**不能用返回文本长度计算游标**。增量文本被截在 UTF-8 字符中间时，仍使用现有 Base64 回退，调用方应拼接字节后解码。空文本也可能推进游标，例如该段只有回显或控制序列；以 `has_more` 和操作状态判断是否继续。默认原始输出和加密审计不变。

text 视图可附加 `tail_lines=1..1000`、`contains="关键词"`，返回最近匹配的行。关键词是区分大小写的字面字符串，上限 256 UTF-8 字节；只有 contains 时默认最多 100 行。每个读取器保留最近 128 KiB 净化文本，每次查询最多向前扫描 1 MiB 原始输出，并受 limit 返回字节数限制。`has_more=true` 时应带 next_cursor 继续读取，直到扫描到当前尾部；最终结果覆盖该位置的近期窗口，**不代表全文搜索**。`truncated` 表示窗口、行数或字节上限造成省略，`window_bytes` 标出窗口上限，`text_lossy` 标识非完整有效 UTF-8 的文本转换。长日志不会整份加载进内存，读取器最多缓存八个；跳转游标或缓存淘汰需要从已认证存档重建解析状态。

### 审批后继续与轻量状态

遇到 `approve_in_oshell` 时，先告诉用户在 OShell 批准，然后调用 `operation_read(operation_id=原ID, wait_for=approval, wait_ms=10000, format=compact)`。服务在批准、拒绝、撤销或超时时返回；批准后按返回状态继续读取执行结果，用户无需另在聊天中回复“已批准”。超时且仍为 pending_approval 时，可继续等待同一个操作；不会自动批准或重新提交命令。取消等待读取只取消等待，不批准、拒绝或中止原命令。原有 output/completion 等待对待审批操作的即时返回行为保持不变。

客户端需要主动发起上述等待调用；本轮不引入后台模型调用或依赖客户端通知扩展。例行检查优先使用 `session_state(include_screen=false)`，只有确实需要查看终端时再读取屏幕；授权、敏感输入和连接代次检查保持一致。

## 存储与回放

数据位于应用独立本机目录的 `agent/`，不写入 configuration.json、共享 vault、WebDAV 或同步目录。`clients.bin`、`intent-*.bin` 为 AES-GCM 加密元数据；配对索引只保存凭据摘要。幂等收据仅保留操作编号、连接代次和命令摘要，不保留命令正文；删除归档不会清除防重复执行的收据。独立本机密钥由 LocalCredentialStore 管理，权限限制为当前用户。

`archives/<随机 UUID>.oshell-audit`：固定格式头 `OSHELL-AUDIT-1\n` 和 36 字节 UUID，随后为 4 字节大端长度及认证密文。每个归档通过 HKDF-SHA256 从独立 Agent 本机密钥派生密钥。事件 JSON 经 LZFSE 压缩后用 AES-GCM 加密；AAD 绑定格式版本、归档 ID、连续序号和前一密文 SHA-256。元数据基线也是加密事件；旁路 .index 索引同样认证加密，包含时间、会话、客户端和任务 ID，检索无需解密全部输出。输出与显示事件分别保留原始 PTY 数据和实际呈现字节。

基线仅取授权时的当前屏幕及尺寸、颜色、光标和主要终端模式，不回溯导出已有历史。输入入队、写入回调、输出、审批、任务、接管、尺寸和封口都有事件。崩溃未封口、序号缺失和认证失败不会显示成完整记录。摘要链用于发现篡改或损坏，不宣称抵御掌握本机文件及密钥的管理员。

审计排队上限 1 MiB；达到高水位暂停终端数据交付，由 PTY 现有有界队列向生产端施加背压，低水位恢复。记录无法接收或持久化时停止新的自动输入，保留人工连接并显示记录缺口。回放使用最多 8 条事件的有界读取队列，顺序快进定位时显示进度。

每个辅助程序最多保留 8 个尚未返回响应的 MCP 请求，包含 SDK 已取走的请求；超限或重复在途请求 ID 会结束该辅助程序连接。回放生产者串行读取，切换记录会取消旧扫描，关闭窗口会停止定时器、取消后台工作并释放终端。全文扫描逐条释放 Foundation 临时对象，索引文件在分配内存前验证大小。

“敏感输入”不记录输入值；对随后输出中的同值进行跨字节块脱敏，Agent 的屏幕结果也会隐藏它。每连接最多 8 次、每值最多 4096 字节。其他普通输出按完整保真策略加密保存；用户仍应避免在命令或外部 Agent 聊天中直接填写凭据。

加密导出格式为 `OSHELL-AUDIT-EXPORT-1\n`、4 字节大端信封长度、SharedVault 密码信封（仅封装此记录派生密钥），再附原加密归档。导出不携带本机主密钥。至少 12 字符导出密码。没有自动清理；10 GB 显示容量提醒，正在写入的记录必须先明确结束才能删除或导出。

## 验证范围

接入设计参考（实现方式各有适用场景）：

- [ferrislucas/iterm-mcp](https://github.com/ferrislucas/iterm-mcp)：共享用户当前终端、少量工具、按需读取输出；该项目不内建命令限制，OShell 保留自身授权与审计。
- [VS Code Shell Integration](https://github.com/microsoft/vscode-docs/blob/main/docs/terminal/shell-integration.md)：通过 Shell 生命周期标记确定命令边界；启动时注入适合新建终端，OShell 还需兼容已经打开的 SSH Shell。
- [kitty SSH kitten](https://github.com/kovidgoyal/kitty/blob/master/docs/kittens/ssh.rst)：经 TTY 握手请求初始化数据。OShell 借鉴带随机标识的按需传输，采用无远端文件的临时内存加载，不替换 SSH 启动流程。

接入专用 PTY 检查运行 `python3 scripts/test-agent-bootstrap.py --helper <OShellCoreChecks 路径>`，使用临时目录和本机 Bash/Zsh 检查静默传输、复用、退出码、历史记录、超时、取消与迟到数据。核心定向检查为 `OShellCoreChecks --agent-usability-checks`。这些检查不连接用户服务器。

净化读取、审批续接和轻量状态的独立验证入口：`OShellCoreChecks --agent-reading-checks`；构建测试包后运行 `python3 scripts/run-ui-tests.py agent-control --agent-suite reading --timeout 240`。该套件不重跑完整旧协议验收，使用合成会话覆盖新增读取、审批和兼容边界。

核心检查与 `run-ui-tests.py agent-control` 使用合成数据，不读取个人会话或 Agent 配置。STDIO 测试的客户端名称只是协议夹具；真实 Codex / OpenCode 的验收必须独立执行并记录，不能以夹具代替。

通道恢复定向验证使用 `python3 scripts/test-agent-reconnect.py --helper <本轮构建的OShell-MCP路径>`：实际辅助程序通过 STDIO 连接隔离 Unix Socket 夹具，覆盖服务不可用后恢复、只读重试、非查询不重发、取消、错误收据保留，以及运行中整包替换后同进程继续通信。它不启动真实 SSH，也不代表真实客户端的工具目录已热更新。安装分支与失败回滚另用 `python3 scripts/test-install-local-app.py` 验证。

真实客户端验收使用 Codex CLI 0.155.1、OpenCode 1.19.4 和面板生成的接入配置，模型响应由本机确定性测试服务提供，不调用付费模型、不读取个人凭据。测试覆盖授权、查询、审批、长任务增量读取和任务结束；SSH 测试通过合成账号连接本机隔离服务器，使用真实 Shell PTY，并检查未建立 SSH exec 通道。

```sh
# 本地 Shell，以及既有终端交互回归
OSHELL_AGENT_REAL_CLIENTS=1 python3 scripts/run-ui-tests.py agent-control agent-replay wheel-gestures terminal-interrupt terminal-focus terminal-scroller tab-reorder arrangement-scroll --timeout 300

# SSH；Python 环境需安装 Paramiko
OSHELL_AGENT_SSH=1 OSHELL_AGENT_REAL_CLIENTS=1 work/file-tests-venv/bin/python scripts/run-ui-tests.py agent-control agent-replay --timeout 300
```

验收报告写入本机忽略目录 `validation/`。核心测试另覆盖记录损坏、缺失尾段、错误密钥、导出密码、持久化失败、敏感值分块脱敏和有界输出；不能仅凭构建成功宣称这些路径已验证。

macOS 最低 15，arm64 与 amd64 两架构。共享配置协议未改变；发布前仍按 AGENTS.md 完成真实 Swift↔Go 互通验证。


接入参考：[Codex MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)、[OpenCode MCP](https://opencode.ai/docs/mcp-servers/)、[Swift SDK 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/releases/tag/0.12.1)。客户端自身的工具批准策略独立于 OShell；需要先在客户端允许调用 OShell 工具，OShell 中的命令审批仍会执行。复制配置不会更改客户端原有批准策略。
