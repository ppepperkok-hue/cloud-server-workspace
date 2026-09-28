# 密钥位置引用（credentials）

> **只记「去哪取」，绝不记明文。** 明文密钥只存在于 `secrets/`（已 gitignore）或外部密钥库。

| 用途 | 位置引用（文件路径 / 密钥库名 / ARN） | 轮换周期 | 负责人 | 备注 |
| --- | --- | --- | --- | --- |
| bt-he1k root SSH 私钥 | secrets/ssh/lighthouse-he1k.pem | 180 天 | agent | 腾讯云密钥对 `<TEST_USER>`（RSA 2048, SHA256:<SSH_KEY_FINGERPRINT>）；原始下载位置 `<LOCAL_KEY_DOWNLOAD_PATH>`；控制台创建于 2026-09-28 12:44:46，绑定实例后需重启生效。2026-09-28 已比对：与主机 `/root/.ssh/authorized_keys` 内指纹一致 |
| bt-he1k 宝塔面板管理员凭据 | secrets/bt-panel/bt-he1k-panel.txt | 90 天 | agent | 面板地址 `http://<TEST_HOST_IP>:8888/<PANEL_ENTRY>`，用户名 `admin`；文件内含明文密码，可用 `bt default` 重新生成；**不进文档、不进日志、不入库** |

## 规则

- 新增密钥：先在 `secrets/` 建文件，再在这里登记**引用**。
- 轮换：到期轮换，记录到 CHANGELOG。
- 泄漏：按 `docs/operations/03-secrets.md` 第 4 节处置。
