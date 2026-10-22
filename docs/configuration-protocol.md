# OShell / OShell Desktop 共享配置协议

共享配置协议的单一维护源是 **oshell-desktop 仓库的 `docs/configuration-protocol-v2.md`**，当前文档修订为 2.0（2026-10-17）。本文件只提供入口，不复制正文。

- [同级本地 checkout 中的协议规范](../../oshell-desktop/docs/configuration-protocol-v2.md)

协议修改必须检查并测试两个实现。真实 Swift/Go 双向及多节点验证入口：

```sh
cd /path/to/oshell-desktop
python3 scripts/test-sync-interop.py --native-source /path/to/OShell
```

发布时记录两个项目的提交号、规范修订号及字段合同 SHA-256。共享配置读 v1/v2、写 v2；未知字段拒绝应用和回写。字段合同源为 oshell-desktop 的 `internal/core/shared_configuration_schema.json`，Swift 文件通过 `scripts/sync-configuration-contract.py` 生成；禁止手工维护两套定义。所有参与同一同步目标的节点都要升级后再启用新版同步。已有未提交的其他功能修改不属于协议文档变更。

## 0.2.75 发布验证基线

- OShell：`v0.2.75`，协议实现提交 `0aa1a047fc4aa251f36290cb306d86d05de2ddd5`。
- OShell Desktop：`89aa37cd88a0362b05b2329e28c72543984c1c3d`。
- 规范修订：2.0（2026-10-17）。
- 字段合同 SHA-256：`9a82a335e40d315f9a54455c874f87bcaea0fe3551a69770d67955f439261657`。

## 0.2.76 发布验证基线

- OShell：`v0.2.76`，共享协议与字段合同保持 v2 不变。
- OShell Desktop：`28571b3a41d15777f79ae77f2658755d0abebaee`；验证时工作区干净，未修改或发布该项目。
- 规范修订：2.0（2026-10-17）；验证日期：2026-10-18。
- 字段合同 SHA-256：`9a82a335e40d315f9a54455c874f87bcaea0fe3551a69770d67955f439261657`。
- Swift 核心源码摘要：`c5cadb3869a544e059e91a165806704a02a654e7fae6ef2881dbf87f7b1870a7`。
- Go 原生兼容样本及 `test-sync-interop.py` 真实双向验证通过：Swift/Go 往返、多节点目录与 WebDAV 同步、首次读取无多余改写、完整共享字段与未知字段拒绝、会话归档使用同一字段定义。
- 本次侧栏专用快捷键、显示状态和鼠标选词偏好留在 Mac 本机，不进入共享配置；Touch ID 记录、命令历史、文件传输记录及续传检查点不加入同步。

## OShell 可选同步范围（v2 兼容模式）

`SyncContentSelection` 是本机策略，不写入共享文档。`SessionSyncConfiguration` 默认仍只选择 profiles、proxies、directories、sessionLinks 的 entries/folders/rootOrder，以及 masterPasswordVerifier；可另外选择客户端 Preferences + highlightSets + Links.visible、quickCommands、sessionDefaults。高亮规则随 Preferences 一起选择；会话、目录、引用、代理及凭据作为整体选择。

比较与合并仅使用选中字段的投影。应用时保留未选中的本机字段，写入时保留完整远端文档中未选中的字段；新目标缺失的类别填协议默认值。Preferences 的 updateRepository、automaticUpdateChecks、masterWarningAcknowledged 始终保留各端原值。更改选择范围重置本机同步基准，重新执行首次接入确认；不删除共享文件。

信封版本与生成的字段合同不变，没有增加共享字段。仍先验证完整 v1/v2 合同、密码和引用，未知数据继续拒绝，写入保持强 ETag / 条件写入及多节点冲突保护。`sync-policy.json` 仅保存于本机工作目录，不随共享文档上传；目录同步和 WebDAV 共用本机策略。未修改 Desktop，其自身是否应用共享设置仍取决于其实现。

除原有双向协议回归外，可运行 `python3 scripts/test-session-sync-interop.py --desktop-source /path/to/oshell-desktop`。该测试在临时 Go overlay 中使用 Desktop 实际核心实现，不修改对端项目文件，验证原有会话范围行为、16 种类别组合的 Swift → Go → Swift → Go 往返、凭据解密、引用保留与旧包兼容。

### WebDAV 目录选择

OShell 在用户填写的父目录下复用或创建 `oshell/`，文件名仍为 `oshell-vault.json`，共享协议不变。地址本身以 `oshell/`（含旧写法 `OShell/`）结尾时直接使用；父目录已存在旧版同步文件时保持原位置，不隐式迁移。未实现自动子目录选择的 Desktop 须填写实际同步目录地址。目录创建先检查 DAV collection，只有 404 才尝试 MKCOL；并发创建后的 405 也须重新验证目录。文件写入仍要求强 ETag 和条件请求。

OShell 的 WebDAV 地址支持显式 HTTP 与 HTTPS；该地址及传输选项仅保存在本机，不改变共享数据格式。HTTP 使用独立的有界请求通道，HTTPS 仍使用原有证书校验；未开启 App 全局任意网络加载。Desktop 的 HTTP 地址支持取决于其版本，本次不修改对端实现；两端的共享文件及凭据加密保持不变。

### 本机标签标题偏好

`tab-title-settings.json` 保存全局默认和按会话 UUID 绑定的本机标题选择。新增 `sessionName` 只属于此本机文件，不写入 `Configuration` 或共享 `titleMode`；原合同仍只有三种主机识别值。即使选择同步客户端设置，也不传输本机标题偏好；不修改 oshell-desktop 的代码或生成合同。
