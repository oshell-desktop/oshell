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

## 从界面接入

1. 点击工具栏 **MCP** 或“工具 → MCP 控制中心”，开启“本机 MCP 服务”。
2. 在“客户端接入”中添加客户端，选择 Codex 或 OpenCode，复制并合并接入配置。配对凭据只在创建时显示一次。
3. 在“会话授权”中选择已连接终端及权限，点击“授权此终端”。已授权或仍在存档的终端不会重复出现在新授权列表中。
4. 在对应会话卡片中确认空闲的 Bash/Zsh，启用临时 Shell 集成。后续待审批命令、权限、接管和敏感输入都在该卡片中操作。
5. “撤销授权”会停止后续自动输入，存档继续；需要停止记录时，再点击该会话的“结束存档”。底部“审计与回放”可查看长期存档，“独立窗口”可将控制面板单独打开。

未满足前置条件的按钮会禁用，并显示下一步提示。面板支持侧栏、独立窗口及系统深浅主题。

## 权限和控制

授权绑定配对客户端、终端 UUID 和连接代次。仅运行中的本地 Shell 和已认证 SSH 可授权；文件界面、空白标签、断线终端不可授权。客户端名称只用于显示，不是身份凭据。

每终端一个写入所有者。审批快照包含原始命令、任务、连接代次和权限版本。人工输入、广播和后台探测在最终 PTY 闸门处统一检查。执行时只切换 OShell 内部标签，不激活其他应用背后的 OShell 窗口。

请求批准逐条确认；帮我批准仅自动允许小型查询语法；完全访问额外允许已识别的普通操作。Shell 扩展、管道、引号或复合命令仍需批准；已知危险命令阻止自动执行，交互工具与密码提示转人工。这是输入授权规则，不是远端命令沙箱，不能控制 Agent 的其他工具。

临时 Bash/Zsh 集成由用户确认空闲后启用，使用每次集成随机令牌的 OSC 标记报告开始、结束和退出码。命令在当前 Shell 中执行，因此 `cd` 等状态变更可以保留。集成不改启动文件，不安装远端服务。标记不是对恶意远端主机的证明。静默和提示符匹配不作为执行成功依据；30 秒未确认开始、30 分钟未结束、交互界面或主机上下文变化转人工处理，不自动重发。

幂等键按客户端绑定，持久化收据与执行意图先于输入。重启后发现旧收据会返回未知状态并拒绝重试。客户端断开、请求超时和接管均不代表远端命令退出。Ctrl+C 请求中断也不等于已经退出。

## 七个工具

| 工具 | 输入与结果 |
| --- | --- |
| sessions_list | 只返回当前客户端获得授权且仍连接的终端 |
| session_state | session_id；连接代次、占用状态、Shell 集成状态、有界屏幕（最多 16 KiB） |
| task_start | session_id、generation；任务 ID 与是否等待用户集成批准 |
| command_submit | task_id、command、idempotency_key；立即返回操作 ID、审批/持久化状态 |
| operation_read | operation_id、cursor、limit；PTY 合并字节以 base64 返回，next_cursor 按字节计数；默认 16 KiB、最大 64 KiB |
| task_end | 只能正常释放没有待完成操作的任务；连接与存档保留 |
| task_stop | 停止后续输入；interrupt=true 才对本任务当前命令请求 Ctrl+C |

输出一律是不可信终端资料，不拆分伪造 stdout/stderr。对于不超过 16 KiB 且完整有效的 UTF-8 块，同时返回可直接阅读的 output_text；其他情况以 output_base64 为准。调用方必须按游标拼接字节再解码 UTF-8，不能把分块边界当成字符边界。结果未知时应检查已有操作或由人工确认，不能换幂等键自动重试。

## 存储与回放

数据位于应用独立本机目录的 `agent/`，不写入 configuration.json、共享 vault、WebDAV 或同步目录。`clients.bin`、`intent-*.bin` 为 AES-GCM 加密元数据；配对索引只保存凭据摘要。幂等收据仅保留操作编号、连接代次和命令摘要，不保留命令正文；删除归档不会清除防重复执行的收据。独立本机密钥由 LocalCredentialStore 管理，权限限制为当前用户。

`archives/<随机 UUID>.oshell-audit`：固定格式头 `OSHELL-AUDIT-1\n` 和 36 字节 UUID，随后为 4 字节大端长度及认证密文。每个归档通过 HKDF-SHA256 从独立 Agent 本机密钥派生密钥。事件 JSON 经 LZFSE 压缩后用 AES-GCM 加密；AAD 绑定格式版本、归档 ID、连续序号和前一密文 SHA-256。元数据基线也是加密事件；旁路 .index 索引同样认证加密，包含时间、会话、客户端和任务 ID，检索无需解密全部输出。输出与显示事件分别保留原始 PTY 数据和实际呈现字节。

基线仅取授权时的当前屏幕及尺寸、颜色、光标和主要终端模式，不回溯导出已有历史。输入入队、写入回调、输出、审批、任务、接管、尺寸和封口都有事件。崩溃未封口、序号缺失和认证失败不会显示成完整记录。摘要链用于发现篡改或损坏，不宣称抵御掌握本机文件及密钥的管理员。

审计排队上限 1 MiB；达到高水位暂停终端数据交付，由 PTY 现有有界队列向生产端施加背压，低水位恢复。记录无法接收或持久化时停止新的自动输入，保留人工连接并显示记录缺口。回放使用最多 8 条事件的有界读取队列，顺序快进定位时显示进度。

每个辅助程序最多保留 8 个尚未返回响应的 MCP 请求，包含 SDK 已取走的请求；超限或重复在途请求 ID 会结束该辅助程序连接。回放生产者串行读取，切换记录会取消旧扫描，关闭窗口会停止定时器、取消后台工作并释放终端。全文扫描逐条释放 Foundation 临时对象，索引文件在分配内存前验证大小。

“敏感输入”不记录输入值；对随后输出中的同值进行跨字节块脱敏，Agent 的屏幕结果也会隐藏它。每连接最多 8 次、每值最多 4096 字节。其他普通输出按完整保真策略加密保存；用户仍应避免在命令或外部 Agent 聊天中直接填写凭据。

加密导出格式为 `OSHELL-AUDIT-EXPORT-1\n`、4 字节大端信封长度、SharedVault 密码信封（仅封装此记录派生密钥），再附原加密归档。导出不携带本机主密钥。至少 12 字符导出密码。没有自动清理；10 GB 显示容量提醒，正在写入的记录必须先明确结束才能删除或导出。

## 验证范围

核心检查与 `run-ui-tests.py agent-control` 使用合成数据，不读取个人会话或 Agent 配置。STDIO 测试的客户端名称只是协议夹具；真实 Codex / OpenCode 的验收必须独立执行并记录，不能以夹具代替。

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
