# 构建与发布

## GitHub Actions 自动发布

流水线位于 [release.yml](../.github/workflows/release.yml)。将配置和源码提交到 GitHub 后，推送 `vX.Y.Z` 标签会自动构建并发布；也可在 Actions 手动运行，按所选分支的版本自动创建标签。

| 构建目标 | 最低系统 | 架构 | DMG 文件后缀 |
| --- | --- | --- | --- |
| `legacy` | macOS 10.13 | Intel x86_64 | `macOS10.13-Intel` |
| `compat` | macOS 11 | Universal：arm64 + x86_64 | `macOS11-Universal` |
| `arm64` | macOS 13 | Apple Silicon arm64 | `macOS13-arm64` |
| `intel` | macOS 13 | Intel x86_64 | `macOS13-x86_64` |

现代版本以 macOS 13 为最低运行目标，可以用于更新系统；并非限制只能在 macOS 13 使用。四种包共用源码，最低系统和名称统一定义在 `scripts/release_targets.py`。macOS 11 的目标同时设置在项目和 SwiftTerm 的编译配置中，并非只改 Info.plist。

仅需编译时，在 **Run workflow** 中关闭 **publish**。流程不创建版本标签、不发布 Release，也不读取更新签名私钥；安装包仍使用固定代码签名身份。四种 DMG 保存在本次运行的 `dmg-*` Artifacts，可分别下载。

发布步骤：

1. 更新 `scripts/Info.plist` 的 `CFBundleShortVersionString`，递增 `CFBundleVersion`，在 `CHANGELOG.md` 中添加对应版本的变更内容，再提交所有源码和流水线文件。Release 说明会自动提取该版本章节，放在“本次变更”中；缺失、空白或重复的版本章节会阻止发布。
2. 将提交推送到 GitHub。手动发布时进入 **Actions → Build and publish macOS DMGs → Run workflow**，选择要发布的分支（通常为 `main`），**tag 留空**。流程读取该提交的 Info.plist，例如版本 `0.2.61` 会创建 `v0.2.61`；也可明确填写匹配版本。已有同名标签必须指向所选提交，流程不会移动或覆盖它。若需重试旧版本，请选择原标签作为运行来源。标签与源码版本不匹配时，会在创建标签和编译前报错。也可以自行创建并推送匹配的 `vX.Y.Z` 标签来触发发布。
3. 标签确定后，Actions 会运行四个独立构建任务。四个任务全部完成核心测试、DMG 挂载检查、全部 Mach-O 的架构/最低系统检查和签名完整性检查后，才进入发布阶段。
4. Release 先以草稿创建，上传四个 DMG 和对应源码包，并在 Release 说明中嵌入四种目标的签名更新信息。`SHA256SUMS.txt` 和 `release-manifest.json` 放在每个 DMG 内，不再单独上传为 Release 附件。确认远端附件完整后才公开发布并设为 Latest。

GitHub API 只使用自动提供的 `GITHUB_TOKEN`，无需额外 PAT。发布前还需在仓库 **Settings → Secrets and variables → Actions** 配置 `OSHELL_UPDATE_SIGNING_KEY`，内容为现有 Sparkle Ed25519 私钥文件中的 Base64 种子。该密钥必须与应用的 `SUPublicEDKey` 匹配，不能重新生成替代。密钥仅在签名步骤写入临时 0600 文件，完成后清理；不写入源码、日志或发布附件。缺少密钥时停止发布，避免生成会导致检查更新失败的不完整 Release。仓库需允许 Actions 运行；构建阶段仅有 `contents: read`，准备标签和发布 job 申请 `contents: write`。如果组织策略禁止写权限，需要仓库管理员允许该工作流发布 Release。工作流不读取开发者本机 `.release-private`，由维护者配置加密 Secret，也不设置默认更新仓库。

准备阶段创建的标签在后续构建失败时会保留，以便重试相同源码；若要改动源码，应使用新版本，不能将原标签移动到新提交。旧失败记录的 **Re-run jobs** 仍使用当时的工作流；升级流程后应从 `main` 新建一次 **Run workflow**。

失败不会发布残缺 Release；日志保留为各构建任务的 `diagnostics-*` Artifact。同一 tag 的运行会串行排队。上传中断后可以重跑：只续传带有同一提交标记的自有草稿；已公开的 Release 和其他草稿不会被覆盖。发布成功后应递增版本并使用新标签，而不是覆盖旧附件。

