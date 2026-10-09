# 运行手册：ops-agent（服务器上的常驻执行通道）

一句话：**日常运维不要再一条条起 `ssh.exe`，改用 `scripts/utils/agent.ps1`。**
它把命令以 JSON 发给服务器上只监听 `127.0.0.1:7777` 的 `ops-agent`，再经**已有的 SSH 隧道**回来，实测 ~124 ms/条（一次性 SSH 是 ~1700 ms）。决策背景见 [ADR-0005](../decisions/ADR-0005-ops-agent.md)。

## 前提：隧道必须起着

agent 只绑本机回环地址，所以先要有隧道：

```powershell
# 保持这个窗口开着（同时转发 NapCat 6099/6100、酒馆 8000、AstrBot 6185 与 agent 7777）
.\scripts\utils\napcat-webui-tunnel.ps1
```

隧道没起时的报错是明确的：`Cannot reach the ops-agent ... is the SSH tunnel up?`

## 日常用法

在 pwsh / powershell 里先点源一次（同一个会话里后续调用都很快）：

```powershell
. D:\cloud-server-workspace\scripts\utils\agent.ps1

AgentHealth                       # 版本、PID、uptime
AgentRun 'uptime -p; nproc'       # 跑命令，打印 stdout/stderr，$LASTEXITCODE = 远端退出码
AgentRun "docker ps --format 'table {{.Names}}\t{{.Status}}'"   # 引号、{{...}} 都不用转义
AgentRun 'ss -lntp' -TimeoutSec 30
```

脚本、后台任务、传文件：

```powershell
AgentScript -Path .\tmp\check.sh -Arguments one, two      # 发本地脚本去跑（无大小/行尾限制）
$id = AgentSpawn 'dnf -y update'                          # 后台跑（agent 端最多 7200 s）
AgentJob -Id $id -Wait                                    # 等它结束并打印输出
AgentJobs                                                 # 列出任务
AgentPut -Local .\tmp\x.conf -Remote /etc/nginx/conf.d/x.conf -Mode 644
AgentGet -Remote /var/log/ops-agent/commands.log -Local .\tmp\commands.log
AgentLs /root
```

需要原始 JSON（比如自己解析）时加 `-PassThru`：

```powershell
$r = AgentRun 'df -h /' -PassThru
$r.exit; $r.duration_ms; $r.stdout
```

命令行包装版本（脚本里调用、或不想点源时）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\utils\rsh.ps1 -Command 'uptime -p'
```

> 注意：`rsh.ps1` 是**另一个 powershell 进程**，固定开销把省下的时间吃回去了（实测 1709 ms vs 1717 ms）。要快就用点源 + `AgentRun`。

## 什么时候仍然用 `ssh-bt-he1k.ps1`

- agent 还没装、或隧道断了（引导/救援）；
- 要连的是别的机器；
- 你只想跑一条命令、不在乎 1.7 s。

它现在也支持大脚本了（>7000 个 base64 字符自动改走 stdin）。

## 服务端

```bash
systemctl status ops-agent                 # 常驻单元，enabled + Restart=always
journalctl -u ops-agent -n 50 --no-pager   # 服务自身日志（绑定、启动）
tail -n 50 /var/log/ops-agent/commands.log # 每条请求一行 JSON：命令、exit、耗时、字节数
cat /etc/ops-agent/token                   # token（0600 root）
ss -lntp | grep 7777                       # 必须只有 127.0.0.1
```

接口一览：

| 方法 | 路径 | 作用 |
| --- | --- | --- |
| GET | `/health` | 版本 / PID / uptime |
| POST | `/run` | `{cmd, cwd?, timeout?}` → `{exit, stdout, stderr, duration_ms, ...}` |
| POST | `/script` | `{script, args?, cwd?, timeout?}`，脚本以文本传输，无大小限制 |
| POST | `/spawn` | 后台任务，返回 `{id}` |
| GET | `/job?id=` / `/jobs` | 任务状态与输出（保留 6 小时，最多 16 个并发） |
| POST | `/kill` | `{id}`，杀后台任务 |
| POST | `/put` | `{path, content_b64, mode?}` |
| GET | `/get?path=` | 下载（base64） |
| GET | `/ls?path=` | 列目录 |

约定：命令用 `bash -lc` 执行、cwd 默认 `/root`、默认 300 s 超时（上限 7200 s）、每路输出只留最后 1 MiB（超出会打印 `note: ... truncated`）。

## 重装 / 升级 / 换 token

```powershell
# 1) 生成新 token（或在 secrets/ops-agent-token.txt 里换一个 64 位 hex）
. .\scripts\utils\agent.ps1
# 2) 重装（幂等：覆盖脚本与单元，重启服务）
$tok = (Get-Content -Raw secrets\ops-agent-token.txt).Trim()
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\utils\ssh-bt-he1k.ps1 `
    -ScriptPath .\scripts\deploy\install-ops-agent.sh -ScriptArgs $tok
```

装了 agent 之后，重装其实也可以走 agent 自己，但**换 token 那一次必须走 SSH**（否则新 token 还没生效，agent 就先拒了你）。

## 排障

| 症状 | 原因 / 处理 |
| --- | --- |
| `Cannot reach the ops-agent ...` | 隧道没起或断线 → 重开 `napcat-webui-tunnel.ps1` |
| `401 missing bearer token` / `403 bad token` | 本机 `secrets/ops-agent-token.txt` 与服务器 `/etc/ops-agent/token` 不一致 → 重跑安装脚本 |
| `Address already in use` | 已经有一个实例在跑（`systemctl status ops-agent`） |
| 输出被截断 | 单路流超过 1 MiB，agent 只保留尾部；把命令改成写日志文件再 `AgentGet` |
| `TIMEOUT` | 命令超过 `-TimeoutSec`；长任务请用 `AgentSpawn` |
| 中文乱码 | 不会发生：请求/响应都是 UTF-8 JSON（脚本投递也一样，见 `ssh-bt-he1k.ps1` 的 `-Encoding UTF8` 修复） |

## 安全须知

- agent **以 root 运行并执行任意 shell**，token 就是 root 密码：不要提交、不要贴聊天记录、怀疑泄露立刻换。
- 它只监听 `127.0.0.1`，唯一的入口是 SSH 隧道 —— **不要**把它 `-L 0.0.0.0:7777` 或加进 nginx/Cloudflare。
- 所有请求都记在 `/var/log/ops-agent/commands.log`，审计时先看这里。
- 不用的机器直接 `systemctl disable --now ops-agent` 并删 `/etc/ops-agent/token`。
