# OCloudSync · OPPO 照片同步

[![Build macOS App](https://github.com/vissong/OCloudSync/actions/workflows/build.yml/badge.svg)](https://github.com/vissong/OCloudSync/actions/workflows/build.yml)
[![Secret scan](https://github.com/vissong/OCloudSync/actions/workflows/secrets.yml/badge.svg)](https://github.com/vissong/OCloudSync/actions/workflows/secrets.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

将本人 OPPO 云相册中的照片和视频下载到 Mac，校验、查重后导入系统“照片”图库，再由系统 iCloud 照片同步。

**独立、非官方的实验性项目，与 OPPO、HeyTap 或 Apple 无隶属或背书关系。** 使用已登录官方网页的私有接口；页面更新、会话过期或服务限制可能导致功能暂停，不保证长期兼容。请只处理你有权访问的媒体，并遵守相关服务规则。

## 可以做什么

- 首次建立历史基线，之后自动同步新增照片与视频；也可按拍摄日期选择历史文件导入。
- 支持 JPEG、HEIC/HEIF、PNG、部分 OPPO JPEG 实况及 MP4/MOV/M4V 视频。
- 实况转换为 Apple Live Photo；转换失败可回退静态照片。部分 HEVC 视频支持无损封装兼容处理。
- 保存下载与导入进度，支持去重、失败重试、队列查看/取消、缓存占用统计/清理。
- 保留可靠拍摄时间，提供本 App 已导入资产的日期核对及修复。

## 开始前

- macOS 13+、本人可登录的 OPPO 云相册，以及可授权访问的系统照片图库。自动化构建目前只验证 `macos-15` Apple Silicon runner；最低系统版本和 Intel 尚无持续验证矩阵。
- 需要上传 iCloud 时，请自行在“照片”设置中开启 iCloud 照片，并确认有足够空间。
- 先备份重要照片，用少量文件验证行为。**“已导入图库”仅表示本机导入成功，不代表 iCloud 服务端已完成上传。**
- 原文件会缓存到本机，需要预留磁盘空间；可以手动清理缓存，但云端已删除的文件将无法重新下载。

## 从源码构建

安装 Xcode Command Line Tools（提供 Swift 5.9+）后，在终端执行：

```sh
git clone https://github.com/vissong/OCloudSync.git
cd OCloudSync
OCLOUD_OUTPUT_DIR="$PWD/dist" bash scripts/build-app.sh
open dist/OCloudSync.app
```

源码无第三方 Swift 包依赖，运行 App 不需要 Node、Python 或浏览器自动化工具。完整测试另需 Node.js 24 和 Python 3，参见 [贡献指南](CONTRIBUTING.md)。

正式安装包从 [GitHub Releases](https://github.com/vissong/OCloudSync/releases) 下载，采用 Developer ID 签名并通过 Apple 公证，同时提供 SHA-256 校验文件。普通 Actions 构建和默认本地构建采用 ad-hoc 签名；Actions 工件保留 14 天，获取方式见 [构建说明](docs/CI.md)。本地重新构建可能需要重新授权照片或钥匙串；不要为运行 App 关闭系统安全保护。

## 首次使用

1. 打开 App，在“OPPO 登录”完成官方登录及本人验证。
2. 授予完整照片访问，用于读取去重元数据、核验原片和导入。
3. 点击“启用自动同步”。**首次成功扫描仅建立历史基线，不导入已有照片/视频。**
4. 如需历史内容，进入“按时间导入”，预览拍摄日期范围后选择文件加入队列。
5. 在“导入队列”查看结果；“清空全部队列”取消剩余任务并保留查重记录。“同步概览”可刷新或清空本机缓存。

关闭窗口后仍在菜单栏运行；退出 App 或 Mac 休眠时停止。自动同步开关会保留，当前未配置开机启动。

## 需要知道的限制

- 按同媒体类型、同文件名（忽略大小写）、同拍摄秒判断重复。因此同名同时间但内容不同也会跳过；不同文件名或时间的相同内容不会仅因哈希相同而跳过。
- OPPO 实况的 HEIC/H.264 转换会重编码，不是字节级无损；原始复合文件保留到手动清理。并非所有固件和实况容器都支持，厂商私有元数据不保证保留。
- 日期范围按拍摄时间筛选；缺少有效云端拍摄时间的项目不会被范围预览选中。导入日期可回退到可靠原文件元数据，但不会用下载时间冒充拍摄时间。
- 轻量扫描可能延迟发现首批之外、且不改变总数的旧文件更新；每天的完整核对或手动“完整核对”用于补充检查。
- 登录续期不能绕过强制登录、风控或服务端会话期限。程序不会删除 OPPO 云端文件，也不会直接管理 iCloud 服务端逐项上传。

## 文档与反馈

- [使用与行为详解](docs/USER-GUIDE.md) · [更新记录](CHANGELOG.md)
- [隐私与本机数据](PRIVACY.md) · [安全漏洞报告](SECURITY.md)
- [构建和 CI](docs/CI.md) · [贡献指南](CONTRIBUTING.md) · [验证边界](docs/VALIDATION.md)
- [架构与数据流](docs/PLAN.md) · [实况转换](docs/LIVEPHOTO.md) · [视频兼容](docs/HEVC-COMPATIBILITY.md)

普通问题请使用 [Issues](https://github.com/vissong/OCloudSync/issues)，先删除账号、Cookie、原片、图库标识和私人路径。安全问题不要公开披露细节，按 [SECURITY.md](SECURITY.md) 私下报告。

## 许可证与来源

[MIT License](LICENSE)，Copyright (c) 2026 Vissong。实况转换部分改编自作者的私有 MotionPhotoFromiPhotos 项目；其独立仓库无需公开即可构建本项目，详见 [代码来源](NOTICE.md)。

正式签名与 Apple 公证发布流程见[签名与公证](docs/SIGNING.md)。普通构建 CI 工件仍为未公证测试版；正式安装包以 Release 附件为准。
