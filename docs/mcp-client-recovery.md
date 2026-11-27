# Codex MCP 连接恢复：边界与复现

## 已确认的行为

2026-11-17 使用桌面应用内置的 Codex `0.169.0-alpha.11.1` 做了独立实验。使用临时 `CODEX_HOME`、合成 MCP 服务和临时会话，不读取个人配置、不调用模型、不访问 SSH。

| 操作 | 实测结果 |
| --- | --- |
| 初始化并调用模拟只读工具 | 成功 |
| 仅结束模拟 MCP 子进程，再调用工具 | `Transport closed` |
| `mcpServerStatus/list`，指定原 threadId 和 serverName | 返回 `runtimeStatus=failed`，不会自行重建连接 |
| 再调用原工具 | 仍为 `Transport closed` |
| `config/mcpServer/reload`，参数为 null | 接受重载请求 |
| 重新查询状态并调用原工具 | `connected`，返回新的模拟子进程 PID |

复现脚本：

```sh
python3 scripts/test-codex-mcp-recovery.py --codex /path/to/codex
```

应传入正在使用的客户端对应的 Codex 可执行文件；PATH 中的 CLI 不一定与桌面版同版本。脚本观察直接调用/状态查询能否自动恢复，并验证官方重载后的恢复；未来 Codex 自动修复该行为时，不应把自动恢复当作测试失败。

同日，当前真实聊天的原生 `oshell/sessions_list` 与 `session_state(include_screen=false)` 已成功，新版工具定义也已加载；此次诊断没有通过临时 OShell 辅助进程查询真实服务器。客户端日志记录了当前聊天的 OShell MCP 从 `starting` 转为 `ready`，但不足以归因于某个用户操作或特定自动恢复触发条件。**当前可用不等于“每次 Transport closed 都会自动修复”。**

## 自动恢复应该由哪一层负责

OShell 控制中心现提供“连接恢复指引”，按所选客户端显示本机通道状态。空闲 Socket 释放与真正的客户端 `Transport closed` 不混为一谈；界面不能证明客户端内部管道健康。该功能只提供指引，不新增守护进程、不调用全局重载接口，也不重放命令。

- OShell 主程序的 Socket 暂时不可用：保留 STDIO 辅助程序，由现有 Bridge 有界重连；沿用原有授权要求。
- OShell-MCP 辅助程序退出，Codex 持有的 STDIO 已关闭：由持有连接的 Codex 后端丢弃旧客户端、重新启动辅助程序并重新握手。OShell 无法向已关闭的管道发送恢复通知。
- 不能用独立启动的另一个 MCP 客户端查询成功，来宣称原生连接已经恢复。

Codex 已实现：运行状态刷新时替换已关闭连接；显式重载时重建已配置的 MCP 服务。但本机实验确认，单纯重复失败的工具调用或状态查询，不会触发这次重载。

## 客户端接入方案与当前限制

拥有正在运行的 Codex app-server 连接的客户端，可在识别到真正的传输关闭时请求 `config/mcpServer/reload`，等待原聊天的 MCP 状态变为 `ready`，再读取状态。避免并发触发多次重载，设置恢复次数和等待上限；认证、权限、参数或业务错误不能视为传输故障。

当前该接口没有单服务参数，官方实现会要求所有配置的 MCP 服务重建。因此不能由 OShell 每次启动或每条查询失败时无条件调用它，也不能通过修改无关配置来强制触发刷新。若要把它做成完善的自动恢复，需要在 Codex 客户端增加按服务合并的恢复处理，或由上游提供定向重连接口。

本次检查到的桌面后端使用私有进程通道，没有可直接连接的默认 app-server 控制 Socket；当前聊天也没有公开的 MCP 重载工具。另起一个 `codex app-server` 只会创建另一个实例，无法修复当前聊天，不能当作替代方案。已在其他环境运行受管理 daemon 的用户，应先确认连接的是原后端，不能假定 PATH 中 CLI 的默认 daemon 就是桌面后端。

官方桌面设置中的 MCP **Restart** 可作为显式恢复入口；它是客户端动作，不是 OShell 配对或会话授权动作。不要要求重新创建配对凭据。原生工具重新可用才算恢复完成；不以接口返回 `{}` 作为成功依据。

只读查询在连接恢复后可以有界重试。对于执行类请求，传输关闭可能发生在远端已执行、客户端尚未收到回复之后，不能自动重放；应先通过原操作 ID、状态查询与原幂等键恢复上下文。重载也不代表远端命令已停止。

## 依据

- [Codex MCP 配置与桌面 Restart 入口](https://learn.chatgpt.com/docs/extend/mcp)
- [Codex app-server：重载与状态查询](https://learn.chatgpt.com/docs/app-server)
- [替换已关闭连接的实现及定向测试 #34957](https://github.com/openai/codex/pull/34957)
- [显式刷新重建 MCP 连接 #35151](https://github.com/openai/codex/pull/35151)
- [运行状态更新触发机制 #35144](https://github.com/openai/codex/pull/35144)

本轮未修改 Codex 应用、用户配置或 OShell 运行逻辑；未重跑此前已通过的 OShell 回归测试。上述实测结论不代替后续客户端版本的验证。
