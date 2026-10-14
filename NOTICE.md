# 代码来源

OCloudSync 由 Vissong 维护，本仓库代码与文档按 [MIT](LICENSE) 许可提供。

## MotionPhotoFromiPhotos

`Sources/LivePhotoWorker/Conversion.swift` 的转换基础改编自同一作者的私有 MotionPhotoFromiPhotos 项目，参考文件为 `native/make_livephoto_with_audio.swift`。可核对的参考版本为 `6a699608438c313d85675d54b425e2e2317b4580`。原项目保持私有；本仓库中发布的改编代码包含在上述 MIT 授权中，构建或运行不需要访问原仓库。

OCloudSync 在此基础上集成了封面时间解析、元数据校验、独立 worker、取消/超时、转换缓存、静态回退及 PhotoKit 导入恢复。本项目不使用原项目的图库整理/删除流程，也不直接修改 Photos 数据库。

## 平台与工具

- App 使用 Apple 提供的系统框架，不在仓库内分发这些框架；平台名称和商标归其各自所有者。
- OPPO 适配器调用用户已登录网页的功能，不随仓库打包 OPPO 网页应用或凭据。MIT 许可证不授予第三方服务或商标的额外权限。
- 开发/CI 使用 Gitleaks 进行秘密扫描；该工具独立下载，不嵌入 App，遵循其 [MIT 许可证](https://github.com/gitleaks/gitleaks/blob/v8.30.1/LICENSE)。GitHub Actions 的许可证由各自仓库提供。
