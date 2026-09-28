# 基础设施即代码（infrastructure/）

云资源与配置的可复现定义。目标是「环境可由代码重建」，不靠手工点控制台。

| 子目录 | 用途 |
| --- | --- |
| `terraform/` | 云资源编排（VPC、实例、安全组、DNS 等） |
| `ansible/` | 配置管理与批量执行（装软件、改配置、批量命令） |

## 规则

1. 变更 IaC 前，先 `--dry-run` / `plan` / `check`，确认影响范围。
2. 状态文件（`.terraform/`、`*.retry`）不入库（见 `.gitignore`）。
3. 密钥用变量/TFVars 引用，不硬编码。
4. 每次 apply/变更后写 `state/CHANGELOG.md`。
5. 云资源与 `docs/inventory/servers.md`、`services.md` 保持一致：IaC 变更后同步更新清单。

## 何时新增子目录

- 引入新 IaC 工具（如 Pulumi、Crossplane）时，新建对应目录并写一条 ADR 说明选型理由。
