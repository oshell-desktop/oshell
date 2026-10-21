# 构建与发布

## GitHub Actions 自动发布

流水线位于 [release.yml](../.github/workflows/release.yml)。将配置和源码提交到 GitHub 后，推送 `vX.Y.Z` 标签会先自动转发到默认分支（通常是 `main`）的发布工作流，再按该不可变标签构建并发布。也可在 Actions 从默认分支手动运行，按当前版本自动创建标签。不同版本共用默认分支的编译缓存，标签始终锁定实际源码提交。

| 构建目标 | 最低系统 | 架构 | DMG 文件后缀 |
| --- | --- | --- | --- |
| `legacy` | macOS 10.13 | Intel x86_64 | `macOS10.13-Intel` |
| `arm64` | macOS 13 | Apple Silicon arm64 | `macOS13-arm64` |

现代版本以 macOS 13 为最低运行目标，可以用于更新系统；并非限制只能在 macOS 13 使用。两种包共用源码，最低系统和名称统一定义在 `scripts/release_targets.py`。Intel 包统一以 macOS 10.13 为最低目标；不再单独发布 Universal 和现代 Intel 包。

所有任务均使用 GitHub 托管 Runner：元数据检查、Release 发布和更新站点使用 `ubuntu-24.04`；ARM64 DMG 使用 `macos-15`，Intel DMG 使用 `macos-15-intel`。两个目标最多并行执行两个 job，不依赖本机或组织的自托管节点。

仅需编译时，在 **Run workflow** 中关闭 **publish**。流程不创建版本标签、不发布 Release，也不读取更新签名私钥；安装包仍使用固定代码签名身份。两种 DMG 保存在本次运行的 `dmg-*` Artifacts，可分别下载。

发布步骤：

1. 更新 `scripts/Info.plist` 的 `CFBundleShortVersionString`，递增 `CFBundleVersion`，在 `CHANGELOG.md` 中添加对应版本的变更内容，再提交所有源码和流水线文件。Release 说明会自动提取该版本章节，放在“本次变更”中；缺失、空白或重复的版本章节会阻止发布。
2. 将提交推送到 GitHub。手动发布时进入 **Actions → Build and publish macOS DMGs → Run workflow**，选择默认分支（通常是 `main`）（通常为 `main`），**tag 留空**。流程读取该提交的 Info.plist，例如版本 `0.2.61` 会创建 `v0.2.61`；也可明确填写匹配版本。已有同名标签必须指向所选提交，流程不会移动或覆盖它。若需重试旧版本，请选择原标签作为运行来源。标签与源码版本不匹配时，会在创建标签和编译前报错。也可以自行创建并推送匹配的 `vX.Y.Z` 标签来触发发布。
3. 标签确定后，Actions 会运行两个独立构建任务。两个任务全部完成核心测试、DMG 挂载检查、全部 Mach-O 的架构/最低系统检查和签名完整性检查后，才进入发布阶段。
4. Release 先以草稿创建，上传两个 DMG 和对应源码包，并在 Release 说明中嵌入两种目标的签名更新信息。`SHA256SUMS.txt` 和 `release-manifest.json` 放在每个 DMG 内，不再单独上传为 Release 附件。确认远端附件完整后才公开发布并设为 Latest。

GitHub API 只使用自动提供的 `GITHUB_TOKEN`，无需额外 PAT。发布前还需在仓库 **Settings → Secrets and variables → Actions** 配置 `OSHELL_UPDATE_SIGNING_KEY`，内容为现有 Sparkle Ed25519 私钥文件中的 Base64 种子。该密钥必须与应用的 `SUPublicEDKey` 匹配，不能重新生成替代。密钥仅在签名步骤写入临时 0600 文件，完成后清理；不写入源码、日志或发布附件。缺少密钥时停止发布，避免生成会导致检查更新失败的不完整 Release。仓库需允许 Actions 运行；构建阶段仅有 `contents: read`，准备标签和发布 job 申请 `contents: write`。如果组织策略禁止写权限，需要仓库管理员允许该工作流发布 Release。工作流不读取开发者本机 `.release-private`，由维护者配置加密 Secret，也不设置默认更新仓库。

准备阶段创建的标签在后续构建失败时会保留，以便重试相同源码；若要改动源码，应使用新版本，不能将原标签移动到新提交。旧失败记录的 **Re-run jobs** 仍使用当时的工作流；升级流程后应从 `main` 新建一次 **Run workflow**。

