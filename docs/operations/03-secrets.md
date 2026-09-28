# 03 · 密钥与敏感信息管理

密钥是生产安全的第一道防线，泄漏即事故。本文件是密钥处理的唯一规范。

## 1. 铁律

- 密钥**绝不**写入代码、文档、日志、commit message、聊天记录。
- 密钥只存两处：`secrets/`（已 gitignore，仅本地）或外部密钥库（如云厂商 KMS/Secrets Manager）。
- 代码与配置里只用**引用**（环境变量名、密钥库路径、占位符），不含真实值。

## 2. 存放约定

- `secrets/` 目录下按用途分文件，文件名见 `secrets/README.md`。
- 外部密钥库：在 `docs/inventory/credentials.md` 记录**位置引用**（密钥名/ARN/路径），绝不记明文。
- 环境变量：命名用 `SCREAMING_SNAKE_CASE`，前缀按用途，如 `DB_PASSWORD`、`API_TOKEN`。

## 3. 使用规范

- 脚本通过环境变量或密钥库读取，不硬编码。
- 日志、报错输出前先脱敏（`***`），不打印密钥、token、密码。
- 配置文件模板放 `configs/`，占位符写 `__PLACEHOLDER__`，真值在 `secrets/` 或密钥库。

## 4. 轮换与泄漏处置

- 密钥**定期轮换**，轮换记录写 CHANGELOG。
- 疑似泄漏：立即轮换 → 撤销旧密钥 → 查访问日志 → 写 postmortem → 记录到 CHANGELOG。
- 共享密钥最小化：一人/一服务一密钥，不共用一个管理员密码。

## 5. 检查手段

- 提交前自检：`git status` 确认 `secrets/`、`*.pem`、`.env` 未被纳入。
- 禁止用 `grep` 之外的方式把密钥明文写进任何 `docs/`、`scripts/`、`configs/` 文件。
- `.gitignore` 已覆盖常见敏感后缀；新增敏感文件类型时同步更新 `.gitignore`。
