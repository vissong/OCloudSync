# GitHub 构建

工作流：`.github/workflows/build.yml`，名称为 **Build macOS App**。

推送、Pull Request 及 Actions 页的 **Run workflow** 都会触发。使用标准 `macos-15` Apple Silicon runner，Node.js 24，Swift / Python 使用 runner 预装版本并打印到日志。官方 Actions 固定到具体 commit；工作流只有 `contents: read` 权限。相同分支的新构建取消旧构建，单次上限 25 分钟。

## 验证及产物

1. Swift 核心状态、分页、重试和 Live Photo 单元测试。
2. 网页桥接与会话适配器模拟测试、扫描取消离线回归。
3. Release 构建与 ad-hoc 签名验证，核对 App 内附带的 MIT 许可证及来源说明。
4. 使用现场生成的合成素材验证 Live Photo 转换、音轨及封面时间、缓存复用、损坏恢复与截断拒绝。
5. 核对二进制架构，生成 `OCloudSync-macOS-arm64.zip` 和 `SHA256SUMS`。

成功运行的 **Artifacts** 下提供 `OCloudSync-macOS-arm64-<commit>`，保留 14 天。下载并解压外层 artifact 后，在文件所在目录运行 `shasum -a 256 -c SHA256SUMS` 校验 App ZIP，再解压 ZIP 获得 `OCloudSync.app`。

构建不登录 OPPO、不读取个人图库，也不启动同步 App。无需配置账号、Cookie、Apple ID 或开发者证书。合成转换测试不向照片图库写入内容。产物采用本地 ad-hoc 签名，未经过 Developer ID 签名或 Apple 公证；不是公开分发安装包。

## 本地复现

在 macOS 安装 Xcode Command Line Tools、Node.js 和 Python 3 后：

```sh
bash scripts/ci.sh
```

默认构建目录 `.build/`，产物目录 `dist/`，均由 Git 忽略。可通过 `OCLOUD_BUILD_DIR` 与 `OCLOUD_OUTPUT_DIR` 指定其他绝对路径。本地脚本按当前 Mac 架构命名产物，GitHub 工作流固定构建 Apple Silicon。

CI 只覆盖离线测试与打包。官方登录、真实云相册下载、PhotoKit 权限及 iCloud 同步仍需在用户 Mac 上验证。

构建结果以对应提交的 [Actions 记录](https://github.com/vissong/OCloudSync/actions/workflows/build.yml) 为准。

## 秘密扫描

独立的 `secrets.yml` 工作流在 push、PR 和手动运行时执行。使用 Ubuntu 托管 runner、只读权限和完整 Git 历史，下载 Gitleaks 8.30.1 官方发行包并核验固定 SHA-256；无需账号秘密或 Gitleaks 商业 action 授权。

先在临时仓库验证检出、输出脱敏和浅克隆拒绝，再扫描所有已获取引用的完整历史。失败不会被忽略，不上传可能含私人元数据的扫描报告。运行方式见 [贡献指南](../CONTRIBUTING.md)。GitHub 原生 Secret scanning / Push protection 与此 CI 是独立功能，需在仓库设置核对启用状态。

正式签名、公证及带票据打包使用独立的本机流程，见 [签名与公证](SIGNING.md)。CI 运行公证脚本的离线回归，不访问 Apple 公证服务。
