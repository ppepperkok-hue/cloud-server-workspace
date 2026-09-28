# 配置模板（configs/）

脱敏配置模板。真实值**不放在这里**，用占位符 `__PLACEHOLDER__` 或环境变量引用。

## 规则

1. 只放模板与默认值，不放密钥、真实 IP、真实密码。
2. 占位符统一 `__PLACEHOLDER__` 或 `${VAR_NAME}`。
3. 每个模板文件头注释（英文）说明：用途、如何填充、对应真实配置在哪。
4. 变更模板后，在 `state/CHANGELOG.md` 记录。

## 常见模板

| 模板 | 用途 |
| --- | --- |
| （示例）`nginx.conf.tpl` | nginx 反代配置模板 |
| （示例）`.env.tpl` | 应用环境变量模板（真值在 secrets/） |

## 真实配置去哪

- 密钥/密码 → `secrets/`（已 gitignore）
- 可复现的服务器配置 → `infrastructure/ansible/` 或 `infrastructure/terraform/`