四种 DMG 的编译、签名及挂载校验统一使用 `[self-hosted, macOS, ARM64, self-macbook]`，通过 `max-parallel: 1` 串行构建。Intel-only 目标的核心检查通过 Rosetta 执行；Universal 目标在本机 ARM64 上执行核心检查。元数据、发布和更新站点任务的 Runner 不受此次 macOS 切换影响。

默认使用 Runner 当前选择的工具链；仓库变量 `OSHELL_DEVELOPER_DIR` 可指定完整 Xcode 或 Command Line Tools 的开发目录，仅对当前 job 生效。预检检查 SDK、Rosetta 及 macOS 10.13 所需的旧 Swift 运行库。更换工具链后仍须通过所有 DMG 的固定签名、全部 Mach-O 架构与最低系统版本校验；构建通过不等于真实旧系统的运行验收。原托管构建使用 Xcode 16.4，可通过该变量继续固定到兼容的安装路径。

组织 Runner 组须授权当前仓库及具体工作流引用。手动从 main 运行需要允许 `release.yml@refs/heads/main`；版本标签触发还需授权对应 tag，分支授权不会自动覆盖标签。仅验证时关闭 `publish`，不创建版本标签、不发布 Release、不部署更新站点；固定代码签名和安装包验证仍会执行。第三方 Actions 继续固定到官方版本提交。

正式构建使用固定自签名代码签名证书，**没有 Developer ID 签名和 Apple 公证**，Release 说明会明确标注。部署目标校验不等于真实 macOS 10.13/11 的运行验收。流水线发布的 DMG 同时用于手动安装和内置更新；也可按下方步骤在本机签名。不会自动创建或更换发布密钥。

