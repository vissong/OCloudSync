# Developer ID 签名与 Apple 公证

公开下载的 App 使用 Developer ID Application 证书签名，再向 Apple 提交公证。默认 CI 仍是无私钥的 ad-hoc 测试构建；正式产物可在持有证书的 Mac 或独立的 GitHub 发布流程中生成，不向普通 PR 工作流提供证书。

## 本机准备

- 有效的 Apple Developer Program 会员，已接受最新协议。
- Xcode、Command Line Tools，以及钥匙串中有效的 Developer ID Application 证书和对应私钥。
- `security find-identity -v -p codesigning` 可列出签名身份。使用输出的 SHA-1 身份标识；不要在仓库保存私钥或 `.p12`。
- 在 Apple 账号生成 App 专用密码，并在自己的终端执行以下命令；按隐藏输入提示输入密码，不把密码放在命令参数或聊天里。

```sh
xcrun notarytool store-credentials OCloudSync-notary \
  --team-id YOUR_TEAM_ID --apple-id 'your-account@example.com'
```

凭据默认保存在本机钥匙串，命令会先向 Apple 验证。Apple 账号密码、App 专用密码、签名私钥均不得提交 Git。

## 构建与验证

从仓库根目录执行，替换身份标识和输出目录。使用与正在运行 App 不同的目录；保留现有 Bundle ID，以便延续已有数据目录。

```sh
OCLOUD_SIGN_IDENTITY='YOUR_CERTIFICATE_SHA1' \
OCLOUD_OUTPUT_DIR="$PWD/dist/signed" bash scripts/build-app.sh
python3 scripts/test-livephoto.py dist/signed/OCloudSync.app/Contents/MacOS/OCloudLivePhoto
```

脚本分别对转换 helper 和主 App 签名，启用 hardened runtime 与安全时间戳，不添加放宽运行时安全性的 entitlement。省略 `OCLOUD_SIGN_IDENTITY` 时仍使用 ad-hoc 签名，只适合开发和离线 CI。

## 公证、附加票据和分发

```sh
python3 scripts/notarize-app.py dist/signed/OCloudSync.app \
  --profile OCloudSync-notary --output dist/notarized
```

`--output` 必须是尚不存在的新目录。脚本复制 App 到该目录的 `work/`，保留待公证原件，不修改输入 App。它会验证 Apple Developer ID 签名、运行时与时间戳，上传 ZIP 并保存 `submission.json`，每次等待最多 60 秒。

若仍是 `In Progress` 或等待时网络中断，使用同一目录继续查询，**不会再次上传**：

```sh
python3 scripts/notarize-app.py dist/signed/OCloudSync.app \
  --profile OCloudSync-notary --output dist/notarized --resume
```

若提交阶段中断、尚未保存 ID，先用 `xcrun notarytool history --keychain-profile OCloudSync-notary` 核对 Apple 是否已接收。不要为未知提交自动新建目录重传。可核对名称和时间后将正确的提交 ID 存为该目录的 `submission.json`（格式为 `{"id":"提交 UUID"}`），再恢复查询。恢复期间保留该目录的原始 `work/`，不要替换或重新签名其中的 App。若脚本被强制终止而遗留 `.lock`，确认没有运行中的发布进程后才删除锁目录。

只有 `Accepted` 才会继续下载公证日志、`stapler staple` / `validate`、签名复验和 `spctl --assess`。全部通过后重新打包带票据的 App，生成目录顶层的 `OCloudSync-macOS-<架构>.zip` 和 `SHA256SUMS`。仅分发这两个文件；`work/upload.zip` 是提交件，不是最终分发件。日志失败或 Gatekeeper 拒绝都会阻止产出。

首次公证处理时间可能超过一次等待。`Invalid` / `Rejected` 需查看 `notary-log.json` 并修复，不能宣称已通过。Apple 公证通过也不替代功能验证：正式签名后仍需人工验证官方登录、照片权限、下载、实况转换及导入；此脚本不会启动 App 或访问个人图库。

转换为正式签名时，macOS 可能重新请求钥匙串和照片权限。保留数据并有序退出旧 App 后再切换。正常“从互联网下载，是否打开”的首次确认仍可能出现。

官方参考：[证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)、[公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[App 专用密码](https://support.apple.com/102654)。

## GitHub 正式发布

工作流 **Release signed macOS App**（`release.yml`）只允许在 `main` 手动运行。先执行无凭据的完整测试；签名 job 下载该次运行的测试产物，以 Developer ID 重新签名并提交 Apple；独立的发布 job 只有 GitHub Release 写权限，没有 Apple 凭据。第三方 Actions 固定提交 SHA。

仓库 Settings → Environments 中需有 `release` 环境，Deployment branches and tags 只允许 **main 分支**，不允许通配符或同名 Tag。将以下五项保存为该环境的 Secrets，而非普通仓库 Secrets：

| Secret | 内容 |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | 包含证书及私钥的加密 `.p12` 的 Base64 |
| `APPLE_CERTIFICATE_PASSWORD` | `.p12` 导出密码 |
| `APPLE_ID` | 公证使用的 Apple 账号 |
| `APPLE_APP_PASSWORD` | Apple App 专用密码，建议专供 GitHub 公证 |
| `APPLE_TEAM_ID` | 证书所属团队 ID |

本机交互配置工具会先核对环境限制和 `.p12`，再隐藏输入密码并通过 `gh` 标准输入上传。只在自己的终端运行，不把密码提供给聊天或 shell 参数：

```sh
python3 scripts/configure-release-secrets.py \
  --p12 "$HOME/Downloads/OCloudSync-DeveloperID.p12" \
  --repo OWNER/OCloudSync --team-id YOUR_TEAM_ID
```

`.cer` 不包含私钥。应从“钥匙串访问 → 登录 → 我的证书”导出证书及其私钥为 `.p12`。CI 使用临时钥匙串，不修改本机钥匙串；导入只允许代码签名工具访问，验证凭据后销毁导出文件，job 结束时清理临时钥匙串。受信任的 main 代码能够使用这些凭据，因此合入 main 前应审查工作流和发布脚本。

在 Actions 中打开 **Release signed macOS App → Run workflow**，分支选 `main`，Tag 填与 App 内版本一致的 `vX.Y.Z`。默认创建**草稿 Release**；勾选 `publish` 才立即发布。流程拒绝已有 Tag 或 Release，不重定向旧 Tag、不覆盖已有附件。若需重新发布，应先核对原草稿/版本，不盲目重跑。

公证最多等待 20 分钟。只有 Accepted、附票、签名校验、Gatekeeper 以及最终 ZIP 解压复验全部通过，才生成 `OCloudSync-notarized-…` 工件和 Release 附件。下载正式版本应使用 Release 中的 `OCloudSync-macOS-arm64.zip`，并用 `SHA256SUMS` 校验；普通 **Build macOS App** 工件和 `unsigned-release-input-…` 均非正式发行包。

若公证中断，流程失败并尽量保留 `NOT-FOR-DISTRIBUTION-notary-recovery-…` 工件 7 天，其中只有提交记录与待公证 App，没有钥匙串或凭据。不要分发这个恢复工件，也不要立即重跑整个工作流重复提交。维护者可下载并解压其中的 `notary-recovery.zip`，保留原 `notarized/work/`，使用本机的 profile 对 `notarized/` 执行 `--resume`。若未保存提交 ID，先查 Apple history。正常签名产物保留 14 天，发行附件由 Release 长期保留。
