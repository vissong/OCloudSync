# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 目标与范围

- 仓库目标：macOS 13+ 菜单栏 App（SwiftUI/AppKit，Swift 5.9，无第三方 Swift 包）。通过已登录的 OPPO 云相册官方网页下载原文件，校验、查重后经 PhotoKit 导入系统“照片”图库，由系统 iCloud 照片同步。仓库文档、UI 文案均使用中文。
- 适用范围：本文件适用于整个仓库（`CLAUDE.md` 是指向本文件的符号链接）；更深层 `AGENTS.md` 只覆盖其目录内的特殊规则。
- 非目标：不删除 OPPO 云端文件；不管理 iCloud 服务端逐项上传；不绕过强制登录、风控或服务端会话期限；Swift 侧不直接调用 OPPO HTTP 接口、不导出账号凭据。

## 仓库地图

- `Sources/SyncCore/`：纯逻辑库（台账/状态机、扫描基线、队列、重试退避、日期、格式校验、缓存），不依赖 WebKit/PhotoKit；`swift test` 只覆盖这一层，新的可测逻辑优先放这里。
- `Sources/OCloudSync/`：App target。`AppModel`（`@MainActor` 总调度）、`WebSession`（WKWebView 官方会话与下载）、`PhotoImporter`（PhotoKit 查重/导入/回执）、`CookieVault`（钥匙串）、各 SwiftUI 视图。
- `Sources/OCloudSync/Resources/`：注入官方页面的 `bridge.js`（相册列表/下载适配）、`session.js`（会话续期）。
- `Sources/LivePhotoWorker/`：产物名 `OCloudLivePhoto` 的独立转换进程。
- `scripts/`：构建、签名、公证、发布校验，以及 `test-*.py` / `test-*.mjs` 离线回归。
- `.github/workflows/`：`build.yml`（push/PR 测试打包）、`release.yml`（签名公证发布）、`secrets.yml`（Gitleaks 全历史扫描）。

## 文档入口

- `docs/PLAN.md`：架构与设计边界总览；`docs/USER-GUIDE.md`：当前用户可见行为。
- 子系统需求与决策：`docs/IMPORT-PIPELINE.md`、`SESSION.md`、`REFRESH.md`、`LIVEPHOTO.md`、`VIDEO.md`、`HEVC-COMPATIBILITY.md`、`QUEUE-AND-FALLBACK.md`、`QUEUE-CACHE-CLEANUP.md`、`CAPTURE-DATE.md`、`DATE-RANGE.md`、`LIST-BACKOFF.md`、`LIST-TIMEOUT.md` 等，改对应子系统前先读。
- 构建与发布：`docs/CI.md`、`docs/SIGNING.md`、`docs/PUBLISHING.md`；验证边界：`docs/VALIDATION.md`。
- `CONTRIBUTING.md`、`PRIVACY.md`、`SECURITY.md`、`CHANGELOG.md`。
- `docs/runbooks/`：排障、踩坑与验证手册（尚未创建，需要时新建）。

## 常用命令

- 单元测试：`swift test`；单个类 `swift test --filter LedgerTests`；单个用例 `swift test --filter LedgerTests/testBaselineOnlyCommitsCompleteScan`。
- 单个离线回归：`python3 scripts/test-import-pipeline.py`、`node scripts/test-bridge.mjs`（Node.js 24）等，见下文“提取式回归”。
- 完整验证：`bash scripts/ci.sh`（Swift/JS/Python 回归、合成媒体转换、Release 构建、签名、架构与 ZIP 校验，产物在 `dist/`）。新增回归脚本必须加入 `ci.sh`，否则 CI 不会运行。
- 构建：`OCLOUD_OUTPUT_DIR="$PWD/dist" bash scripts/build-app.sh`。默认输出到仓库**外**的 `../OCloudSync-App`，本地构建请显式设置；`OCLOUD_BUILD_DIR` 可改 scratch 目录。
- 签名：`build-app.sh` 末尾调用 `scripts/sign-app.sh`。未设置 `OCLOUD_SIGN_IDENTITY` 时为 ad-hoc；设置后启用 hardened runtime 与时间戳（`OCLOUD_KEYCHAIN_PATH` 指定钥匙串）。公证见 `docs/SIGNING.md`。
- Live Photo 转换回归需要已构建的 worker：`python3 scripts/test-livephoto.py dist/OCloudSync.app/Contents/MacOS/OCloudLivePhoto`。
- 秘密扫描（需核验过的 Gitleaks 8.30.1）：`GITLEAKS_BIN=/path/to/gitleaks bash scripts/scan-secrets.sh --staged`；完整历史扫描拒绝浅克隆。
- 无独立 lint/格式化工具；Swift 代码保持两空格缩进，匹配周边写法。

## 架构

### 数据流

OPPO 官方页面 → WKDownload 原文件缓存 → 格式/完整性校验 → 实况或 HEVC 兼容转换 → 图库查重 → PhotoKit 导入 → 系统 iCloud 同步。

