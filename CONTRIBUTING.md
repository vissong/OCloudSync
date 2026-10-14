# 参与开发

欢迎通过 Issue 描述问题或提出小范围 PR。安全问题请使用 [私密报告](SECURITY.md)。提交贡献即表示你有权将该贡献按本仓库 [MIT 许可证](LICENSE) 提供；引用外部实现请保留来源和许可说明。

## 环境和验证

开发需要 macOS、完整 Xcode 26+（App 图标使用 Icon Composer 格式，由 `actool` 编译）；完整回归另需 Node.js 24、Python 3。App 无第三方 Swift 包依赖。

```sh
swift test
bash scripts/ci.sh
```

`ci.sh` 会执行 Swift、JavaScript 和 Python 回归、合成媒体转换、Release 构建、签名与 ZIP 校验，产物在 `dist/`。测试不需要 OPPO 或 Apple 账号，不操作个人图库。真实登录与 PhotoKit 授权测试应在本人设备、本人授权的独立小样本上执行，不能把私有样本放到 CI。

## 秘密扫描

使用 [Gitleaks v8.30.1 官方发行版](https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1)，下载适合当前平台的归档并核对该发行版的 SHA-256。可把二进制解压到临时工具目录，不需要系统安装。

```sh
# 将此路径替换为核验过的可执行文件路径。
export GITLEAKS_BIN=/path/to/gitleaks
python3 scripts/test-secret-scan.py
bash scripts/scan-secrets.sh
# 提交前检查已暂存的变更；完整历史检查不会覆盖未提交内容。
bash scripts/scan-secrets.sh --staged
```

完整历史检查拒绝浅克隆。CI `secrets.yml` 使用 `fetch-depth: 0`、固定版本及 Linux x64 SHA-256，扫描所有已获取引用，发现秘密时失败并脱敏输出。更新 Gitleaks 时同时更新脚本中的版本、工作流的版本/校验值和本文；Dependabot 只维护 GitHub Actions，工具发行版需人工检查。

合成回归会在临时仓库中验证：干净仓库通过、暂存凭据被拒绝、删除文件后历史仍能检出，以及浅克隆不能冒充完整扫描。不要通过泛化白名单掩盖发现；先确认是否需要撤销真实凭据。

## 修改与提交

- 每个 PR 尽量处理一个问题，说明触发条件、行为变化和验证结果。
- 维护下载、导入、回执和取消之间的边界；图库提交结果未知时不能盲目重传。
- 使用合成图片/视频和伪造账号标识，新增行为应覆盖失败、重启和取消路径。
- 文档改动核对相对链接，配置改动核对真实 CI；不要为纯文字调整新增重复实现的测试。
- 不提交原片、台账、导入回执、完整抓包、Cookie、签名 URL、真实 GPS、用户路径或包含这些信息的截图。
- 更新公开文档时保留“已验证”与“未验证”的边界，不把一次单机结果写成所有系统/设备均支持。
