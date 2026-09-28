# 密钥（secrets/）

本目录存放真实密钥，**已被 `.gitignore` 忽略，绝不提交**。

## 目录约定

按用途分子目录，如：

| 路径 | 用途 |
| --- | --- |
| `secrets/ssh/` | SSH 私钥 |
| `secrets/db/` | 数据库凭据 |
| `secrets/api/` | API token |
| `secrets/tls/` | 证书私钥 |

## 铁律

1. 明文只放这里，或放外部密钥库（KMS/Secrets Manager）。
2. 代码/配置里只用引用，见 `docs/operations/03-secrets.md`。
3. 每个密钥在 `docs/inventory/credentials.md` 登记**引用**（不记明文）。
4. 定期轮换，轮换记录写 CHANGELOG。
5. 提交前 `git status` 确认本目录内容未被纳入。