- **网页适配**：`WebSession` 加载 `cloud.oppo.com`，用 `evaluateJavaScript` 注入 `bridge.js` / `session.js`；脚本遍历官方页面的 Vue 组件树（`$children`）和 webpack 模块，复用页面自身的签名/加密请求客户端，凭据不离开 WebView。登录 Cookie 只存 macOS 钥匙串（`CookieVault`，限 OPPO/HeyTap 域名）。官方页面结构变化是最常见的故障来源，`test-bridge.mjs` 用 `node:vm` 加模拟组件验证适配器。
- **实况转换**：`LivePhotoConverter` 从 App 的 `Contents/MacOS/` 以 `Process` 启动 `OCloudLivePhoto`，worker 写出 HEIC + MOV 和 `manifest.json`，App 再按哈希、尺寸核对后才导入。worker 单独签名，**不带**照片 entitlement。
- **本机数据**：`~/Library/Application Support/OCloudSync/` 下的 `ledger.json`（原子写 + `flock` 进程锁，`LedgerStore`）、`originals/` 原文件缓存、`imports/` 导入回执、`session-status.json` 诊断。
- **流水线**：下载准备与图库处理两阶段并行，最多预取一项；官方网页同时最多一个下载，下载开始之间至少间隔 1.2 秒；查重、回执写入和 PhotoKit 提交严格串行。
- **状态机**（`RecordState`）：`baseline`（首次扫描建立的历史基线，永不导入）→ `pending` → `downloading`/`downloaded` → `importing` → `imported`/`duplicate`/`unsupported`/`failed`/`unavailable`。`importing` 带错误表示 PhotoKit 提交结果未知：先按占位标识和回执恢复核对，**不能**直接重置为失败后重传（见 `SyncRecord.fail(importWasNotCommitted:)`）。
- **同步规则**：新增按账号 + 资产 ID + 内容版本识别，不按拍摄日期；日常比较首批版本与总数，变化、待处理任务、手动请求或每日核对触发完整核对。“按时间导入”是独立的显式批次，预览不修改基线。查重按同媒体类型 + 文件名（忽略大小写）+ 拍摄秒。拍摄日期优先云端时间，回退可靠原文件元数据，绝不用下载时间。

### 提取式回归（改 App target 代码前必读）

`scripts/test-*.py` 不 import App target，而是按**精确签名字符串**（含前导两个空格缩进）从 `Sources/OCloudSync/*.swift` 截取方法/类型体，用朴素的花括号计数确定结尾，再与全部 `Sources/SyncCore/*.swift` 和桩代码一起 `swiftc` 编译运行。例如 `test-import-pipeline.py` 截取 `AppModel.swift` 的 `  private func processQueue(` 等，`test-session-cancellation.py` 截取 `WebSession.swift` 的 `  func ensureSession() async throws {`。因此：

- 重命名、改签名、改缩进或移动这些方法时，同步更新对应脚本中的签名字符串。
- 被截取方法调用的依赖（如 `PhotoImporter`、`WebSession` 的方法）在脚本里是桩实现；改这些依赖的接口要同步更新桩。
- 花括号计数不识别字符串和注释，在被截取的方法里写不配对的 `{`/`}` 字面量会截错。
- 改动后用 `rg -l "<方法名>" scripts/` 找出受影响的脚本并单独运行。

## 工作流程

1. 先阅读根 `AGENTS.md`、目标目录最近的 `AGENTS.md` 和相关 `docs/` 文档。
2. 只修改当前任务涉及的范围，保留无关工作区变更。
3. 同步更新受影响的测试、文档、配置和生成入口；用户可见改动记入 `CHANGELOG.md` 的“未发布”小节。
4. 用户要求“记住”与当前仓库相关的经验时，优先整理到 `docs/runbooks/`，
   记录可复用的条件、步骤和验证方法；只在不适合入库时使用用户级或外部记忆。
5. 交付前运行本文件列出的验证命令并检查最终差异。

## 工程约束

- 任何单个 `AGENTS.md` 不得超过 32 KB（32768 字节）；超限时在其中只保留索引和高频规则，
  将实际文档按职责下沉到 `docs/` 及其子目录。
- 版本号写在 `scripts/build-app.sh` 内联 Info.plist 的 `CFBundleShortVersionString` / `CFBundleVersion`，同时更新 `CHANGELOG.md` 顶部“当前版本”。发布 tag 必须等于 `v` + App 版本且未被使用（`scripts/validate-release.py`）；`release.yml` 只能在 `main` 上手动触发。
- 保持 Bundle ID `dev.local.ocloudsync` 不变（影响钥匙串、照片权限与已有数据延续）。
- 主 App 必须带 `scripts/OCloudSync.entitlements` 中的照片图库 entitlement（hardened runtime 下缺失会导致授权框不弹出），由 `validate-photo-permission.py` 在签名后校验。App 包内须附带 `LICENSE` 与 `NOTICE.md`，`ci.sh` 逐字节比对。
- 维护下载、导入、回执和取消之间的边界；图库提交结果未知时不能盲目重传。新行为要覆盖失败、重启和取消路径。
- 测试只用合成图片/视频和伪造账号标识；CI 不登录 OPPO、不访问个人图库。真实登录与 PhotoKit 授权只能在维护者本人设备上用小样本人工验证。
- 公开文档保留“已验证”与“未验证”的边界，不把单机结果写成所有系统/设备均支持。

## 交付与验证

- 必须通过：`swift test`；涉及 App target、脚本、构建或签名时运行 `bash scripts/ci.sh`。
- 必须检查：`git status --short` 与 `git diff`，确认没有运行数据或无关改动。
- 必须检查：`find . -name AGENTS.md -type f -size +32768c -print` 无输出。
- 交付说明应区分已验证事实、推断和未完成事项（例如离线回归通过不等于真实账号/图库已验证）。

## 安全边界

- 不提交令牌、密码、Cookie、私钥、真实凭据或无权公开的材料；本仓库还包括原片、台账、导入回执、抓包（HAR）、签名 URL、真实 GPS、用户路径及含这些信息的截图。
- 不覆盖用户已有内容，不执行未经授权的破坏性、发布或外部写入操作。
- 不声称未执行的命令、测试、提交或发布已经完成。