参考：[GitHub 托管 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[macOS 15 工具链清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)、[GitHub CLI Release 命令](https://cli.github.com/manual/gh_release_create)。


## MacBook 编译缓存

`release.yml` 在 Runner 工具缓存目录下的 `oshell-compile-cache/<owner>/<repository>` 保存本机编译产物，位于源码检出目录和临时目录之外，checkout 清理不会删除它。不上传网络缓存。

Swift 缓存按源码与测试代码、Package 定义、依赖内容、编译脚本、工具链与 SDK、检出路径、架构、最低系统版本和测试模式区分；匹配后复用编译结果。只改版本号或文档可以命中；相关源码变更会重新编译 Swift。rz/sz 辅助程序单独缓存，应用源码变化不影响其复用。

缓存只保存所需的编译程序、资源 bundle 和辅助程序许可，不保存主密码、用户配置、签名私钥、已签名 App 或 DMG。每次构建仍重新执行核心检查、应用组装、固定签名、DMG 打包及完整安装包验证。缓存清单记录文件 SHA-256 和权限；损坏、缺失或格式不匹配时按未命中处理并重新构建。

每个架构/目标缓存保留最近两代，命中情况写入 Actions 日志与任务摘要。删除对应仓库的缓存目录即可恢复冷构建；普通本地打包默认不启用缓存，只有设置 `OSHELL_COMPILATION_CACHE_DIR` 才启用。首次建立缓存的耗时不代表后续命中性能，评估时需使用同一提交分别比较冷、热两轮，并排除人工等待 Runner 授权的时间。

## 本地构建与 CI 安装包

日常开发仅运行 `bash scripts/build.sh`，保留本机架构的 `dist/OShell.app`。四种兼容安装包通过上方 Actions 流程生成；需要构建但暂不发布时关闭 `publish`。

流水线使用 `package-release.py --flavor <目标> --format dmg --test-core`，并用 `verify-installers.py` 校验。高级手动打包命令仍可用于排查 CI，但不会由本地默认构建触发。带 UI 测试标记的应用不能打包或通过发布验证。

## 固定代码签名身份

本地正式构建与 Actions 共用同一张证书，以 `scripts/code-signing.json` 中的公开指纹固定身份。签名要求同时绑定证书和应用标识，升级后不随可执行文件哈希变化；四种安装包必须使用同一身份。缺少私钥或证书指纹不匹配时构建失败，不自动生成新证书或回退 ad-hoc 签名。

维护者的加密 PKCS#12 文件和密码保存在 `.release-private/code-signing/`，目录权限 0700、文件权限 0600，须另外安全备份。首次创建使用带 cryptography 的 Python 运行 `scripts/init-code-signing.py`；该命令拒绝覆盖已有身份，日常构建和 CI 不会调用它。私钥及其密码不得进入源码、日志、构建产物或 Release。

GitHub Actions 使用仓库 Secret `OSHELL_CODESIGN_P12`（加密 PKCS#12 的 Base64）和 `OSHELL_CODESIGN_PASSWORD`。这两个 Secret 与更新签名密钥 `OSHELL_UPDATE_SIGNING_KEY` 各自独立，不能互相替换。签名时将证书导入随机密码保护的临时独立钥匙串，仅授权签名工具使用；结束后删除临时钥匙串，不修改系统证书信任或用户原有钥匙串条目。

公开指纹仅用于验证，其他开发者没有维护者的私钥时，可用 `OSHELL_ALLOW_ADHOC=1 bash scripts/build.sh` 构建个人开发版；`bash scripts/build.sh --tests` 也使用 ad-hoc 签名，避免让测试版本继承正式 App 的签名身份。官方流水线设置 `OSHELL_REQUIRE_FIXED_SIGNING=1`，拒绝这些开发构建。独立 fork 应建立自己的签名身份，不能冒用上游身份。

固定证书保持指定签名要求稳定，但旧式钥匙串还有独立的分区列表，可能按二进制 cdhash 授权；因此不能保证点击“始终允许”后跨版本不再提示。Touch ID 加密记录现改用本机私有文件，解密仍由 Secure Enclave 指纹验证控制；旧钥匙串仅尝试无提示迁移，拒绝访问时需手动解锁后重新启用一次。证书过期、更换证书或用户修改钥匙串访问策略时需要单独处理。自签名不等于 Apple 信任，不能替代 Developer ID / 公证或保证消除 Gatekeeper 提醒。

验证固定身份：`python3 scripts/sign-app.py --verify dist/OShell.app`。签名政策回归使用 `python3 scripts/test-code-signing.py`；跨版本钥匙串回归使用 `python3 scripts/test-signing-upgrade.py`，只操作可自动清理的临时测试钥匙串，交互授权处于禁用状态。该回归验证指定签名要求，不代表所有已有登录钥匙串条目的分区授权都能跨版本继承。

## 内置更新

当前客户端通过 `https://<owner>.github.io/<repository>/updates/latest.json` 获取已签名的更新信息，不调用匿名 GitHub Releases REST API，也不要求用户配置 Token。标准 Pages 地址由“更新仓库”的 `owner/repository` 推导；Pages 部署步骤见下方。

安装包仍存放在 GitHub Releases。CI 将四种目标的签名元数据嵌入 Release 说明的 `oshell-update-v1` 隐藏注释，再生成 Pages 静态索引；修改发布说明时必须保留这些注释。不会生成独立 XML 或 `*-update.zip` 附件。

Sparkle 2.9.6 负责校验签名、下载、安装及重启。客户端通过随机路径的本机回环适配通道交给 Sparkle 处理，保留 `SURequireSignedFeed`、`SUVerifyUpdateBeforeExtraction` 及原有公钥。校验失败不降级。更新签名不等同于 Apple Developer ID 签名或公证。

Apple Silicon 的 macOS 13+ 使用 arm64 包，macOS 11/12 使用 Universal 包；Intel 的 macOS 13+ 使用 x86_64 包，更早系统使用 macOS 10.13 Intel 包。客户端只下载匹配目标的 DMG。

CI 使用 `OSHELL_UPDATE_SIGNING_KEY` Secret。维护者本地的 `.release-private/` 不属于构建缓存，清理脚本不会删除其中的私钥。现有发行线不能随意替换公钥或生成新密钥；独立 fork 应使用自己的更新密钥。

关闭手动运行中的“发布 GitHub Release”选项，可以对当前分支进行仅构建验证，即使同版本标签指向较早提交；已有标签与 Release 均不会修改。正式发布仍要求标签与源码提交一致。

流水线会在编译前调用 `python3 scripts/sign-app.py --preflight`，用临时可执行文件验证固定证书能够实际签名。临时钥匙串在签名期间加入搜索列表，成功或失败后均恢复原列表并删除；不修改系统证书信任或默认钥匙串。

签名工具依赖见 `scripts/requirements-release.txt`。`publish-updates.py` 只生成内部签名元数据，不上传或发布；正常发布应交给 Actions 完成校验和发布流程。

## 对应源代码与许可

分发二进制时，同时提供与该二进制对应的源代码、构建脚本、第三方许可和来源。使用不可变的 release tag，并让源码下载与二进制同样容易获得。

```sh
python3 scripts/check-public-source.py --index
python3 scripts/check-public-source.py --history main
python3 scripts/export-public-source.py --ref HEAD --output dist/source/OShell-source.tar.gz
```

源码包只导出审核过的 Git 提交，不包含工作目录、私钥或构建缓存。`Vendor/` 包含 SwiftTerm 与 CryptoSwift 源码，以及 lrzsz 和 Sparkle 的上游源码归档。第三方调整记录见 `THIRD_PARTY_NOTICES.txt`。应用内“开源许可…”可查看 GPL-3.0 与第三方声明。

参考：[GPL-3.0 原文](../LICENSE)、[Sparkle 文档](https://sparkle-project.org/documentation/)、[GitHub Release 下载链接](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases)。


## 包内构建信息与校验

打开 DMG 后，`OShell.app` 旁边提供 `release-manifest.json` 和 `SHA256SUMS.txt`。前者记录该包的版本、构建号、系统目标、架构、源码提交和签名状态；后者校验包内应用、安装说明及清单文件。它不校验自身或外层 DMG，避免循环依赖。可在挂载卷根目录运行 `shasum -a 256 -c SHA256SUMS.txt`。

流水线仍计算外层 DMG、源码包的校验值用于发布前验证，但这些流程内部文件不展示为 Release 附件。更新客户端从 Pages 索引获取相同的签名信息并使用 DMG；包内清单不替代更新签名或 Apple 公证。

## 静态更新站点（GitHub Pages）

客户端读取 `https://<owner>.github.io/<repository>/updates/latest.json`，不调用 GitHub Releases REST API，不需要用户 Token。用户站点仓库 `<owner>.github.io` 使用根目录下的 `/updates/latest.json`。仓库地址仍在 OShell 更新设置中填写，应用自动推导标准 Pages 地址；当前不支持重定向到自定义 Pages 域名。

管理员首次在仓库 Settings → Pages 将发布来源设为 GitHub Actions。`.github/workflows/update-pages.yml` 可以手动执行，用最新已公开的正式 Release 初始化或修复更新站点，无需重建安装包或重新签名。正式发布流水线在 Release 上传校验并公开成功后调用它；只编译模式不部署 Pages。

部署任务使用 Actions 的短期 `GITHUB_TOKEN` 读取最新 Release，验证四份更新元数据的 Ed25519 签名、版本一致性、DMG 名称和大小，然后生成站点。它不读取发布私钥，也不向 Pages 上传源码、配置或安装包。权限为 `contents: read`、`pages: write`、`id-token: write`；站点环境为 `github-pages`。部署串行执行，每次读取最新正式版本，避免旧构建任务拿自己的旧版本覆盖更新源。仓库如限制部署分支，需要允许主分支及发布标签。

Pages 只有首页和 `updates/latest.json` 等静态文件。JSON 按四种平台包装原有签名数据，不改变签名覆盖的字节；客户端仍由 Sparkle 验证更新信息与 DMG。Releases 保留原有签名注释供 0.2.61–0.2.63 客户端升级一次使用，不增加 XML、update ZIP 或额外 JSON 附件。

客户端缓存成功检查结果五分钟；请求失败至少等待一分钟，服务端提供 Retry-After 时遵循其等待时间。过期缓存不会伪装成新的成功检查。Pages 暂不可用时明确报错，不回退到匿名 API。仍使用旧通道的客户端需要升级一次；被 API 限流时可等额度恢复或手动安装新版。

如果 Release 已发布但 Pages 部署失败，旧站点不被替换。修复原因后单独重跑“Publish static update site”，不要覆盖已有正式 Release。默认 GitHub Pages 的域名与地域可达性仍受网络条件影响，此方案解决 REST API 匿名额度问题，不保证所有网络均能访问。
