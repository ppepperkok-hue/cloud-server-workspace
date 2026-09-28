# Cloud Server Ops Workspace

A unified workspace for cloud server **debugging, deployment, and maintenance**. All agents and collaborators work here under one standard: information is centralized, and every operation is traceable, rollback-able, and reproducible.

> 📄 中文入口 / Chinese: [`README.md`](README.md). Note: the detailed operational docs under `docs/` and `state/` are written in Chinese.

## Quick Start (new agents, in order)

1. [`AGENTS.md`](AGENTS.md) — the constitution; the highest rule of this workspace.
2. [`docs/operations/00-quickstart.md`](docs/operations/00-quickstart.md) — 5-minute onboarding guide.
3. [`state/CHANGELOG.md`](state/CHANGELOG.md) — recent changes and current state (read every time).
4. [`state/TASKS.md`](state/TASKS.md) — in-progress tasks, to avoid colliding with other agents.
5. [`docs/inventory/`](docs/inventory/README.md) — single source of truth for servers, services, ports, and credential locations.

## Directory Layout

```
cloud-server-workspace/
├── AGENTS.md              # Agent constitution (auto-loaded; highest rule)
├── README.md              # Chinese entry point and navigation
├── README.en.md           # This file (English entry point)
├── LICENSE                # MIT license
├── .gitignore             # Ignore secrets/, logs/, tmp/, and other sensitive/temp files
├── docs/                  # Documentation center (single source of truth, SSOT)
│   ├── operations/        #   Operational standards: onboarding, conventions, safety, secrets, DR, monitoring, access
│   ├── runbooks/          #   Runbooks: step-by-step procedures for specific tasks
│   ├── inventory/         #   Inventory: servers, services, credential locations (single source)
│   ├── decisions/         #   Decisions: ADR records
│   └── postmortems/       #   Postmortems: incident analysis and improvements
├── infrastructure/        # Infrastructure as Code (IaC)
│   ├── terraform/         #   Cloud resource orchestration
│   └── ansible/           #   Configuration management and batch execution
├── scripts/               # Operational scripts (organized by purpose)
│   ├── deploy/            #   Deployment
│   ├── backup/            #   Backup and restore
│   ├── healthcheck/       #   Health checks
│   ├── maintenance/       #   Routine maintenance
│   └── utils/             #   General utilities
├── configs/               # Config templates (sanitized; no secrets)
├── secrets/               # Secrets (gitignored; local only — see README inside)
├── state/                 # Shared runtime state (the key to preventing information silos)
│   ├── CHANGELOG.md       #   Operation log (append-only; write after every operation)
│   ├── TASKS.md           #   Task board: todo / in-progress / done
│   └── KNOWN-ISSUES.md    #   Known issues
├── templates/             # Document templates: runbook, operation record, postmortem, handoff
├── logs/                  # Runtime logs (gitignored)
└── tmp/                   # Temporary files (gitignored)
```

## Core Principles

- **Single Source of Truth (SSOT)**: inventory, decisions, and state each live in exactly one place — no scattered duplicates.
- **Traceable**: every operation is appended to `state/CHANGELOG.md` (who, when, what, result).
- **Rollback-able**: destructive operations must have a rollback plan first.
- **Idempotent**: scripts are repeatable and yield consistent results.

## Navigation

| Need | Entry |
| --- | --- |
| Onboarding | [`docs/operations/00-quickstart.md`](docs/operations/00-quickstart.md) |
| Directory / naming / state conventions | [`docs/operations/01-conventions.md`](docs/operations/01-conventions.md) |
| Operational safety & change control | [`docs/operations/02-safety.md`](docs/operations/02-safety.md) |
| Secrets management | [`docs/operations/03-secrets.md`](docs/operations/03-secrets.md) |
| Disaster recovery (DR) | [`docs/operations/04-dr.md`](docs/operations/04-dr.md) |
| Monitoring & alerting | [`docs/operations/05-monitoring.md`](docs/operations/05-monitoring.md) |
| Access control & permissions | [`docs/operations/06-access.md`](docs/operations/06-access.md) |
| How to run a specific task | [`docs/runbooks/`](docs/runbooks/README.md) |
| Where servers/services live | [`docs/inventory/`](docs/inventory/README.md) |
| Why a decision was made | [`docs/decisions/`](docs/decisions/README.md) |
| How to review an incident | [`docs/postmortems/`](docs/postmortems/README.md) |

## License

[MIT](LICENSE)
