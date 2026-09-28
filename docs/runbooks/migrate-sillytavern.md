# migrate-sillytavern：把本机 SillyTavern（酒馆）迁移到服务器

- **名称**：把 Windows 上的 SillyTavern 迁移到 bt-he1k 的 Docker 容器
- **适用环境**：test（2026-09-28 已在 bt-he1k 执行完成）
- **风险级别**：中 —— 涉及角色卡与聊天记录；配置写错会**整站 403**，扩展层级错会**扩展全不加载**
- **前置条件**：服务器已装 Docker（[`install-docker.sh`](../../scripts/deploy/install-docker.sh)）；能 SSH；已确认本机版本
- **最近更新**：2026-09-28
- **脚本**：[`package-sillytavern.py`](../../scripts/deploy/package-sillytavern.py) · [`deploy-sillytavern.sh`](../../scripts/deploy/deploy-sillytavern.sh) · [`st-patch-config.py`](../../scripts/deploy/st-patch-config.py)

## 迁移什么

| 内容 | 本机位置 | 说明 |
| --- | --- | --- |
| `config.yaml` | 安装根 | listen / port / whitelist / basicAuth 等全部设置（**含 basicAuth 明文密码，别泄露**） |
| `data/default-user/` | 数据根 | 角色卡、聊天记录、世界书、主题、预设、用户设置 |
| `data/cookie-secret.txt` | 数据根 | 会话 cookie 签名密钥 |
| `public/scripts/extensions/third-party/<扩展>/` | 应用目录 | 用户自装的第三方扩展（连各自的 node_modules 一起） |

**不要迁移**：应用本体（镜像自带）、`node_modules/`、`data/_webpack`、`data/_cache`、`data/_errors`、`access.log`、`content.log`、`backups/`。

## 步骤

1. 选镜像，与本机版本对齐（本机是 1.18.0）：
   ```bash
   docker pull ghcr.io/sillytavern/sillytavern:1.18.0
   ```
   > ghcr.io 从这台香港机器**能连但极慢**（实测 35 分钟仍未下完）。改用 DaoCloud 的 ghcr 镜像前缀 `m.daocloud.io/ghcr.io/sillytavern/sillytavern:1.18.0` **几秒就完成** —— 因为层是按 digest 复用的，之前下的不用重下。

2. 本机打包（脚本只挑「用户数据」，并**保留** `extensions/third-party/` 这层上游结构）：
   ```powershell
   python scripts\deploy\package-sillytavern.py E:\jiuguan\SillyTavern D:\sillytavern-migrate\payload
   tar.exe -czf D:\sillytavern-migrate\sillytavern-payload.tar.gz -C D:\sillytavern-migrate\payload .
   ```

3. 上传（注意 scp 把 `D:` 当主机名，先切目录用相对路径）后部署：
   ```bash
   bash scripts/deploy/deploy-sillytavern.sh
   ```

## 必修项（两个，坏起来都是静默的）

| 症状 | 原因 | 处理 |
| --- | --- | --- |
| 容器 `healthy`，但**所有请求 403**，日志写 `Blocked connection from 172.19.0.1` | 请求是从 **docker 网关**进来的、不是 `127.0.0.1`，而 SillyTavern 自己的白名单里没有它。（官方文档说 `whitelistDockerHosts` 会自动加，但那只在 Docker Desktop 生效；Linux 上 `host.docker.internal` 解析不了） | 把 `172.16.0.0/12` 加进 `whitelist`。用 `st-patch-config.py`：**缩进必须和已有条目完全一致** —— 深一层 YAML 照样解析通过，但那条会被当成上一条的子列表，白名单里**根本没生效**（本次就是这么踩的） |
| 页面正常，但**第三方扩展一个都不显示** | 容器的卷挂载点在 `.../extensions/third-party`，所以宿主目录里要**直接**放扩展文件夹；打包保留了 `extensions/third-party/<名>` 这层，于是变成 `third-party/third-party/<名>` | 把 `extensions/third-party/*` 上提一层（`deploy-sillytavern.sh` 已按此处理） |

## 验证

```bash
docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' sillytavern   # running healthy
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/                                          # 200
curl -s http://127.0.0.1:8000/ | grep -o '<title>[^<]*</title>'                                          # <title>SillyTavern</title>
docker exec sillytavern sh -c 'ls -1 /home/node/app/public/scripts/extensions/third-party'               # 扩展目录名
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:8000/scripts/extensions/third-party/<扩展>/manifest.json                              # 200
```

角色卡与设置是否搬全，看数据目录即可：`data/default-user/characters`（本次 6 张）、`chats`（5 个）、`settings.json`。

## 回滚

```bash
cd /opt/sillytavern && docker compose down
# config / data / extensions 的上一版保留为 <名>.pre-<时间戳>；config.yaml 另存 config.yaml.pre-migration
# 彻底回退：删 /opt/sillytavern。本机原实例全程未改动，随时切回
```

## 注意事项

- 容器端口只绑 `127.0.0.1`，对外一律走 SSH 隧道（[`napcat-webui-tunnel.ps1`](../../scripts/utils/napcat-webui-tunnel.ps1)，它同时转发 6099 / 6100 / **8000**）。理由见 [ADR-0004](../decisions/ADR-0004-tencent-domain-block.md)：这台机器上域名走 80 端口会被腾讯云「未备案」拦截。
- 真要让酒馆公网可访问，**先把 `basicAuthMode` 打开**（本机配置里已经填好账号密码），再去控制台放行端口 —— SillyTavern 官方明确写着不要裸着暴露到公网。
- `config.yaml` 里存着 basicAuth 的**明文密码**：不要贴进任何文档、日志或提交。
