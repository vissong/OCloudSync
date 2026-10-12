# GitHub 构建

工作流：`.github/workflows/build.yml`，名称为 **Build macOS App**。

推送、Pull Request 及 Actions 页的 **Run workflow** 都会触发。使用标准 `macos-15` Apple Silicon runner，Node.js 24，Swift / Python 使用 runner 预装版本并打印到日志。官方 Actions 固定到具体 commit；工作流只有 `contents: read` 权限。相同分支的新构建取消旧构建，单次上限 25 分钟。

## 验证及产物

1. Swift 核心状态、分页、重试和 Live Photo 单元测试。
2. 网页桥接与会话适配器模拟测试、扫描取消离线回归。
3. Release 构建与 ad-hoc 签名验证。
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

首次接入已在本地完整执行上述脚本，45 项 Swift 测试及全部脚本测试通过，ZIP 完整性、架构和签名校验通过；独立审查无问题。远端结果见 [Actions 构建记录](https://github.com/vissong/OCloudSync/actions/workflows/build.yml)。
