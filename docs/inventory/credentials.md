# 密钥位置引用（credentials）

> **只记「去哪取」，绝不记明文。** 明文密钥只存在于 `secrets/`（已 gitignore）或外部密钥库。

| 用途 | 位置引用（文件路径 / 密钥库名 / ARN） | 轮换周期 | 负责人 | 备注 |
| --- | --- | --- | --- | --- |
| （示例）web-01 SSH 私钥 | secrets/ssh/web-01 | 180 天 | agent-a | 仅内网可连 |
| （示例）生产 DB 密码 | secrets/db/prod.env | 90 天 | agent-a | 或用 KMS 引用 |

## 规则

- 新增密钥：先在 `secrets/` 建文件，再在这里登记**引用**。
- 轮换：到期轮换，记录到 CHANGELOG。
- 泄漏：按 `docs/operations/03-secrets.md` 第 4 节处置。
