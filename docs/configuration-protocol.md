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

## OShell 会话范围同步（v2 兼容模式）

OShell 的传输合并使用 `SessionSyncConfiguration` 白名单：profiles、proxies、directories、sessionLinks 的 entries/folders/rootOrder，以及用于认证和比较的 masterPasswordVerifier。客户端 Preferences、默认会话属性、快速命令、高亮规则及 Links.visible 保留本机，不参与远端差异比较。

编码合同与信封版本不变。已有目标的客户端设置部分作为兼容字段保留，新目标填入固定协议默认值，不导出本机客户端设置。接收旧 v1/v2 数据时仍先验证完整合同、密码和引用，未知数据继续拒绝；再仅将白名单会话内容应用到当前完整本机配置。写入仍使用强 ETag / 内容版本条件。

此变更仅在 OShell 实现。未修改的 Desktop 继续读取同一格式，其自身客户端设置处理不由 OShell 控制；不能宣称旧 Desktop 也实现了“设置仅本机”。

除原有双向协议回归外，可运行 `python3 scripts/test-session-sync-interop.py --desktop-source /path/to/oshell-desktop`。该测试在临时 Go overlay 中使用 Desktop 的实际核心实现，不修改 Desktop 项目文件，验证会话/代理/密码/链接往返、旧包兼容、OShell 设置保留和仅设置变化不上传。

### WebDAV 目录选择

OShell 在用户填写的父目录下复用或创建 `oshell/`，文件名仍为 `oshell-vault.json`，共享协议不变。地址本身以 `oshell/`（含旧写法 `OShell/`）结尾时直接使用；父目录已存在旧版同步文件时保持原位置，不隐式迁移。未实现自动子目录选择的 Desktop 须填写实际同步目录地址。目录创建先检查 DAV collection，只有 404 才尝试 MKCOL；并发创建后的 405 也须重新验证目录。文件写入仍要求强 ETag 和条件请求。
