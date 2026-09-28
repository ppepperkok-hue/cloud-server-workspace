# 云服务器运维工作区

用于云服务器**调试、部署、维护**的统一工作区。所有 agent 与协作者在此按统一标准协作：信息集中维护、操作全程可追溯、可回滚、可复现。

> 🌐 English: [`README.en.md`](README.en.md) · 许可证：[`LICENSE`](LICENSE) (MIT)

> ⚠️ **本仓库是公开的。** 所有清单、runbook、ADR、脚本里**只写占位符**（`<TEST_HOST_IP>`、`<OPERATOR_IP>`、`<QQ_ACCOUNT_A>` 之类），真值放在已 gitignore 的 `secrets/redaction-map.json`。
> **提交前必须跑** `python scripts/utils/redact-workspace.py --check`，细则见 [`docs/inventory/README.md`](docs/inventory/README.md#本仓库是公开的--提交前必须脱敏)。

## 快速开始（新 agent 必读，按顺序）

1. [`AGENTS.md`](AGENTS.md) — 行为宪法，本工作区最高准则。
2. [`docs/operations/00-quickstart.md`](docs/operations/00-quickstart.md) — 5 分钟上手指南。
3. [`state/CHANGELOG.md`](state/CHANGELOG.md) — 最近变更与当前状态（每次必看）。
4. [`state/TASKS.md`](state/TASKS.md) — 进行中任务，避免与其他 agent 冲突。
5. [`docs/inventory/`](docs/inventory/README.md) — 服务器/服务/密钥位置唯一事实来源。

## 目录结构

```
cloud-server-workspace/
├── AGENTS.md              # Agent 宪法（自动加载，最高准则）
├── README.md              # 本文件：总入口与导航
├── .gitignore             # 忽略 secrets/ logs/ tmp/ 等敏感与临时文件
├── docs/                  # 文档中心（单一事实来源 SSOT）
│   ├── operations/        #   操作规范：上手、约定、安全、密钥、DR、监控、权限
│   ├── runbooks/          #   操作手册：具体任务的分步执行文档
│   ├── inventory/         #   清单：服务器、服务、密钥位置（唯一来源）
│   ├── decisions/         #   决策：ADR 架构决策记录
│   └── postmortems/       #   复盘：事故分析与改进
├── infrastructure/        # 基础设施即代码（IaC）
│   ├── terraform/         #   云资源编排
│   └── ansible/           #   配置管理与批量执行
├── scripts/               # 运维脚本（按用途分类）
│   ├── deploy/            #   部署
│   ├── backup/            #   备份与恢复
│   ├── healthcheck/       #   健康检查
│   ├── maintenance/       #   例行维护
│   └── utils/             #   通用工具
├── configs/               # 配置模板（已脱敏，不含密钥）
├── secrets/               # 密钥（gitignore，仅本地，见 README 内说明）
├── state/                 # 共享运行状态（防信息孤岛的关键）
│   ├── CHANGELOG.md       #   操作日志（追加式，每次操作必写）
│   ├── TASKS.md           #   任务看板：待办/进行中/已完成
│   └── KNOWN-ISSUES.md    #   已知问题
├── templates/             # 文档模板：runbook、操作记录、复盘、交接
├── logs/                  # 运行日志（gitignore）
└── tmp/                   # 临时文件（gitignore）
```

## 核心原则

- **单一事实来源（SSOT）**：清单、决策、状态各只存一处，禁止散落重复。
- **可追溯**：每次操作写入 `state/CHANGELOG.md`，谁、何时、做了什么、结果如何。
- **可回滚**：破坏性操作必先有回滚方案。
- **幂等**：脚本可重复执行、结果一致。

## 导航

| 需求 | 入口 |
| --- | --- |
| 上手 | [`docs/operations/00-quickstart.md`](docs/operations/00-quickstart.md) |
| 目录/命名/状态约定 | [`docs/operations/01-conventions.md`](docs/operations/01-conventions.md) |
| 操作安全与变更控制 | [`docs/operations/02-safety.md`](docs/operations/02-safety.md) |
| 密钥管理 | [`docs/operations/03-secrets.md`](docs/operations/03-secrets.md) |
| 灾难恢复（DR） | [`docs/operations/04-dr.md`](docs/operations/04-dr.md) |
| 监控与告警 | [`docs/operations/05-monitoring.md`](docs/operations/05-monitoring.md) |
| 访问控制与权限 | [`docs/operations/06-access.md`](docs/operations/06-access.md) |
| 具体任务怎么执行 | [`docs/runbooks/`](docs/runbooks/README.md) |
| 服务器/服务在哪 | [`docs/inventory/`](docs/inventory/README.md) |
| 为什么这么做 | [`docs/decisions/`](docs/decisions/README.md) |
| 出了事故怎么复盘 | [`docs/postmortems/`](docs/postmortems/README.md) |
