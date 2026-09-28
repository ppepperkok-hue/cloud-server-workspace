# migrate-astrbot：把本机 AstrBot 迁移到服务器

- **名称**：把 Windows 上的 AstrBot（含插件、配置、数据库、人格、知识库）迁移到 bt-he1k 的 Docker 容器里
- **适用环境**：test（2026-09-28 已在 bt-he1k 执行完成）
- **风险级别**：中 —— 涉及用户数据；数据目录放错会被 AstrBot 当成全新安装，面板密码和插件全部清零
- **前置条件**：服务器已装 Docker（[`install-docker.sh`](../../scripts/deploy/install-docker.sh)）；能 SSH；已确认源版本号
- **最近更新**：2026-09-28
- **脚本**：[`package-astrbot-data.py`](../../scripts/deploy/package-astrbot-data.py) · [`deploy-astrbot.sh`](../../scripts/deploy/deploy-astrbot.sh) · [`install-docker.sh`](../../scripts/deploy/install-docker.sh)

## 迁移什么

AstrBot 的全部身家就是 `data/` 一个目录：

| 内容 | 作用 |
| --- | --- |
| `cmd_config.json` | 平台、17 个提供商（含各家 API Key）、面板账号、人格、T2I、代理等全部设置 |
| `data_v4.db` | 会话、人格、记忆主库（SQLite + WAL） |
| `plugins/` `plugin_data/` `config/` | 37 个插件本体、插件运行数据、每个插件的配置 |
| `knowledge_base/` `memes_data/` `attachments/` | 知识库、表情包、附件 |
| `skills/` `t2i_templates/` `webchat/` `mcp_server.json` `plugins.json` | 其它运行态 |

**不要迁移**：`backups/`（自备份，本次 1.76 GB）、`temp/`、`*.bak`、`logs/`、`site-packages/`（Windows 版 pip 依赖，容器里会重装；跨平台带过去反而坏事）。

## 步骤

1. **对齐版本**，再拉镜像（版本不一致 AstrBot 会做配置迁移，能对齐就对齐）：

   ```bash
   grep -m1 '^version' <AstrBot>/pyproject.toml
   docker pull m.daocloud.io/docker.io/soulter/astrbot:v<版本>
   ```

   > 国内/香港机器直连 Docker Hub 常被墙；用镜像前缀 `m.daocloud.io/docker.io/...`，或在 `/etc/docker/daemon.json` 里配 `registry-mirrors`。

2. **本机打包**（用脚本，别直接复制：它调用 SQLite 在线备份 API 给每个 `.db` 做一致性快照，**AstrBot 不用停**）：

   ```powershell
   .\<AstrBot>\venv\Scripts\python.exe scripts\deploy\package-astrbot-data.py `
       "D:\...\AstrBot\data" "D:\astrbot-migrate\data"
   tar.exe -czf D:\astrbot-migrate\astrbot-data.tar.gz -C D:\astrbot-migrate data
   ```

3. **上传**（`scp` 会把路径开头的 `D:` 当成主机名，先切进目录用相对路径）：

   ```powershell
   cd D:\astrbot-migrate
   scp -i <key> astrbot-data.tar.gz root@<host>:/root/astrbot-data.tar.gz
   # 两边 sha256sum 必须一致再往下走
   ```

4. **服务器上解包 + 起容器**：

   ```bash
   bash scripts/deploy/deploy-astrbot.sh
   ```

   脚本会把 tarball 解到临时目录，再把**内容**拷进 `/opt/astrbot/data`，校验 `cmd_config.json` 存在才启动；旧数据会保留成 `data.pre-<时间戳>`。

5. **清掉 Windows 专有的网络设置**（不做这步插件依赖一个都装不上）：

   ```bash
   bash scripts/deploy/astrbot-fix-config.sh   # 去 BOM + 清 http_proxy
   ```

## 必修项（漏一个就出怪事）

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 日志刷 `SOCKSHTTPSConnection(...) Connection refused`，插件依赖全装不上、T2I 也失败 | 迁移来的 `cmd_config.json` 带着本机的 `http_proxy`（如 `socks5://127.0.0.1:PORT`），容器里没有这个代理 | 置空 `http_proxy`：停容器 → 改配置 → 起容器 |
| JSON 解析报 `Unexpected UTF-8 BOM` | Windows 写入的 JSON 带 UTF-8 BOM | 批量去 BOM（本次 39 个文件） |
| 容器起来了但要重新设密码、插件全没 | `data/` 被放成 `data/data/`（`mv A B` 在 B 已存在时会嵌套），AstrBot 当全新安装跑 | 用 `deploy-astrbot.sh`，它靠 `cp` 内容 + 存在性校验挡住这一脚 |

## 验证

```bash
docker ps --filter name=astrbot
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6185/                      # 预期 200
docker logs astrbot 2>&1 | grep -c 'Failed to import plugin'                         # 预期 0
docker logs astrbot 2>&1 | grep -aoE 'Plugin [a-z_0-9]+ \([^)]*\) by' | sort -u | wc -l
```

从客户端（AstrBot 不像宝塔那样认 UA）：

```bash
curl -s http://<TEST_HOST_IP>/ | grep -o '<title>[^<]*</title>'      # 预期 <title>AstrBot Dashboard</title>
curl -s -o /dev/null -w '%{http_code}\n' http://<TEST_HOST_IP>/api/stat   # 预期 401（需要登录）
```

## 回滚

```bash
cd /opt/astrbot && docker compose down
# 数据在 /opt/astrbot/data；上一版被保留为 /opt/astrbot/data.pre-<时间戳>
# 彻底回退：删 /opt/astrbot，本机原实例一直没动，随时切回
```

## 注意事项

- WebUI **不要直接暴露公网**：容器端口只绑 `127.0.0.1`，由 nginx 反代 + IP 白名单兜住（见 [`setup-astrbot-nginx.sh`](../../scripts/deploy/setup-astrbot-nginx.sh)）。
- 反代之后把 `dashboard.trust_proxy_headers` 设为 `true`，AstrBot 才能拿到真实客户端 IP。
- **QQ/OneBot（NapCat）是另一件事**：AstrBot 只在 `6199` 上监听、等适配器反向连进来；NapCat 要单独迁移并**重新扫码登录**，且换 IP 登录有触发 QQ 风控的风险，需要本人在场。
- 迁移完按 `AGENTS.md` 三件套收尾：验证 → 追 `state/CHANGELOG.md` → 更新 `docs/inventory/services.md` 与 `state/TASKS.md`。
