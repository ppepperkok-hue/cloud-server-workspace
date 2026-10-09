# astrbot-deps：AstrBot 的插件依赖（装得慢、一重建就全丢）

对应 KNOWN-ISSUES **#23**。AstrBot 的插件依赖（`transformers` / `modelscope` / `huggingface-hub` …）是**运行时**用 pip 装进**容器可写层**的，不在镜像里，所以：

- `docker compose up -d`（**任何**重建，包括只改动 compose）⇒ 依赖全丢，AstrBot 启动后从零重装，期间**面板 6185 与两个 OneBot 口 6199/6200 全都不监听**，但 `docker ps` 里容器照样显示 `Up`，很容易误判成崩溃。
- 2026-10-09 那次实测下载速度只有 **~211 kB/s**（出厂默认走 `https://mirrors.aliyun.com/pypi/simple/`），重装能拖到几十分钟。

## 现状（2026-10-09 19:44 起已缓解）

| 项 | 值 |
| --- | --- |
| 依赖安装源 | `https://mirrors.cloud.tencent.com/pypi/simple/`（腾讯内网，容器内解析到 `169.254.0.3`） |
| 生效位置 | `/opt/astrbot/data/cmd_config.json` 的 **`pypi_index_url`** |
| 缓存持久化 | `/opt/astrbot/pip-cache` → `/root/.cache/pip`、`/opt/astrbot/uv-cache` → `/root/.cache/uv`（已预热 122M / 80M） |
| 一次性改到位 | [`scripts/deploy/set-astrbot-pip-mirror.sh`](../../scripts/deploy/set-astrbot-pip-mirror.sh)（幂等，自带备份） |

**为什么改环境变量没用**：AstrBot 在容器内 `astrbot/core/utils/pip_installer.py:1012` 自己拼 `args.extend(["-i", index_url])`，`index_url` 来自配置项（默认值在 `astrbot/core/config/default.py:290`，读值在 `astrbot/core/__init__.py:46`）⇒ 容器里的 `PIP_INDEX_URL` 会被它的 `-i` **覆盖**，只对「直接手敲 `pip`」有效。脚本两处都写，是为了双保险。

## 步骤

只改 bind-mount 里的配置（例如 `cmd_config.json`、人格、插件配置）时：

```bash
docker restart astrbot          # 不重建容器 ⇒ 依赖不丢，25 秒左右面板就回来
```

真的要动 `docker-compose.yml` 时（预期一次长重装）：

```bash
cd /opt/astrbot
docker compose config >/dev/null && docker compose up -d
# 重装期间面板/适配器不可用；等容器内 6185 变 OPEN（见下「验证」）
```

重新配置 pip 源 / 缓存挂载（一般不需要再跑）：

```powershell
# 本机工作区执行
. .\scripts\utils\agent.ps1
AgentPut "scripts\deploy\set-astrbot-pip-mirror.sh" "/tmp/set-astrbot-pip-mirror.sh" -Mode 755
AgentRun -Cmd 'bash /tmp/set-astrbot-pip-mirror.sh'
```

脚本做四件事：改 `pypi_index_url`、给 astrbot 服务加 3 行 env + 2 行缓存卷（`docker compose config` 校验）、把可写层里现成的 pip/uv 缓存 `docker cp` 出来预热（`.seeded` 防重复）、**用 `docker stop`+`docker start` 而非 `up -d` 让 JSON 生效**（改 JSON 必须在容器停止时做，否则与 AstrBot 退出时的回写竞争）。

## 验证

```bash
# 1) 面板是否已经回来（镜像里没有 ss/netstat/ps，只能用 python）
docker exec astrbot python3 -c "import socket;s=socket.socket();s.settimeout(2);print(s.connect_ex(('127.0.0.1',6185)))"   # 期望 0
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:6185/        # 期望 200
curl -s  -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6185/         # 期望 000（明文口本来就关）

# 2) 两个 QQ 是否重新连上（这条才算真的好了）
docker logs astrbot --since 10m 2>&1 | grep -E "Loading IM platform adapter|适配器已连接"

# 3) 是否真的是 start 而不是 recreate
docker inspect astrbot --format 'Created={{.Created}} StartedAt={{.State.StartedAt}} RestartCount={{.RestartCount}}'

# 4) 源到底快不快（用配置里那个 URL，别用命令行默认值）
docker exec astrbot sh -c 'python3 -m pip download --no-deps --no-cache-dir -d /tmp/dl -i "$(python3 -c "import json;print(json.load(open(\"/AstrBot/data/cmd_config.json\"))[\"pypi_index_url\"])")" numpy'
```

判据（历史实测）：腾讯内网 **2348 ms**、aliyun **280500 ms**、`pypi.org` 超时（同一个 16.7 MB 的 numpy wheel）。

## 回滚

```bash
docker stop astrbot
cp -a /root/backups/astrbot-pip-<时间戳>/cmd_config.json   /opt/astrbot/data/cmd_config.json
cp -a /root/backups/astrbot-pip-<时间戳>/docker-compose.yml /opt/astrbot/docker-compose.yml
docker start astrbot
```

`docker-compose.yml` 里那 3 行 env + 2 行卷只在**下一次 `up -d`** 时才生效，所以从文件里删掉就够了，不必为了它们重建容器。

## 注意事项

- **别用 `docker compose restart`**：它不会重建，但也不会把新加的 env/卷带进容器；env 与卷只有**重建**才生效。
- 长重装期间**不要**因为「面板 502」就去 kill 容器或反复重启——那只会让 pip 从头再来。
- 镜像里**没有** `ps` / `ss` / `netstat`，排障只能用 `python3` 的 socket 或从宿主机看 `docker-proxy` 的监听。
- 缓存目录被 `docker cp` 预热过，属于「可重建的加速物」：真出问题直接删 `/opt/astrbot/{pip-cache,uv-cache}` 即可，代价只是下次重装变慢。
