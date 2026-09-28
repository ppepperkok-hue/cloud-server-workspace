# 事故复盘（postmortems/）

出事故不是结束，复盘后的改进才是。本目录记录事故的完整分析与改进项，避免重蹈覆辙。

## 规范

- 文件名：`{YYYY-MM-DD}-{slug}.md`，如 `2026-02-01-nginx-cert-expired.md`。
- 用 [`../../templates/postmortem.md`](../../templates/postmortem.md) 模板写。
- **不追责、只找根因**；改进项要可执行、有 owner、有期限。
- 复盘结论若形成长期规则 → 更新 `docs/operations/` 或写 ADR。
- 关联的 `state/KNOWN-ISSUES.md` 与 `state/CHANGELOG.md` 记录要互相引用。

## 索引

| 日期 | 标题 | 影响级别 | 状态 |
| --- | --- | --- | --- |
| （暂无） | | | |

## 何时写复盘

- 生产服务中断或降级。
- 数据丢失或泄漏。
- 人为误操作造成实质影响。
- 任何「差点出事但值得总结」的险情。
