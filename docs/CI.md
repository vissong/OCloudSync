# GitHub 构建

工作流：`.github/workflows/build.yml`，名称为 **Build macOS App**。

推送、Pull Request 及 Actions 页的 **Run workflow** 都会触发。使用标准 `macos-26` Apple Silicon runner，显式选择 Xcode 26.6，Node.js 24，Swift / Python 使用 runner 预装版本并打印到日志。可用工具链见 [GitHub runner 清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)。官方 Actions 固定到具体 commit；工作流只有 `contents: read` 权限。相同分支的新构建取消旧构建，单次上限 25 分钟。

构建机要求 macOS 26+：macOS 15 即使使用 Xcode 26 编译，系统 `assetutil` 仍不能正确读取新格式的 `IconImageStack`，会报告 `couldn't materialize rendition`，无法完成图标验证。构建与签名 job 均使用新系统，最终分发 ZIP 解压后再次校验图标。App 的部署目标仍为 macOS 13，与构建机要求不同。

## 验证及产物

1. Swift 核心状态、分页、重试和 Live Photo 单元测试。
2. 网页桥接与会话适配器模拟测试、扫描取消离线回归。
3. Release 构建与 ad-hoc 签名验证，核对 App 内附带的 MIT 许可证及来源说明。
4. 使用现场生成的合成素材验证 Live Photo 转换、音轨及封面时间、缓存复用、损坏恢复与截断拒绝。
5. 核对二进制架构，生成 `OCloudSync-macOS-arm64.zip` 和 `SHA256SUMS`。

成功运行的 **Artifacts** 下提供 `OCloudSync-macOS-arm64-<commit>`，保留 14 天。下载并解压外层 artifact 后，在文件所在目录运行 `shasum -a 256 -c SHA256SUMS` 校验 App ZIP，再解压 ZIP 获得 `OCloudSync.app`。

构建不登录 OPPO、不读取个人图库，也不启动同步 App。无需配置账号、Cookie、Apple ID 或开发者证书。合成转换测试不向照片图库写入内容。产物采用本地 ad-hoc 签名，未经过 Developer ID 签名或 Apple 公证；不是公开分发安装包。

应用图标原图为 `assets/AppIcon.png`（1024 × 1024、不透明、满版方形），由内置 imagegen 生成后等比缩放，提示词保存在 `assets/AppIcon.prompt.txt`。根据 [Apple 图标规范](https://developer.apple.com/design/human-interface-guidelines/app-icons/)，输入素材不预裁圆角、不留透明边框，圆角和最终留白交给系统处理。

`build-icon.sh` 将 PNG 与 `assets/AppIcon.icon.json` 装配为临时 `.icon` 文档，通过 Xcode 26+ 的 `actool` 编译，输出包含原生 `IconImageStack` 的 `Assets.car`，并生成适用于旧系统的完整 16–1024 像素 ICNS。图案使用单个不透明位图层，关闭前景玻璃和阴影以保留扁平风格；没有手绘矢量素材。Info.plist 同时设置 `CFBundleIconName` 和 `CFBundleIconFile`。仅把旧图转换成 `.appiconset` 不会修正素材中的双层底板。

CI 的 `validate-app-icon.py` 检查实际编译产物中的原生图标栈、不透明 1024 像素图层、Info.plist 引用和 10 个 ICNS 尺寸。构建不调用图像生成服务。Apple 的[图标编译说明](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)说明编译器会生成旧系统兼容图；这不替代各系统上的 Dock 实测。发布前应启动最终 App，在 Dock 中检查大小、单层底板及小尺寸辨识度，不能只凭 Finder“显示简介”判断。

## 本地复现

在 macOS 26+ 安装并选中完整 Xcode 26+、安装 Node.js 和 Python 3 后：

```sh
bash scripts/ci.sh
```

默认构建目录 `.build/`，产物目录 `dist/`，均由 Git 忽略。可通过 `OCLOUD_BUILD_DIR` 与 `OCLOUD_OUTPUT_DIR` 指定其他绝对路径。本地脚本按当前 Mac 架构命名产物，GitHub 工作流固定构建 Apple Silicon。

CI 只覆盖离线测试与打包。官方登录、真实云相册下载、PhotoKit 权限及 iCloud 同步仍需在用户 Mac 上验证。

构建结果以对应提交的 [Actions 记录](https://github.com/vissong/OCloudSync/actions/workflows/build.yml) 为准。

## 秘密扫描

独立的 `secrets.yml` 工作流在 push、PR 和手动运行时执行。使用 Ubuntu 托管 runner、只读权限和完整 Git 历史，下载 Gitleaks 8.30.1 官方发行包并核验固定 SHA-256；无需账号秘密或 Gitleaks 商业 action 授权。

先在临时仓库验证检出、输出脱敏和浅克隆拒绝，再扫描所有已获取引用的完整历史。失败不会被忽略，不上传可能含私人元数据的扫描报告。运行方式见 [贡献指南](../CONTRIBUTING.md)。GitHub 原生 Secret scanning / Push protection 与此 CI 是独立功能，需在仓库设置核对启用状态。

正式签名、公证及带票据打包使用独立的本机或 GitHub 发布流程，见 [签名与公证](SIGNING.md)。CI 运行公证脚本的离线回归，不访问 Apple 公证服务。
