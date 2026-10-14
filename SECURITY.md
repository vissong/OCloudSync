# 安全问题报告

仅维护最新 main / 最新发布版本的安全修复。项目处于实验阶段，没有固定响应或修复时限。

## 私密报告

公开仓库时使用 GitHub **Private vulnerability reporting**：在 [Security → Advisories](https://github.com/vissong/OCloudSync/security/advisories) 中点击 **Report a vulnerability**，或访问 [新建私密报告](https://github.com/vissong/OCloudSync/security/advisories/new)。

该功能需要维护者在仓库公开时单独启用。如果入口尚不可用，请只开一个不含漏洞细节的 Issue 请求私密联系方式，等待维护者提供渠道；不要在公开 Issue、PR 或评论中提交漏洞详情、账号资料或敏感附件。

报告尽量包含：影响版本、macOS/架构、问题影响、最小复现步骤和合成样本。不要提供真实密码、Cookie、会话令牌、签名下载 URL、个人原片、完整台账/回执、图库数据库、Apple ID 或精确位置。

## 用户端注意事项

App 需要完整照片访问，可能读取原片以确认未完成的导入；只使用你信任并核验来源的构建。会话保存在本机钥匙串和 WebKit 网站数据中。清空原文件缓存不会退出账号或清除登录凭据，详见 [隐私说明](PRIVACY.md)。

如果凭据意外公开，先通过服务提供方终止会话或更换受影响凭据，再联系维护者处理记录；仅删除当前文件不能移除 Git 历史或已经被复制的数据。
