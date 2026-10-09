# 操作手册（runbooks/）

本目录放**具体任务的分步执行文档**：照着就能做，不用临场想。每条 runbook 是「操作规范 + 实际步骤 + 验证 + 回滚」的组合。

## 规范

- 文件名：`{主题}-{动作}.md`，如 `nginx-reload.md`、`postgres-backup.md`。
- 每条 runbook 用 [`../../templates/runbook.md`](../../templates/runbook.md) 模板写。
- 写完在下方索引登记一行。
- 涉及脚本的，指向 `scripts/` 下的对应脚本，不把脚本内容抄进文档（SSOT）。
- 每次执行 runbook 后，在 `state/CHANGELOG.md` 追加记录。

## 索引

| Runbook | 用途 | 环境 | 最近更新 |
| --- | --- | --- | --- |
| [`service-restart.md`](service-restart.md) | 重启单个服务（示例示范） | prod/staging/dev | 2026-02-01 |
| [`connect-bt-he1k.md`](connect-bt-he1k.md) | 密钥登录测试服务器 bt-he1k（<TEST_HOST_IP>）并验证 | test | 2026-09-28 |
| [`harden-bt-panel.md`](harden-bt-panel.md) | 宝塔面板加固：开启 HTTPS + 设置访问 IP 白名单 | test | 2026-09-28 |
| [`migrate-astrbot.md`](migrate-astrbot.md) | 把本机 AstrBot（插件/配置/数据库）迁移到服务器 Docker，含三个必修项 | test | 2026-09-28 |
| [`migrate-sillytavern.md`](migrate-sillytavern.md) | 把本机 SillyTavern（酒馆）迁到服务器 Docker，含白名单 403 与扩展层级两个坑 | test | 2026-09-28 |
| [`migrate-cloudflared-tunnel.md`](migrate-cloudflared-tunnel.md) | 把本机 Cloudflare Tunnel 迁到服务器，含 `--overwrite-dns` 不生效的坑与「停掉本机验证」判据 | test | 2026-09-28 |
| [`napcat-drop-alert.md`](napcat-drop-alert.md) | NapCat QQ 掉线告警：安装、日常操作、排障（先查锁）、残余风险 | test | 2026-10-09 |
| [`ops-agent.md`](ops-agent.md) | 服务器常驻执行通道 ops-agent：日常用法、重装换 token、排障与安全须知 | test | 2026-10-09 |
| [`astrbot-deps.md`](astrbot-deps.md) | AstrBot 插件依赖：换腾讯内网 pip 源、缓存持久化、重建后只能等（#23） | test | 2026-10-09 |

## 建议首批补充的 runbook

- 部署：`deploy-web.md`、`deploy-db.md`
- 备份恢复：`backup-db.md`、`restore-db.md`
- 例行：`renew-cert.md`、`rotate-secrets.md`、`os-patch.md`
- 应急：`service-restart.md`、`failover.md`
