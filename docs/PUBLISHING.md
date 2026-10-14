# 公开与发布检查清单

本清单不执行任何 GitHub 设置更改。源码许可见 [MIT](../LICENSE)，代码来源见 [NOTICE](../NOTICE.md)。

## 切换 Public 前

- 在完整克隆上运行 `bash scripts/scan-secrets.sh`，提交前再检查暂存内容；确认对应提交的构建及秘密扫描 workflow 均成功。
- 检查当前文件、所有远端分支/Tag/PR、提交邮箱、Issue/PR 描述与附件、Actions 历史日志和工件。GitHub 的可见性变更会公开更多内容，参见 [官方说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/setting-repository-visibility)。
- 当前公开文档已改为概括性验证结论。旧提交仍含当时的个人邮箱、真实相册数量、测试时间与原片哈希；当前清理没有改写历史。它们并非登录凭据，但维护者仍需决定是否接受公开。若不接受，应在切换 Public 前另行处理历史及相关 PR/工件引用；不能仅删除最新版本文件。
- 确认所有贡献的来源和许可兼容，README 的能力/限制与实际版本一致。

## 切换 Public 时

由仓库所有者确认并执行可见性变更，然后：

- 启用 GitHub **Private vulnerability reporting**，检查 `Security → Advisories → Report a vulnerability` 与 [私密报告地址](https://github.com/vissong/OCloudSync/security/advisories/new) 可用。启用步骤见 [GitHub 文档](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository)。`SECURITY.md` 提供入口不可用时的处理方式，不应在入口实际启用前宣称已开启。
- 核对 GitHub 原生 Secret scanning 与 Push protection 状态；它们与仓库中的 Gitleaks CI 分开管理。
- 根据维护方式设置 main 的强推/删除限制和必要状态检查；是否要求 PR 由维护者决定。
- 用未登录视角核对 README、MIT 识别、文档、Actions 和安全报告说明。

## 正式 App Release

当前源码可自行构建，但 ad-hoc CI 产物不是经过公证的正式发行版。维护者可使用[本机签名与公证流程](SIGNING.md)生成正式签名产物。正式安装包发布另需确定 Developer ID 签名、公证、支持系统/架构、升级/回退验证，并从对应 Tag 生成 Release 与 SHA-256 文件。

不要在 PR 工作流中提供生产签名密钥或账号凭据；签名发布应使用独立、受保护的流程。发布流程不能访问个人 OPPO 会话或照片图库。
