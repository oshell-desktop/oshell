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
python3 scripts/run-ui-tests.py auth-concurrency login-password-save proxy-catalog
python3 scripts/run-ui-tests.py tab-window-merge tab-detach tab-reorder multi-window
python3 scripts/run-ui-tests.py --group sessions
```

测试应用单独输出到 `work/test-app/OShell.app`，缓存位于 `work/build-tests/`，不会覆盖正式 app。通用 UI 运行器会复制应用、分配独立 Bundle ID 和临时数据目录，结束时清理测试副本；结果写入 `validation/ui-*.json`。可用 `--app` 指定其他带测试标记的应用。`tabs`、`sessions`、`memory` 分组替代原来重复的批量包装脚本。`stress` 输出性能采样，不代表所有负载下的性能保证。

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
work/test-tools/bin/python scripts/run-ssh-clone-tests.py
work/test-tools/bin/python scripts/run-local-tool-tests.py --connection-status-only
work/test-tools/bin/python scripts/run-webdav-tests.py
```

这些脚本默认使用测试应用和一次性本地账号。更新、文件传输、代理、隧道和内存循环等专用脚本继续保留；它们与通用 UI 检查的测试服务需求不同。加密启动测试会自行生成临时样本，不依赖维护者工作目录中的文件。

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
