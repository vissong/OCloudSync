# Developer ID 签名与 Apple 公证

公开下载的 App 使用 Developer ID Application 证书签名，再向 Apple 提交公证。默认 CI 仍是无私钥的 ad-hoc 测试构建；正式产物由维护者在持有证书的 Mac 上生成，不向普通 PR 工作流提供证书。

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
