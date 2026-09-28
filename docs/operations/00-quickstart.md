# 00 · 新 Agent 快速上手（5 分钟）

本文件让任何新加入的 agent 在 5 分钟内知道「该去哪、该看什么、该守什么规矩」。

## 一、先读（顺序）

1. `AGENTS.md`（本工作区宪法，已自动加载）——行为红线与 SSOT 原则。
2. 本文件——上手路径。
3. `state/CHANGELOG.md` 尾部——最近发生了什么。
4. `state/TASKS.md`——有哪些活在进行，别撞车。
5. `docs/inventory/`——服务器、服务、密钥位置在哪。

## 二、动手前自检清单

- [ ] 我要改的东西，在 `docs/inventory/` 里查到了唯一事实来源吗？
- [ ] 我的任务和 `state/TASKS.md` 里的进行中任务有冲突吗？
- [ ] 我的操作是破坏性的吗？是 → 先写回滚方案，并确认已获用户批准。
- [ ] 我清楚操作完成后要往哪写记录吗？（`state/CHANGELOG.md` + `state/TASKS.md`）

## 三、做完后必做（三件套）

1. 验证结果（真实输入跑通，不假装绿灯）。
2. 追加 `state/CHANGELOG.md` 记录。
3. 更新 `state/TASKS.md` 状态。

## 四、常见任务去哪

| 我要做的事 | 去这里 |
| --- | --- |
| 部署一个服务 | `docs/runbooks/` + `scripts/deploy/` |
| 备份/恢复 | `scripts/backup/` + `docs/operations/02-safety.md` 回滚部分 |
| 检查服务器健康 | `scripts/healthcheck/` |
| 加一台新服务器 | `docs/inventory/servers.md` + `infrastructure/` |
| 记一个踩坑结论 | `docs/decisions/` 新建 ADR |
| 报告一个已知问题 | `state/KNOWN-ISSUES.md` |
| 交接给另一个 agent | `templates/handoff.md` 填好放 `state/` |
| 出事故了 | `docs/postmortems/` + 先止血再复盘 |

## 五、一句话原则

**信息只存一处、操作必留痕、破坏性操作先想回滚。**
