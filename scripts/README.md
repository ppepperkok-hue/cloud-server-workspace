# 运维脚本（scripts/）

可执行脚本统一放这里，按用途分子目录。脚本是英文代码，注释英文。

| 子目录 | 用途 |
| --- | --- |
| `deploy/` | 部署脚本 |
| `backup/` | 备份与恢复脚本 |
| `healthcheck/` | 健康检查脚本 |
| `maintenance/` | 例行维护（证书续期、补丁、清理） |
| `utils/` | 通用工具（日志脱敏、主机探测等） |

## 脚本规范

1. 文件头注释（英文）写清：用途、用法、前置条件、风险、是否幂等。
2. **幂等**：可重复执行、结果一致。
3. 破坏性脚本：支持 `--dry-run` 或执行前二次确认。
4. 密钥从环境变量或 `secrets/` 读取，**不硬编码**。
5. 新增脚本后，在本目录 `README.md` 的索引表登记。

## 脚本索引

| 脚本 | 用途 | 幂等 | 风险 |
| --- | --- | --- | --- |
| [`healthcheck/check-disk.sh`](healthcheck/check-disk.sh) | 磁盘使用率告警（示例示范） | 是 | 无 |
| [`healthcheck/server-inventory.sh`](healthcheck/server-inventory.sh) | 主机只读盘点：系统/硬件/网络/安全基线/端口/服务/计划任务/宝塔面板/包更新，输出 22 个分区 | 是 | 无（只读） |
| [`healthcheck/status.sh`](healthcheck/status.sh) | 一页式健康巡检：主机/资源/服务/容器/监听/四套应用/安全基线/补丁，含日志错误与 SSH 尝试统计 | 是 | 无（只读） |
| [`maintenance/harden-bt-panel.sh`](maintenance/harden-bt-panel.sh) | 宝塔面板加固：开启面板 HTTPS（SHA-256 自签）+ 设置访问 IP 白名单，自动备份与回滚说明 | 是 | 中（白名单写错会挡自己，可用 `bt 13` 复位；SSH 不受影响） |
| [`maintenance/os-upgrade.sh`](maintenance/os-upgrade.sh) | 以 systemd 瞬态单元脱离 SSH 会话执行 `dnf -y upgrade`，带日志与 `dnf history` 回滚指引 | 是 | 中（内核/glibc 升级需重启；先看 `dnf history` 记下事务号） |
| [`utils/ssh-bt-he1k.ps1`](utils/ssh-bt-he1k.ps1) | 连 bt-he1k 的执行封装：密钥、known_hosts、脚本投递（gzip+base64，规避 Windows argv 截断） | 是 | 低 |
| [`deploy/install-docker.sh`](deploy/install-docker.sh) | 在 OpenCloudOS 9 上装 Docker（`moby`+`docker-compose`，配 registry 镜像）并启动 | 是 | 中（会写 `/etc/docker/daemon.json`；`docker-ce` 与 `moby` 互斥见 ADR-0003） |
| [`deploy/package-astrbot-data.py`](deploy/package-astrbot-data.py) | 打包 AstrBot `data/`：排除 backups/temp/bak/logs/site-packages，用 SQLite 在线备份做不停机一致快照 | 是 | 低（只读源目录，写到独立 staging） |
| [`deploy/deploy-astrbot.sh`](deploy/deploy-astrbot.sh) | 解包 AstrBot 数据到 `/opt/astrbot/data`、写 compose、起容器；含「防 `mv` 嵌套」与配置存在性断言 | 是 | 中（会替换数据目录，旧数据保留为 `data.pre-<时间戳>`） |
| [`deploy/astrbot-fix-config.sh`](deploy/astrbot-fix-config.sh) | 迁移后去 Windows 化：批量去 UTF-8 BOM + 清本机 `http_proxy` | 是 | 低（改前备份 `cmd_config.json`） |
| [`deploy/setup-astrbot-nginx.sh`](deploy/setup-astrbot-nginx.sh) | 用宿主机 nginx 反代 AstrBot WebUI 并加 IP 白名单（WebSocket 透传） | 是 | 中（写 BT vhost 并 reload nginx；配置测试失败会自动删除该 vhost） |
| [`deploy/deploy-napcat.sh`](deploy/deploy-napcat.sh) | 为每个 QQ 号起一个 NapCat 容器（`MODE=astrbot` 自动反向连 AstrBot），与 AstrBot 同栈同网络 | 是 | 中（会重写 `/opt/astrbot/docker-compose.yml`，旧文件自动备份；改后需重新 `up -d`） |
| [`utils/redact-workspace.py`](utils/redact-workspace.py) | 提交前脱敏：按 `secrets/redaction-map.json` 把真值替换成占位符，并自检「一个都不剩」 | 是 | 低（`--check` 只读；`--apply` 改写受管目录，不碰 `secrets/` `logs/` `tmp/`） |
| [`utils/napcat-webui-tunnel.ps1`](utils/napcat-webui-tunnel.ps1) | SSH 隧道：把服务器上只绑本机的管理界面映射到本机（NapCat 6099/6100 + SillyTavern 8000） | 是 | 低（只建隧道，改本机监听；窗口关掉即断开） |
| [`deploy/package-sillytavern.py`](deploy/package-sillytavern.py) | 打包本机 SillyTavern 的**用户数据**：config.yaml、data/default-user、cookie-secret、第三方扩展；跳过应用本体与缓存 | 是 | 低（只读源目录） |
| [`deploy/deploy-sillytavern.sh`](deploy/deploy-sillytavern.sh) | 解包酒馆数据、修正 `config.yaml`（白名单/心跳）、写 compose 并启动 | 是 | 中（替换数据目录，旧数据保留为 `*.pre-<时间戳>`） |
| [`deploy/st-patch-config.py`](deploy/st-patch-config.py) | 幂等地把 docker 私网段加进 SillyTavern 白名单并设心跳；**按同级条目缩进插入**，避免 YAML 静默失效 | 是 | 低（改前备份 `config.yaml.pre-migration`） |
| [`deploy/install-cloudflared.sh`](deploy/install-cloudflared.sh) | 下载 cloudflared 静态二进制到 `/usr/local/bin` 并建 `/etc/cloudflared` | 是 | 低（不覆盖已安装的） |
| [`deploy/setup-cloudflared-tunnel.sh`](deploy/setup-cloudflared-tunnel.sh) | 用给定的隧道 ID 与 `主机名=端口` 列表生成 ingress 配置并装成 systemd 服务；**主机名由参数传入，脚本内不含真实域名** | 是 | 中（会重写 `/etc/cloudflared/config.yml` 与 `cloudflared.service`） |

## 执行约定

- 生产环境执行前，对照 `docs/operations/02-safety.md` 确认风险级别。
- 执行后写 `state/CHANGELOG.md` 记录。