失败不会发布残缺 Release；日志保留为各构建任务的 `diagnostics-*` Artifact。同一 tag 的运行会串行排队。上传中断后可以重跑：只续传带有同一提交标记的自有草稿；已公开的 Release 和其他草稿不会被覆盖。发布成功后应递增版本并使用新标签，而不是覆盖旧附件。

macOS 构建固定使用 `/Applications/Xcode_16.4.app/Contents/Developer`，保留 macOS 10.13 所需的旧 Swift 运行库；预检确认本机架构能运行对应目标的核心检查。Runner 镜像更新导致工具链缺失时会明确失败，不静默切换工具链或降低安装包校验要求。第三方 Actions 固定到官方版本提交。

正式构建使用固定自签名代码签名证书，**没有 Developer ID 签名和 Apple 公证**，Release 说明会明确标注。部署目标校验不等于真实 macOS 10.13/11 的运行验收。流水线发布的 DMG 同时用于手动安装和内置更新；也可按下方步骤在本机签名。不会自动创建或更换发布密钥。

参考：[GitHub 托管 runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[macOS 15 工具链清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md)、[GitHub CLI Release 命令](https://cli.github.com/manual/gh_release_create)。


## GitHub Actions 编译缓存

每个目标通过官方 `actions/cache/restore` 和 `actions/cache/save` 单独恢复、保存编译产物及 SwiftPM 增量状态，缓存目录位于 job 临时目录。只有完整安装包验证成功后才保存缓存；不缓存签名证书、密码、钥匙串、用户配置、已签名 App 或 DMG。SwiftPM 配置与凭据目录不进入快照。

缓存按架构、最低系统版本、工具链/SDK、Package 定义、二进制依赖及编译脚本隔离。源码完全相同直接命中编译产物；源码变化时，从相同构建配置的旧缓存恢复 SwiftPM 数据库和中间文件，按源码内容校验恢复未变文件的时间戳，再按 SwiftPM 的传递产品归属选择构建范围，避免无关二进制 framework 的复制触发主程序重编；由 SwiftPM 决定这些产品中需重编译和重新链接的模块。无法可靠识别的输入会安全退回完整依赖图。新增、删除源码及归档造成的时间戳精度变化均有真实编译回归覆盖。缓存损坏或配置不匹配时退回完整编译。

Release 保持整模块优化，因此一个文件的变化可能重编其所属模块以及必要的依赖者，不能保证只编译单个文件；未受影响的模块和独立的 rz/sz 辅助程序可继续复用。核心检查、固定签名、DMG 挂载、全部 Mach-O 架构与最低系统版本校验每次仍完整执行。参考 [Swift 整模块优化说明](https://www.swift.org/blog/whole-module-optimizations/)。

正式构建缓存不包含 `Sources/OShell/TestSupport`，但始终包含核心检查源码；只有 Intel 兼容目标纳入 CryptoSwift。Swift 编译、lrzsz 编译和安装包组装使用独立脚本，调整版本号、DMG 组装或 UI 测试不会无故重编正式 Swift 产物。核心检查仍在每次构建执行，缓存命中也不会跳过。

更新签名工具固定使用 Python 3.12，并由 setup-python 缓存 pip 下载和 wheel。当前固定的 cryptography 版本没有 macOS Intel wheel，Intel 第一次运行仍需本地构建，随后复用已构建 wheel。仅构建模式也安装依赖并执行离线签名验证测试（合成密钥），便于公平比较耗时；实际发布更新签名仍仅在发布模式读取 Secret。

缓存命中状态写入任务摘要。产物缓存保留最近两代，每个目标的增量快照保留最近一次成功编译状态；GitHub 归档按仓库缓存策略保留。缓存服务不可用时可以冷构建，验证流程不依赖缓存才具备正确性。首次运行用于建立缓存；比较性能时应区分冷构建、相同源码命中和源码变化后的增量构建，并单独统计 Runner 排队时间。

## 本地构建与 CI 安装包

日常开发仅运行 `bash scripts/build.sh`，保留本机架构的 `dist/OShell.app`。两种兼容安装包通过上方 Actions 流程生成；需要构建但暂不发布时关闭 `publish`。

流水线使用 `package-release.py --flavor <目标> --format dmg --test-core`，并用 `verify-installers.py` 校验。高级手动打包命令仍可用于排查 CI，但不会由本地默认构建触发。带 UI 测试标记的应用不能打包或通过发布验证。

## 固定代码签名身份

本地正式构建与 Actions 共用同一张证书，以 `scripts/code-signing.json` 中的公开指纹固定身份。签名要求同时绑定证书和应用标识，升级后不随可执行文件哈希变化；两种安装包必须使用同一身份。缺少私钥或证书指纹不匹配时构建失败，不自动生成新证书或回退 ad-hoc 签名。

维护者的加密 PKCS#12 文件和密码保存在 `.release-private/code-signing/`，目录权限 0700、文件权限 0600，须另外安全备份。首次创建使用带 cryptography 的 Python 运行 `scripts/init-code-signing.py`；该命令拒绝覆盖已有身份，日常构建和 CI 不会调用它。私钥及其密码不得进入源码、日志、构建产物或 Release。

GitHub Actions 使用仓库 Secret `OSHELL_CODESIGN_P12`（加密 PKCS#12 的 Base64）和 `OSHELL_CODESIGN_PASSWORD`。这两个 Secret 与更新签名密钥 `OSHELL_UPDATE_SIGNING_KEY` 各自独立，不能互相替换。签名时将证书导入随机密码保护的临时独立钥匙串，仅授权签名工具使用；结束后删除临时钥匙串，不修改系统证书信任或用户原有钥匙串条目。

公开指纹仅用于验证，其他开发者没有维护者的私钥时，可用 `OSHELL_ALLOW_ADHOC=1 bash scripts/build.sh` 构建个人开发版；`bash scripts/build.sh --tests` 也使用 ad-hoc 签名，避免让测试版本继承正式 App 的签名身份。官方流水线设置 `OSHELL_REQUIRE_FIXED_SIGNING=1`，拒绝这些开发构建。独立 fork 应建立自己的签名身份，不能冒用上游身份。

固定证书保持指定签名要求稳定，但旧式钥匙串还有独立的分区列表，可能按二进制 cdhash 授权；因此不能保证点击“始终允许”后跨版本不再提示。Touch ID 加密记录现改用本机私有文件，解密仍由 Secure Enclave 指纹验证控制；旧钥匙串仅尝试无提示迁移，拒绝访问时需手动解锁后重新启用一次。证书过期、更换证书或用户修改钥匙串访问策略时需要单独处理。自签名不等于 Apple 信任，不能替代 Developer ID / 公证或保证消除 Gatekeeper 提醒。

验证固定身份：`python3 scripts/sign-app.py --verify dist/OShell.app`。签名政策回归使用 `python3 scripts/test-code-signing.py`；跨版本钥匙串回归使用 `python3 scripts/test-signing-upgrade.py`，只操作可自动清理的临时测试钥匙串，交互授权处于禁用状态。该回归验证指定签名要求，不代表所有已有登录钥匙串条目的分区授权都能跨版本继承。

## 内置更新

默认更新仓库为 `oshell-desktop/oshell`（`https://github.com/oshell-desktop/oshell.git`），对应更新站点为 `https://oshell-desktop.github.io/oshell/`。已有用户手动填写的仓库仍优先生效。

当前客户端通过 `https://<owner>.github.io/<repository>/updates/latest.json` 获取已签名的更新信息，不调用匿名 GitHub Releases REST API，也不要求用户配置 Token。标准 Pages 地址由“更新仓库”的 `owner/repository` 推导；Pages 部署步骤见下方。

安装包仍存放在 GitHub Releases。CI 将两种目标的签名元数据嵌入 Release 说明的 `oshell-update-v1` 隐藏注释，再生成 Pages 静态索引；修改发布说明时必须保留这些注释。不会生成独立 XML 或 `*-update.zip` 附件。

Sparkle 2.9.6 负责校验签名、下载、安装及重启。客户端通过随机路径的本机回环适配通道交给 Sparkle 处理，保留 `SURequireSignedFeed`、`SUVerifyUpdateBeforeExtraction` 及原有公钥。校验失败不降级。更新签名不等同于 Apple Developer ID 签名或公证。

Apple Silicon 的 macOS 13+ 使用 arm64 包；所有受支持的 Intel 系统统一使用 macOS 10.13 Intel 包。Apple Silicon 的 macOS 11/12 不再提供新版安装包。客户端只下载匹配目标的 DMG。

已安装的旧版现代 Intel 客户端仍查找 `macOS13-x86_64` 更新；发布后复制同一份 Intel DMG 为旧名称兼容附件，并生成对应签名更新信息，因此不需要手动迁移，也不增加编译目标。历史目标定义仅保留用于手动排查，不参与默认构建或发布。

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

部署任务使用 Actions 的短期 `GITHUB_TOKEN` 读取最新 Release，验证两份更新元数据的 Ed25519 签名、版本一致性、DMG 名称和大小，然后生成站点。它不读取发布私钥，也不向 Pages 上传源码、配置或安装包。权限为 `contents: read`、`pages: write`、`id-token: write`；站点环境为 `github-pages`。部署串行执行，每次读取最新正式版本，避免旧构建任务拿自己的旧版本覆盖更新源。仓库如限制部署分支，需要允许主分支及发布标签。

Pages 只有首页和 `updates/latest.json` 等静态文件。JSON 按两种平台包装原有签名数据，不改变签名覆盖的字节；客户端仍由 Sparkle 验证更新信息与 DMG。Releases 保留原有签名注释供 0.2.61–0.2.63 客户端升级一次使用，不增加 XML、update ZIP 或额外 JSON 附件。

客户端缓存成功检查结果五分钟；请求失败至少等待一分钟，服务端提供 Retry-After 时遵循其等待时间。过期缓存不会伪装成新的成功检查。Pages 暂不可用时明确报错，不回退到匿名 API。仍使用旧通道的客户端需要升级一次；被 API 限流时可等额度恢复或手动安装新版。

如果 Release 已发布但 Pages 部署失败，旧站点不被替换。修复原因后单独重跑“Publish static update site”，不要覆盖已有正式 Release。默认 GitHub Pages 的域名与地域可达性仍受网络条件影响，此方案解决 REST API 匿名额度问题，不保证所有网络均能访问。

## 旧仓库更新入口

`arnolixi/oshell` 作为兼容更新仓库继续使用。旧客户端请求 `https://arnolixi.github.io/oshell/updates/latest.json`，该站点由公开仓库 `arnolixi/arnolixi.github.io` 的 `master` 分支承载，仅包含公开更新信息。不要重建 `arnolixi/oshell` 仓库，以免移除 GitHub 到新仓库的迁移跳转。

正式发布前，`publish-legacy-updates.py --release-output` 验证本地已校验 Intel DMG 的 Ed25519 签名，创建字节完全相同的 `macOS13-x86_64` 兼容附件，更新签名元数据、清单和校验和。所有附件必须在草稿阶段上传并核验，才将 Release 公开；不可变发布公开后不能追加附件。原始的两个编译目标不变。脚本用现有 `OSHELL_UPDATE_SIGNING_KEY` 生成分别绑定新、旧仓库名的签名元数据；新站点额外提供旧 Intel 文件名入口，旧站点保留旧仓库下载地址，由 GitHub 将下载跳转到新仓库。不会降低客户端仓库名、系统目标或签名校验。

`deploy-legacy-pages.py` 通过专用 `OSHELL_LEGACY_PAGES_DEPLOY_KEY` 更新旧站点的 `.nojekyll`、`oshell/index.html` 和 `oshell/updates/latest.json`。该部署密钥仅对旧 Pages 仓库有写权限；更新签名私钥不进入该仓库。旧站点由 Pages 的分支发布处理，无定时轮询。相同内容不产生额外提交；旧版本拒绝覆盖新版本。

手动修复使用 **Repair legacy update entry (no builds)** 工作流。它只读取最新正式 Release、重新生成签名元数据并部署新旧 Pages；不会改动不可变 Release、追加附件、重新编译、创建版本或移动标签。若旧发布没有兼容附件，需在下一正式版本发布前加入，不能事后补传。macOS 11/12 的 Apple Silicon 已不属于新版本支持范围，不通过伪造最低系统版本提供更新。

## Actions 历史记录保留

[prune-actions.yml](../.github/workflows/prune-actions.yml) 每天北京时间 04:17 自动清理（GitHub 调度可能延迟），也可从默认分支手动运行 **Prune old Actions history**。手动执行默认只预览；勾选 `apply` 才会删除。

- 发布工作流保留最近 15 次已完成的实际构建运行，包括失败和取消的尝试。
- 成功的纯标签转发记录独立保留最新 1 条；失败转发独立保留 15 条，不占实际构建名额。
- 其他工作流各保留最近 15 条已完成记录，包括清理工作流自身。
- 正在执行、排队、等待审批的记录不删除，当前清理任务也不删除。删除前重新检查状态和运行尝试，发生变化则跳过。

按记录创建时间排序，先读取全部分页再删除，避免分页位移。通过实际 job 判定纯转发；旧版直接在标签上编译的运行仍计入实际构建。删除运行会连同其日志和 Actions Artifacts 一起移除；脚本不调用 Release、Git 标签或编译缓存删除接口。

本地预览：`python3 scripts/prune-actions-runs.py --repository oshell-desktop/oshell`。确认后增加 `--apply` 执行。使用 GitHub CLI 登录身份或工作流内的短期 `GITHUB_TOKEN`，仅需 Actions 写权限及源码读权限，不配置新的 Secret。
