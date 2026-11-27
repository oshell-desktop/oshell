# OShell / OShell Desktop 配置兼容约束

用户要求：后续 OShell 与 oshell-desktop 的共享配置必须保持双向通用。这是持续的开发及验收要求。

- 修改会话、代理、目录、快捷引用、保存密码、默认会话属性、共享偏好、导入导出或同步代码时，必须检查另一个项目对应的字段、类型、默认值、身份绑定及加密实现，不能只验证单端读写。
- 共享协议以两端共同支持的 `OShell.shared-vault` 为准。WebDAV 使用 `oshell-vault.json`，同步目录使用 `configuration.json`。本机配置文件、密钥和同步基准仍由各应用独立管理，不应直接共用本机数据目录。
- 保持 Swift → Go → Swift 和 Go → Swift → Go 可读、凭据可解密、引用不丢失。没有用户修改时，不应因空数组、UUID 大小写、默认值或编码差异反复上传或制造冲突。
- 协议变动须兼容已有数据，或提供明确版本识别和安全迁移；不得静默丢弃对端字段、凭据或未知版本数据。平台专属设置应留在本机，或使用双方明确支持且不会被回写丢弃的扩展方式。
- 保留强 ETag / 条件写入、首次同步确认、多节点合并及冲突保护。错误主密码、损坏数据、过期版本及未解决冲突都不得覆盖有效数据。
- 不把用户真实配置、主密码、WebDAV 凭据、私钥或本机密钥放入代码、测试样本或日志。互通测试只用合成数据和临时目录。

## 协议变更的必要验证

在 `oshell-desktop` 项目中执行：

```sh
go test ./internal/core -run 'Test(NativeSwiftSharedFixture|SharedQuickSendScope|LegacySharedProtocol|SharedEncodingNormalization)'
python3 scripts/test-sync-interop.py --native-source /path/to/OShell
```

第二条需要 macOS 和真实 OShell 源码，覆盖双方读写、密码及代理、多节点同步、冲突和无变化不重写。对共享格式新增或变更字段时，补充相应双向测试与合成样本，再执行相关回归。普通 `go test` 会跳过未配置 Swift helper 的测试，不能据此声称真实双端互通已通过。

Windows / Linux 开发时至少运行 Go 兼容样本及相关测试；缺少 macOS 验证环境必须明确报告未验证项目，不得宣称配置兼容验收完成。发布前完成真实双端验证。

详细协议和接入方式见 `oshell-desktop/docs/shared-configuration.md`。不要为兼容性改动擅自提交、推送或发布另一个项目中已有的无关修改。

## 协议规范入口

共享协议的单一维护源为 oshell-desktop 的 `docs/configuration-protocol-v2.md`。本仓库入口为 `docs/configuration-protocol.md`。变更共享结构时先更新规范、双端实现和互通测试；区分当前已实现行为与计划中的扩展。

共同字段定义为 oshell-desktop 的 `internal/core/shared_configuration_schema.json`，`SharedConfigurationContract.swift` 由其生成，禁止手改。共享配置读 v1/v2、写 v2；发布前必须升级参与同步的两端，未知字段拒绝应用和覆盖，不能绕过校验静默丢弃。

## 每次任务结束前清理构建产物

- 每次涉及构建、测试或预览的任务结束前，先保存本次验证摘要，再运行 `python3 scripts/clean-local-builds.py` 检查目标，随后用 `--apply` 清理历史编译、测试应用和预览副本；不得把多个测试版本留在系统应用列表中。
- 新建的测试或预览目录必须纳入清理脚本的明确名单，或在测试退出时可靠删除。删除应用前仅注销该副本的 Launch Services 注册，不重置系统应用数据库。
- 保留正式应用、源码和未提交修改、独立工作区、用户配置、凭据及必要的验证摘要。没有 `dist/OShell.app` 时可验证并保留 `/Applications/OShell.app`，不要为清理而重新构建。
- 正在运行的应用或 MCP 辅助进程依赖的文件必须保留；不得为清理终止它们。若存在无法安全删除的产物，在任务结果中说明，之后空闲时再清理。
- 已通过且与本次修改无关的测试不重复运行。必要诊断资料可用 `--keep` 明确保留，不能借此长期保留无用测试应用。
